import { createClaudeCoach, createMockCoach } from "./coach.ts";
import { createCoachServer } from "./server.ts";

const appToken = process.env.APP_TOKEN ?? "";
if (appToken.length < 16) {
  console.error("Set APP_TOKEN to a random secret of at least 16 characters (the app sends it as a Bearer token).");
  process.exit(1);
}

const mock = process.env.COACH_MOCK === "1";
const effort = process.env.COACH_EFFORT as "low" | "medium" | "high" | undefined;
const coach = mock ? createMockCoach() : createClaudeCoach({ model: process.env.COACH_MODEL, effort });
const port = Number(process.env.PORT ?? 8787);

createCoachServer({ coach, appToken }).listen(port, () => {
  console.log(`Hanaseru coach proxy on :${port} (${mock ? "mock coach" : `model ${coach.model}`})`);
});
