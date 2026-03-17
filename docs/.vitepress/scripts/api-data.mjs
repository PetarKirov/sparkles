import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = resolve(__dirname, "../../..");

const defaultSourcePath = "libs/core-cli/src";
const sourcePath =
  process.argv[2] ?? process.env.DOCS_API_SOURCE ?? defaultSourcePath;
const outputPath = "docs/.vitepress/data/api";

const run = spawnSync(
  "dub",
  ["run", ":sparkle-docs", "--", sourcePath, "-o", outputPath],
  {
    cwd: repoRoot,
    stdio: "inherit",
  },
);

if (run.status !== 0) {
  process.exit(run.status ?? 1);
}

const indexPath = resolve(repoRoot, outputPath, "index.json");
const searchPath = resolve(repoRoot, outputPath, "search.json");
const typesPath = resolve(repoRoot, outputPath, "types.json");

const indexData = JSON.parse(readFileSync(indexPath, "utf8"));
const searchData = JSON.parse(readFileSync(searchPath, "utf8"));
const typesData = JSON.parse(readFileSync(typesPath, "utf8"));

const generatedDir = resolve(repoRoot, "docs/.vitepress/generated");
mkdirSync(generatedDir, { recursive: true });

const manifest = {
  sourcePath,
  generated: new Date().toISOString(),
  parserGenerated: indexData.generated,
  moduleCount: Object.keys(indexData.modules ?? {}).length,
  symbolCount: (searchData.index ?? []).length,
  typeNodeCount: (typesData.graph?.nodes ?? []).length,
  typeEdgeCount: (typesData.graph?.edges ?? []).length,
};

writeFileSync(
  resolve(generatedDir, "api-manifest.json"),
  JSON.stringify(manifest, null, 2),
  "utf8",
);
