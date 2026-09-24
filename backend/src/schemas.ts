// Wire format shared with the iOS app (Packages/HanaseruKit/Sources/ConversationCore/AIProvider.swift).
// Keep field names in sync on both sides.

export const VERDICTS = [
  "natural",
  "acceptable",
  "understandable",
  "contextuallyInappropriate",
  "incorrect",
  "unclear",
  "noResponse",
] as const;
export type Verdict = (typeof VERDICTS)[number];

export const MISTAKE_TYPES = ["pastTense", "conjugation", "particle", "politeness", "vocabulary", "wordOrder", "other"] as const;
export type MistakeType = (typeof MISTAKE_TYPES)[number];

export const POLITENESS = ["casual", "professional", "veryPolite"] as const;
export type Politeness = (typeof POLITENESS)[number];

export interface DialogueTurn {
  speaker: "partner" | "learner";
  japanese: string;
  english?: string;
}

export interface ConversationContext {
  scenarioID: string;
  scenarioTitle: string;
  situation: string;
  persona: { name: string; role: string; personality: string; formality: Politeness; style: string };
  learnerName: string;
  learnerLevel: number;
  englishSupport: number;
  targetTerms: string[];
  recurringMistakeTypes: string[];
  history: DialogueTurn[];
  turnIndex: number;
  maxTurns: number;
}

export interface TurnRequest {
  context: ConversationContext;
  learnerUtterance: string;
  asrConfidence?: number;
}

export interface EvaluationRequest {
  mode: "recall" | "listening";
  prompt: string;
  question: string;
  examples: string[];
  learnerUtterance: string;
  learnerLevel: number;
  politeness: Politeness;
}

export interface DetectedMistake {
  type: MistakeType;
  said: string;
  correction: string;
  explanation: string;
}

export interface TurnEvaluation {
  verdict: Verdict;
  understood: boolean;
  feedbackEn: string;
  naturalVersion: string;
  mistakes: DetectedMistake[];
}

export interface TurnResponse {
  evaluation: TurnEvaluation;
  reply: { japanese: string; kana: string; english: string };
  shouldEnd: boolean;
}

// JSON Schemas for Claude structured outputs. Every field is required; "no value" is an empty string,
// which the app treats as absent.

const mistakeSchema = {
  type: "object",
  properties: {
    type: { type: "string", enum: [...MISTAKE_TYPES] },
    said: { type: "string" },
    correction: { type: "string" },
    explanation: { type: "string" },
  },
  required: ["type", "said", "correction", "explanation"],
  additionalProperties: false,
};

export const evaluationSchema = {
  type: "object",
  properties: {
    verdict: { type: "string", enum: [...VERDICTS] },
    understood: { type: "boolean" },
    feedbackEn: { type: "string" },
    naturalVersion: { type: "string" },
    mistakes: { type: "array", items: mistakeSchema },
  },
  required: ["verdict", "understood", "feedbackEn", "naturalVersion", "mistakes"],
  additionalProperties: false,
};

export const turnSchema = {
  type: "object",
  properties: {
    evaluation: evaluationSchema,
    reply: {
      type: "object",
      properties: {
        japanese: { type: "string" },
        kana: { type: "string" },
        english: { type: "string" },
      },
      required: ["japanese", "kana", "english"],
      additionalProperties: false,
    },
    shouldEnd: { type: "boolean" },
  },
  required: ["evaluation", "reply", "shouldEnd"],
  additionalProperties: false,
};

// Request validation. The app is the only client, but the proxy is on the internet, so bound every input.

export class ValidationError extends Error {}

const MAX_TEXT = 500;
const MAX_HISTORY = 24;

function text(value: unknown, field: string, { optional = false } = {}): string {
  if (value === undefined || value === null) {
    if (optional) return "";
    throw new ValidationError(`${field} is required`);
  }
  if (typeof value !== "string") throw new ValidationError(`${field} must be a string`);
  return value.slice(0, MAX_TEXT);
}

function number(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new ValidationError(`${field} must be a number`);
  return Math.min(max, Math.max(min, value));
}

function object(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new ValidationError(`${field} must be an object`);
  return value as Record<string, unknown>;
}

function strings(value: unknown, field: string, limit = 20): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new ValidationError(`${field} must be an array`);
  return value.slice(0, limit).map((item, i) => text(item, `${field}[${i}]`));
}

function politeness(value: unknown, field: string): Politeness {
  if (!POLITENESS.includes(value as Politeness)) {
    throw new ValidationError(`${field} must be one of ${POLITENESS.join(", ")}`);
  }
  return value as Politeness;
}

export function parseTurnRequest(body: unknown): TurnRequest {
  const root = object(body, "body");
  const ctx = object(root.context, "context");
  const persona = object(ctx.persona, "context.persona");
  if (!Array.isArray(ctx.history)) throw new ValidationError("context.history must be an array");
  const history = ctx.history.slice(-MAX_HISTORY).map((raw, i): DialogueTurn => {
    const turn = object(raw, `context.history[${i}]`);
    if (turn.speaker !== "partner" && turn.speaker !== "learner") throw new ValidationError(`context.history[${i}].speaker is invalid`);
    return {
      speaker: turn.speaker,
      japanese: text(turn.japanese, `context.history[${i}].japanese`),
      english: text(turn.english, `context.history[${i}].english`, { optional: true }),
    };
  });
  return {
    context: {
      scenarioID: text(ctx.scenarioID, "context.scenarioID"),
      scenarioTitle: text(ctx.scenarioTitle, "context.scenarioTitle"),
      situation: text(ctx.situation, "context.situation"),
      persona: {
        name: text(persona.name, "persona.name"),
        role: text(persona.role, "persona.role"),
        personality: text(persona.personality, "persona.personality"),
        formality: politeness(persona.formality, "persona.formality"),
        style: text(persona.style, "persona.style"),
      },
      learnerName: text(ctx.learnerName, "context.learnerName", { optional: true }),
      learnerLevel: Math.round(number(ctx.learnerLevel, "context.learnerLevel", 1, 8)),
      englishSupport: number(ctx.englishSupport, "context.englishSupport", 0, 1),
      targetTerms: strings(ctx.targetTerms, "context.targetTerms"),
      recurringMistakeTypes: strings(ctx.recurringMistakeTypes, "context.recurringMistakeTypes"),
      history,
      turnIndex: Math.round(number(ctx.turnIndex, "context.turnIndex", 0, 50)),
      maxTurns: Math.round(number(ctx.maxTurns, "context.maxTurns", 1, 50)),
    },
    learnerUtterance: text(root.learnerUtterance, "learnerUtterance", { optional: true }),
    asrConfidence: root.asrConfidence === undefined ? undefined : number(root.asrConfidence, "asrConfidence", 0, 1),
  };
}

export function parseEvaluationRequest(body: unknown): EvaluationRequest {
  const root = object(body, "body");
  if (root.mode !== "recall" && root.mode !== "listening") throw new ValidationError("mode must be recall or listening");
  return {
    mode: root.mode,
    prompt: text(root.prompt, "prompt"),
    question: text(root.question, "question", { optional: true }),
    examples: strings(root.examples, "examples", 10),
    learnerUtterance: text(root.learnerUtterance, "learnerUtterance", { optional: true }),
    learnerLevel: Math.round(number(root.learnerLevel, "learnerLevel", 1, 8)),
    politeness: root.politeness === undefined ? "professional" : politeness(root.politeness, "politeness"),
  };
}
