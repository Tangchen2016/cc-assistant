import { bindings, defineConfig, triggers } from "cf/config";
export default defineConfig({
  worker: {
    name: "cc-mail-assistant",
    entrypoint: "./src/index.ts",
    workersDev: false,
    triggers: [triggers.fetch({ pattern: "tangchen02.top/apps/cc-assistant/mail-api/*", zone: "tangchen02.top" })],
    compatibilityDate: "2026-10-20",
    env: {
      MAIL: bindings.kv(),
      API_KEY: bindings.secret(),
      DOMAIN: bindings.text("tangchen02.top"),
      FORWARD_TO: bindings.text("tangchen1994@icloud.com"),
    },
    observability: { enabled: true, traces: { enabled: true } },
  },
});
