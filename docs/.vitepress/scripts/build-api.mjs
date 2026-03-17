import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = resolve(__dirname, "../../..");

const sourcePathArg = process.argv[2];

const runNodeScript = (scriptPath, args = []) => {
  const run = spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: repoRoot,
    stdio: "inherit",
  });

  if (run.status !== 0) {
    process.exit(run.status ?? 1);
  }
};

runNodeScript(
  "docs/.vitepress/scripts/api-data.mjs",
  sourcePathArg ? [sourcePathArg] : [],
);
runNodeScript("docs/.vitepress/scripts/generate-api-pages.mjs");
