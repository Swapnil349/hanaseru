import Anthropic from "@anthropic-ai/sdk";
import {
  ANNOTATE_SYSTEM_PROMPT,
  buildAnnotationMessage,
  buildSceneMessage,
  SCENE_SYSTEM_PROMPT,
  buildEvaluationMessage,
  buildTranslationMessage,
  buildTurnMessage,
  EVALUATE_SYSTEM_PROMPT,
  TRANSLATE_SYSTEM_PROMPT,
  TURN_SYSTEM_PROMPT,
} from "./prompts.ts";
import {
  annotationSchema,
  sceneSchema,
  type SceneRequest,
  type SceneResult,
  evaluationSchema,
  type AnnotationRequest,
  type AnnotationResult,
  translationSchema,
  turnSchema,
  type EvaluationRequest,
  type TranslationRequest,
  type TranslationResult,
  type TurnEvaluation,
  type TurnRequest,
  type TurnResponse,
} from "./schemas.ts";

export class CoachError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export interface Coach {
  readonly model: string;
  turn(request: TurnRequest): Promise<TurnResponse>;
  evaluate(request: EvaluationRequest): Promise<TurnEvaluation>;
  translate(request: TranslationRequest): Promise<TranslationResult>;
  annotate(request: AnnotationRequest): Promise<AnnotationResult>;
  scene(request: SceneRequest): Promise<SceneResult>;
}

type Effort = "low" | "medium" | "high" | "xhigh" | "max";

export interface ClaudeCoachOptions {
  client?: Anthropic;
  model?: string;
  effort?: Effort;
}

/**
 * Claude-backed coach. Low effort by default: a hands-free conversation can't wait long for each turn,
 * and these are short, well-specified outputs.
 */
export function createClaudeCoach(options: ClaudeCoachOptions = {}): Coach {
  const client = options.client ?? new Anthropic({ timeout: 30_000, maxRetries: 1 });
  const model = options.model || "claude-opus-5-5";
  const effort = options.effort ?? "low";

  async function structured<T>(system: string, content: string, schema: Record<string, unknown>, maxTokens = 4000,
                               options: { effort?: Effort; timeout?: number } = {}): Promise<T> {
    let response: Anthropic.Beta.BetaMessage;
    try {
      response = await client.beta.messages.create({
        model,
        max_tokens: maxTokens,
        // If a safety classifier declines a benign request, retry server-side on Anthropic's recommended model.
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
        output_config: { effort: options.effort ?? effort, format: { type: "json_schema", schema } },
        messages: [{ role: "user", content }],
      }, options.timeout ? { timeout: options.timeout } : undefined);
    } catch (error) {
      if (error instanceof Anthropic.RateLimitError) throw new CoachError(429, "Claude rate limit reached");
      if (error instanceof Anthropic.AuthenticationError) throw new CoachError(502, "Proxy misconfigured: Anthropic authentication failed");
      if (error instanceof Anthropic.BadRequestError) throw new CoachError(502, `Claude rejected the request: ${error.message}`);
      if (error instanceof Anthropic.APIConnectionTimeoutError) throw new CoachError(504, "Claude timed out");
      if (error instanceof Anthropic.APIError) throw new CoachError(502, `Claude API error ${error.status ?? ""}`.trim());
      throw error;
    }

    if (response.stop_reason === "refusal") throw new CoachError(422, "Claude declined this request");
    if (response.stop_reason === "max_tokens") throw new CoachError(502, "Claude's response was cut off");
    const block = response.content.find((b): b is Anthropic.Beta.BetaTextBlock => b.type === "text");
    if (!block) throw new CoachError(502, "Claude returned no text");
    try {
      return JSON.parse(block.text) as T;
    } catch {
      throw new CoachError(502, "Claude returned invalid JSON");
    }
  }

  return {
    model,
    turn: (request) => structured<TurnResponse>(TURN_SYSTEM_PROMPT, buildTurnMessage(request), turnSchema),
    evaluate: (request) => structured<TurnEvaluation>(EVALUATE_SYSTEM_PROMPT, buildEvaluationMessage(request), evaluationSchema),
    translate: (request) =>
      structured<TranslationResult>(TRANSLATE_SYSTEM_PROMPT, buildTranslationMessage(request), translationSchema),
    annotate: (request) =>
      structured<AnnotationResult>(ANNOTATE_SYSTEM_PROMPT, buildAnnotationMessage(request), annotationSchema, 16000),
    // A whole scene is written once and studied for weeks: worth more thought and time than a turn.
    scene: (request) =>
      structured<SceneResult>(SCENE_SYSTEM_PROMPT, buildSceneMessage(request), sceneSchema, 32000, { effort: "medium", timeout: 180_000 }),
  };
}

/** Deterministic coach for local development and tests: no API key, no network. */
export function createMockCoach(): Coach {
  return {
    model: "mock",
    async turn(request) {
      const said = request.learnerUtterance.trim();
      const isFinal = request.context.turnIndex + 1 >= request.context.maxTurns;
      return {
        evaluation: {
          verdict: said ? "acceptable" : "noResponse",
          understood: Boolean(said),
          feedbackEn: "",
          naturalVersion: "",
          mistakes: [],
        },
        reply: isFinal
          ? { japanese: "ありがとうございました。", kana: "ありがとうございました。", english: "Thank you." }
          : { japanese: "なるほど。もう少し詳しく教えてください。", kana: "なるほど。もうすこしくわしくおしえてください。", english: "I see. Tell me a bit more." },
        shouldEnd: isFinal,
      };
    },
    async evaluate(request) {
      const normalize = (s: string) => s.replace(/[\s、。？！?!,.]/g, "");
      const said = normalize(request.learnerUtterance);
      const exact = request.examples.some((example) => normalize(example) === said);
      return {
        verdict: !said ? "noResponse" : exact ? "natural" : "acceptable",
        understood: Boolean(said),
        feedbackEn: "",
        naturalVersion: exact ? "" : (request.examples[0] ?? ""),
        mistakes: [],
      };
    },
    async translate(request) {
      return {
        japanese: "確認しておきます。",
        kana: "かくにんしておきます。",
        backTranslation: `I'll check it in advance. (mock for: ${request.english})`,
        notes: "",
        alternatives: [],
      };
    },
    async scene(request) {
      const line = (japanese: string, english: string) => ({
        japanese, kana: japanese, english, words: [{ ja: japanese.replace(/[、。？！\s]/g, ""), kana: japanese, en: english }],
      });
      const empty = { japanese: "", kana: "", english: "", words: [] };
      const monologue = request.kind === "monologue";
      return {
        title: monologue ? "My self-introduction" : "My scene",
        titleJa: monologue ? "自己紹介" : "私の場面",
        situationEn: `(mock) ${request.description}`,
        placeEn: "in the office",
        partnerNameJa: "田中さん", partnerNameEn: "Tanaka-san", partnerRole: "Colleague", partnerGender: "female",
        track: "everyday",
        beats: Array.from({ length: request.length }, (_, i) => ({
          partner: monologue ? empty : line("はい。", "Yes."),
          learner: line(`{name}です。${i + 1}`, `I'm {name}. ${i + 1}`),
          hintEn: "Say your name",
        })),
        closing: monologue ? empty : line("ありがとうございました。", "Thank you."),
      };
    },
    async annotate(request) {
      return {
        lines: request.lines.map((line) => ({
          japanese: line,
          kana: line,
          english: `(mock translation of ${line})`,
          words: [{ ja: line.replace(/[、。？！\s]/g, ""), kana: line, en: "(mock)" }],
        })),
      };
    },
  };
}
