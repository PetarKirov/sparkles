import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = resolve(__dirname, "../../..");

const dataDir = resolve(repoRoot, "docs/.vitepress/data/api");
const docsDir = resolve(repoRoot, "docs");
const apiDir = resolve(repoRoot, "docs/api");
const generatedDir = resolve(repoRoot, "docs/.vitepress/generated");
const vitepressCacheDir = resolve(repoRoot, "docs/.vitepress/cache");
const vitepressTempDir = resolve(repoRoot, "docs/.vitepress/.temp");

const indexData = JSON.parse(
  readFileSync(resolve(dataDir, "index.json"), "utf8"),
);
const searchData = JSON.parse(
  readFileSync(resolve(dataDir, "search.json"), "utf8"),
);

const modules = Object.keys(indexData.modules ?? {}).sort();
const searchEntries = [...(searchData.index ?? [])].sort((a, b) =>
  a.qualifiedName.localeCompare(b.qualifiedName),
);
const uniqueSearchEntries = [
  ...new Map(
    searchEntries.map((entry) => [entry.qualifiedName, entry]),
  ).values(),
];

const stableHash = (text) => {
  let h = 5381;
  for (const ch of text) {
    h = (h * 33) ^ ch.charCodeAt(0);
  }
  return (h >>> 0).toString(16);
};

const sanitizeSegment = (text) =>
  text
    .replace(/[^A-Za-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    .slice(0, 80) || "symbol";

const sanitizeQualifiedName = (text) =>
  text
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    .toLowerCase()
    .slice(0, 220) || "symbol";

const baseSymbolRoute = (entry) =>
  `/api/symbols/${sanitizeQualifiedName(entry.qualifiedName)}`;

const hasRouteConflict = (route, usedRoutes) => {
  for (const existingRoute of usedRoutes) {
    if (
      existingRoute === route ||
      existingRoute.startsWith(`${route}/`) ||
      route.startsWith(`${existingRoute}/`)
    ) {
      return true;
    }
  }
  return false;
};

const getCollisionSafeRoute = (entry, usedRoutes) => {
  const baseRoute = baseSymbolRoute(entry);
  if (!hasRouteConflict(baseRoute, usedRoutes)) {
    return { route: baseRoute, collided: false };
  }

  const suffixBase = `${baseRoute}--${sanitizeSegment(entry.kind)}`;
  if (!hasRouteConflict(suffixBase, usedRoutes)) {
    return { route: suffixBase, collided: true };
  }

  const hashedSuffix = `${suffixBase}-${stableHash(entry.qualifiedName).slice(0, 8)}`;
  if (!hasRouteConflict(hashedSuffix, usedRoutes)) {
    return { route: hashedSuffix, collided: true };
  }

  for (let i = 1; i < 1_000; i += 1) {
    const withCounter = `${hashedSuffix}-${i}`;
    if (!hasRouteConflict(withCounter, usedRoutes)) {
      return { route: withCounter, collided: true };
    }
  }

  throw new Error(
    `Unable to resolve route collision for symbol: ${entry.qualifiedName}`,
  );
};

const symbolRouteMap = {};
const usedSymbolRoutes = [];
let collisionCount = 0;

rmSync(apiDir, { recursive: true, force: true });
rmSync(vitepressCacheDir, { recursive: true, force: true });
rmSync(vitepressTempDir, { recursive: true, force: true });
mkdirSync(apiDir, { recursive: true });
mkdirSync(generatedDir, { recursive: true });

writeFileSync(
  resolve(apiDir, "index.md"),
  `---\ntitle: API Index\n---\n\n<ApiIndexPage />\n`,
  "utf8",
);

const modulePageLink = (moduleName) =>
  `/api/modules/${moduleName.replaceAll(".", "/")}`;

for (const moduleName of modules) {
  const path = resolve(apiDir, "modules", ...moduleName.split("."), "index.md");
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(
    path,
    `---\ntitle: ${moduleName}\n---\n\n<ApiModulePage module-name="${moduleName}" />\n`,
    "utf8",
  );
}

for (const entry of uniqueSearchEntries) {
  const collisionSafe = getCollisionSafeRoute(entry, usedSymbolRoutes);
  const pathRoute = collisionSafe.route;
  symbolRouteMap[entry.qualifiedName] = pathRoute;
  usedSymbolRoutes.push(pathRoute);
  if (collisionSafe.collided) {
    collisionCount += 1;
  }

  const symbolPath = resolve(docsDir, `${pathRoute.replace(/^\//, "")}.md`);
  mkdirSync(dirname(symbolPath), { recursive: true });
  writeFileSync(
    symbolPath,
    `---\ntitle: ${entry.qualifiedName}\n---\n\n<ApiSymbolPage qualified-name="${entry.qualifiedName}" />\n`,
    "utf8",
  );
}

const moduleItems = modules.map((moduleName) => {
  const moduleSymbols = uniqueSearchEntries
    .filter((entry) => entry.qualifiedName.startsWith(`${moduleName}.`))
    .map((entry) => ({
      text: `${entry.name} (${entry.kind})`,
      link: symbolRouteMap[entry.qualifiedName],
    }));

  return {
    text: moduleName,
    link: modulePageLink(moduleName),
    collapsed: true,
    items: moduleSymbols,
  };
});

const apiSidebar = [
  {
    text: "API",
    items: [{ text: "Index", link: "/api/" }],
  },
  ...moduleItems,
];

const sidebarModule = `export const apiSidebar = ${JSON.stringify(apiSidebar, null, 2)};\n`;
writeFileSync(resolve(generatedDir, "api-sidebar.mjs"), sidebarModule, "utf8");
writeFileSync(
  resolve(generatedDir, "api-routes.json"),
  JSON.stringify({ symbols: symbolRouteMap }, null, 2),
  "utf8",
);

if (Object.keys(symbolRouteMap).length !== uniqueSearchEntries.length) {
  throw new Error(
    `Route map incomplete: mapped ${Object.keys(symbolRouteMap).length} of ${uniqueSearchEntries.length} unique symbols`,
  );
}

const manifestPath = resolve(generatedDir, "api-manifest.json");
let manifest = {};
try {
  manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
} catch {
  manifest = {};
}
manifest.routesGenerated = uniqueSearchEntries.length + modules.length + 1;
manifest.symbolRouteCollisions = collisionCount;
manifest.generatedPagesAt = new Date().toISOString();
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2), "utf8");
