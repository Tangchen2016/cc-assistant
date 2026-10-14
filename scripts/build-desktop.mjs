import { build as bundle } from "esbuild";
import { build as buildUI } from "vite";
import tailwindcss from "@tailwindcss/postcss";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = resolve(process.env.DESKTOP_OUTPUT_DIR || join(root, "outputs", "desktop"));
const buildRoot = join(root, "dist", "desktop");
const app = join(output, "cc助手.app");
const resources = join(app, "Contents", "Resources");
const macOS = join(app, "Contents", "MacOS");
const runtimeVersion = "22.22.3";
const cache = join(root, "work", "desktop-runtime");
const run = (command, args) => execFileSync(command, args, { cwd: root, stdio: "inherit" });
const mihomo = JSON.parse(readFileSync(join(root, "config", "mihomo-runtime.json"), "utf8"));

mkdirSync(buildRoot, { recursive: true });
await buildUI({
  configFile: false,
  root: join(root, "desktop", "ui"),
  css: { postcss: { plugins: [tailwindcss()] } },
  esbuild: { jsx: "automatic" },
  build: { outDir: join(buildRoot, "public"), emptyOutDir: true, sourcemap: false },
});
await bundle({ entryPoints: [join(root, "desktop", "src", "server.ts")], outfile: join(buildRoot, "server.mjs"), platform: "node", format: "esm", bundle: true, target: "node22", sourcemap: false, banner: { js: "import {createRequire as __desktopCreateRequire} from 'node:module'; const require = __desktopCreateRequire(import.meta.url);" } });
rmSync(app, { recursive: true, force: true });
mkdirSync(resources, { recursive: true }); mkdirSync(macOS, { recursive: true }); mkdirSync(cache, { recursive: true });
cpSync(join(buildRoot, "public"), join(resources, "public"), { recursive: true });
cpSync(join(buildRoot, "server.mjs"), join(resources, "server.mjs"));
cpSync(join(root, "desktop", "native", "Info.plist"), join(app, "Contents", "Info.plist"));

// Bundle both official runtimes, verifying their downloaded archives against Node's checksum list.
const sumsPath = join(cache, `SHASUMS256-${runtimeVersion}.txt`);
run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--max-time", "60", "--output", sumsPath, `https://nodejs.org/dist/v${runtimeVersion}/SHASUMS256.txt`]);
const sums = readFileSync(sumsPath, "utf8");
for (const architecture of ["arm64", "x64"]) {
  const name = `node-v${runtimeVersion}-darwin-${architecture}.tar.gz`;
  const archive = join(cache, name);
  const expected = sums.split("\n").find((line) => line.trim().endsWith(`  ${name}`))?.split(/\s+/)[0];
  if (!expected || !/^[a-f0-9]{64}$/.test(expected)) throw new Error("Official Node runtime checksum missing");
  if (!existsSync(archive)) run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--max-time", "180", "--output", archive, `https://nodejs.org/dist/v${runtimeVersion}/${name}`]);
  const actual = createHash("sha256").update(readFileSync(archive)).digest("hex");
  if (actual !== expected) { rmSync(archive); throw new Error("Downloaded Node runtime checksum mismatch"); }
  run("/usr/bin/tar", ["-xzf", archive, "-C", cache, `node-v${runtimeVersion}-darwin-${architecture}/bin/node`, `node-v${runtimeVersion}-darwin-${architecture}/LICENSE`]);
  const destination = join(resources, `node-${architecture}`);
  cpSync(join(cache, `node-v${runtimeVersion}-darwin-${architecture}`, "bin", "node"), destination);
  chmodSync(destination, 0o755);
  cpSync(join(cache, `node-v${runtimeVersion}-darwin-${architecture}`, "LICENSE"), join(resources, "Node-LICENSE.txt"));
  run("/usr/bin/codesign", ["--force", "--sign", "-", destination]);
}
for (const architecture of ["arm64", "x64"]) {
  const asset = mihomo.assets[architecture];
  const archive = join(cache, asset.name);
  if (!existsSync(archive)) run("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--max-time", "180", "--output", archive, `https://github.com/MetaCubeX/mihomo/releases/download/v${mihomo.version}/${asset.name}`]);
  const bytes = readFileSync(archive);
  if (createHash("sha256").update(bytes).digest("hex") !== asset.sha256) { rmSync(archive); throw new Error("Official Mihomo runtime checksum mismatch"); }
  const destination = join(resources, `mihomo-${architecture}`);
  writeFileSync(destination, gunzipSync(bytes), { mode: 0o755 });
  run("/usr/bin/codesign", ["--force", "--sign", "-", destination]);
}
const sourceArchive = join(cache, `mihomo-source-v${mihomo.version}.tar.gz`);
if (!existsSync(sourceArchive)) run("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--max-time", "180", "--output", sourceArchive, `https://github.com/MetaCubeX/mihomo/archive/refs/tags/v${mihomo.version}.tar.gz`]);
cpSync(sourceArchive, join(resources, `Mihomo-Source-v${mihomo.version}.tar.gz`));
const license = execFileSync("/usr/bin/tar", ["-xOf", sourceArchive, `mihomo-${mihomo.version}/LICENSE`], { encoding: "utf8" });
writeFileSync(join(resources, "Mihomo-LICENSE.txt"), license);
const nativeSources = readdirSync(join(root, "desktop", "native")).filter((name) => name.endsWith(".swift") && name !== "MakeIcon.swift").map((name) => join(root, "desktop", "native", name));
for (const architecture of ["arm64", "x86_64"]) {
  run("/usr/bin/xcrun", ["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-target", `${architecture}-apple-macosx14.0`, ...nativeSources, "-o", join(buildRoot, `SubscriptionStudio-${architecture}`)]);
}
run("/usr/bin/lipo", ["-create", join(buildRoot, "SubscriptionStudio-arm64"), join(buildRoot, "SubscriptionStudio-x86_64"), "-output", join(macOS, "SubscriptionStudio")]);
run("/usr/bin/swift", [join(root, "desktop", "native", "MakeIcon.swift"), join(buildRoot, "AppIcon.iconset")]);
run("/usr/bin/iconutil", ["--convert", "icns", join(buildRoot, "AppIcon.iconset"), "--output", join(resources, "AppIcon.icns")]);
writeFileSync(join(resources, "ThirdParty-LICENSES.txt"), ["Subscription Studio uses React, ReactDOM, Lucide, YAML and ipaddr.js.", ...["react", "react-dom", "lucide-react", "yaml", "ipaddr.js"].map((name) => {
  const base = join(root, "node_modules", name);
  const license = ["LICENSE", "LICENSE.md", "LICENSE.txt", "License"].map((file) => join(base, file)).find(existsSync);
  return `${name}\n${license ? readFileSync(license, "utf8") : "See the package's distribution for license terms."}`;
})].join("\n\n"));
run("/usr/bin/codesign", ["--force", "--sign", "-", app]);
run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]);
const zip = join(output, "cc助手-macOS.zip");
rmSync(zip, { force: true });
run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, zip]);
process.stdout.write(`Built ${app}\nPackaged ${zip}\n`);
