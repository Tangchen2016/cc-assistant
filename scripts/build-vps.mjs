import { build } from 'esbuild';
await build({ entryPoints: ['server/vps-service.ts'], outfile: 'dist/vps/server.mjs', bundle: true, platform: 'node', format: 'esm', target: 'node22', minify: true, banner: { js: "import {createRequire} from 'node:module';const require=createRequire(import.meta.url);" } });
