import { createHash, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { CoachError, type Coach } from "./coach.ts";
import { parseAnnotationRequest, parseEvaluationRequest, parseTranslationRequest, parseTurnRequest, ValidationError } from "./schemas.ts";

/** Web pages allowed to call the coach from a browser: the Windows desktop app and its local preview. */
const ALLOWED_ORIGINS = new Set(["https://swapnil349.github.io", "http://localhost:5173", "http://localhost:4173"]);

const MAX_BODY_BYTES = 64 * 1024;

export interface ServerOptions {
  coach: Coach;
  /** Shared secret the app sends as `Authorization: Bearer <token>`. */
  appToken: string;
  /** Requests per minute across all clients; this proxy serves one learner. */
  rateLimitPerMinute?: number;
  log?: (message: string) => void;
}

class HttpError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function createCoachServer(options: ServerOptions): Server {
  const { coach, appToken } = options;
  const log = options.log ?? ((message: string) => console.log(message));
  const limit = options.rateLimitPerMinute ?? 60;
  const expected = digest(appToken);
  let windowStart = Date.now();
  let windowCount = 0;

  function authorized(request: IncomingMessage): boolean {
    const header = request.headers.authorization ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    return token.length > 0 && timingSafeEqual(digest(token), expected);
  }

  function withinRateLimit(): boolean {
    const now = Date.now();
    if (now - windowStart > 60_000) {
      windowStart = now;
      windowCount = 0;
    }
    windowCount += 1;
    return windowCount <= limit;
  }

  async function route(request: IncomingMessage): Promise<unknown> {
    const path = new URL(request.url ?? "/", "http://localhost").pathname;
    if (!authorized(request)) throw new HttpError(401, "Missing or invalid token");
    if (request.method === "GET" && path === "/health") return { ok: true, model: coach.model };
    if (request.method !== "POST") throw new HttpError(404, "Not found");
    if (!withinRateLimit()) throw new HttpError(429, "Too many requests");

    switch (path) {
      case "/v1/turn":
        return coach.turn(parseTurnRequest(await readJSON(request)));
      case "/v1/evaluate":
        return coach.evaluate(parseEvaluationRequest(await readJSON(request)));
      case "/v1/translate":
        return coach.translate(parseTranslationRequest(await readJSON(request)));
      case "/v1/annotate":
        return coach.annotate(parseAnnotationRequest(await readJSON(request)));
      default:
        throw new HttpError(404, "Not found");
    }
  }

  return createServer(async (request, response) => {
    const started = Date.now();
    // The desktop app runs in a browser: it may call the coach from its own address only. The token is still required.
    const origin = request.headers.origin;
    if (origin && ALLOWED_ORIGINS.has(origin)) {
      response.setHeader("Access-Control-Allow-Origin", origin);
      response.setHeader("Vary", "Origin");
      response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
      response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      response.setHeader("Access-Control-Max-Age", "600");
    }
    if (request.method === "OPTIONS") {
      response.writeHead(origin && ALLOWED_ORIGINS.has(origin) ? 204 : 403);
      response.end();
      return;
    }
    try {
      send(response, 200, await route(request));
    } catch (error) {
      const status =
        error instanceof HttpError || error instanceof CoachError ? error.status : error instanceof ValidationError ? 400 : 500;
      const message = error instanceof Error && status !== 500 ? error.message : "Internal error";
      if (status === 500) log(`error: ${error instanceof Error ? error.stack : String(error)}`);
      send(response, status, { error: message });
    } finally {
      // Log shape only, never the learner's words.
      log(`${request.method} ${request.url} ${response.statusCode} ${Date.now() - started}ms`);
    }
  });
}

function digest(value: string): Buffer {
  return createHash("sha256").update(value).digest();
}

async function readJSON(request: IncomingMessage): Promise<unknown> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, "Request too large");
    chunks.push(chunk as Buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new ValidationError("Body must be JSON");
  }
}

function send(response: ServerResponse, status: number, body: unknown): void {
  const json = JSON.stringify(body);
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(json) });
  response.end(json);
}
