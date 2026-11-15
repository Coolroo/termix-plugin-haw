// Writes src/shared/release-files.ts: the SHA-256 of each file a host's
// setup downloads, so the setup the page shows checks exactly what this
// version released. Run after a change to a file under vmctl/; a test fails
// when the hashes are old. `--check` only compares.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const root = new URL("..", import.meta.url);
const files = { "hyper-v": ["vmctl.ps1", "install.ps1"] };
const dirs = { "hyper-v": "vmctl/hyperv" };

const sha = (path) =>
  createHash("sha256")
    .update(readFileSync(new URL(path, root)))
    .digest("hex")
    .toUpperCase();

const lines = [
  "// Made by tools/release-files.mjs. Do not edit: run `node tools/release-files.mjs`.",
  "",
  'export const REPO_RAW = "https://raw.githubusercontent.com/Coolroo/termix-plugin-haw";',
  "",
  "/** SHA-256 (upper case hex) of each file a host's setup downloads. */",
  "export const RELEASE_FILES = {",
];
for (const [iface, names] of Object.entries(files)) {
  lines.push(`  "${iface}": {`);
  for (const name of names)
    lines.push(`    "${name}": "${sha(`${dirs[iface]}/${name}`)}",`);
  lines.push("  },");
}
lines.push("} as const;", "");
const text = lines.join("\n");
const target = new URL("src/shared/release-files.ts", root);
if (process.argv.includes("--check")) {
  const current = readFileSync(target, "utf8");
  if (current !== text) {
    console.error(
      "src/shared/release-files.ts is old: run node tools/release-files.mjs",
    );
    process.exit(1);
  }
  console.log("release-files: up to date");
} else {
  writeFileSync(target, text);
  console.log("wrote src/shared/release-files.ts");
}
