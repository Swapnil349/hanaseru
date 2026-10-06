import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createMockCoach } from "../src/coach.ts";
import { buildTurnMessage, TURN_SYSTEM_PROMPT } from "../src/prompts.ts";
import { parseTurnRequest, turnSchema } from "../src/schemas.ts";
import { createCoachServer } from "../src/server.ts";

const TOKEN = "test-token-0123456789";

// Exactly what the iOS app encodes (see ConversationCore/AIProvider.swift).
const turnBody = {
  context: {
    scenarioID: "s.progress.meeting",
    scenarioTitle: "Progress meeting",
    situation: "Weekly progress meeting with Suzuki-san.",
    persona: { name: "鈴木さん", role: "Project manager", personality: "Friendly", formality: "professional", style: "Business-like" },
    learnerName: "Swapnil",
    learnerLevel: 3,
    englishSupport: 0.8,
    targetTerms: ["進捗", "予定"],
    recurringMistakeTypes: ["pastTense"],
    history: [
      { speaker: "partner", japanese: "この区間の進捗はどうですか？", english: "How is progress on this section?" },
      { speaker: "learner", japanese: "順調です" },
    ],
    turnIndex: 0,
    maxTurns: 4,
  },
  learnerUtterance: "順調です",
  asrConfidence: 0.92,
};

describe("coach proxy", () => {
  let base = "";
  const server = createCoachServer({ coach: createMockCoach(), appToken: TOKEN, log: () => {} });

  before(async () => {
    await new Promise<void>((resolve) => server.listen(0, resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));

  const post = (path: string, body: unknown, token = TOKEN) =>
    fetch(base + path, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });

  it("rejects requests without the app token", async () => {
    assert.equal((await fetch(`${base}/health`)).status, 401);
    assert.equal((await post("/v1/turn", turnBody, "wrong-token")).status, 401);
  });

  it("reports health", async () => {
    const response = await fetch(`${base}/health`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true, model: "mock" });
  });

  it("answers a conversation turn in the app's wire format", async () => {
    const response = await post("/v1/turn", turnBody);
    assert.equal(response.status, 200);
    const json = await response.json();
    assert.equal(json.evaluation.verdict, "acceptable");
    assert.equal(typeof json.reply.japanese, "string");
    assert.equal(typeof json.reply.kana, "string");
    assert.equal(json.shouldEnd, false);
  });

  it("ends on the final turn", async () => {
    const body = structuredClone(turnBody);
    body.context.turnIndex = 3;
    const json = await (await post("/v1/turn", body)).json();
    assert.equal(json.shouldEnd, true);
  });

  it("evaluates a recall answer", async () => {
    const response = await post("/v1/evaluate", {
      mode: "recall", prompt: "Say: I'll check on that.", question: "", examples: ["確認しておきます"],
      learnerUtterance: "確認しておきます。", learnerLevel: 2, politeness: "professional",
    });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).verdict, "natural");
  });

  it("translates English into natural Japanese", async () => {
    const response = await post("/v1/translate", { english: "I'll check that", politeness: "professional" });
    assert.equal(response.status, 200);
    const json = await response.json();
    assert.equal(typeof json.japanese, "string");
    assert.ok(Array.isArray(json.alternatives));
    assert.equal((await post("/v1/translate", { english: "hi", politeness: "rude" })).status, 400);
    assert.equal((await post("/v1/translate", {})).status, 400);
  });

  it("rejects malformed bodies with 400", async () => {
    assert.equal((await post("/v1/turn", "{not json")).status, 400);
    assert.equal((await post("/v1/turn", { context: {} })).status, 400);
    assert.equal((await post("/v1/evaluate", { mode: "essay" })).status, 400);
  });

  it("rejects oversized bodies", async () => {
    const huge = { ...turnBody, learnerUtterance: "あ".repeat(70_000) };
    assert.equal((await post("/v1/turn", huge)).status, 413);
  });

  it("404s unknown routes", async () => {
    assert.equal((await post("/v1/nope", {})).status, 404);
  });
});

describe("request handling", () => {
  it("bounds input sizes", () => {
    const long = { ...turnBody, learnerUtterance: "あ".repeat(2000) };
    assert.equal(parseTurnRequest(long).learnerUtterance.length, 500);
    const clamped = parseTurnRequest({ ...turnBody, context: { ...turnBody.context, learnerLevel: 42 } });
    assert.equal(clamped.context.learnerLevel, 8);
  });

  it("tells Claude when the conversation must close", () => {
    const request = parseTurnRequest({ ...turnBody, context: { ...turnBody.context, turnIndex: 3 } });
    assert.match(buildTurnMessage(request), /final turn/);
    assert.match(buildTurnMessage(parseTurnRequest(turnBody)), /not the final turn/);
  });

  it("keeps the system prompt free of per-request data so it caches", () => {
    assert.doesNotMatch(TURN_SYSTEM_PROMPT, /\d{4}-\d{2}-\d{2}/);
    assert.doesNotMatch(TURN_SYSTEM_PROMPT, /Swapnil/);
  });

  it("uses strict schemas for structured output", () => {
    const check = (schema: Record<string, unknown>): void => {
      if (schema.type !== "object") return;
      assert.equal(schema.additionalProperties, false);
      const properties = schema.properties as Record<string, Record<string, unknown>>;
      assert.deepEqual([...(schema.required as string[])].sort(), Object.keys(properties).sort());
      for (const property of Object.values(properties)) {
        check(property);
        if (property.type === "array") check(property.items as Record<string, unknown>);
      }
    };
    check(turnSchema);
  });
});
