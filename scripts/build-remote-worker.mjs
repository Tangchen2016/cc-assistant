import { build } from "esbuild";

await build({
  entryPoints: ["cloud/remote-worker.ts"], outfile: "dist/remote-worker/index.js",
  bundle: true, format: "esm", platform: "browser", target: "es2022",
  external: ["cloudflare:workers"], sourcemap: false, minify: true,
});
