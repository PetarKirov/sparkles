import indexData from "../../data/api/index.json";
import searchData from "../../data/api/search.json";
import typeData from "../../data/api/types.json";
import routeData from "../../generated/api-routes.json";

type ApiSymbol = {
  qualifiedName: string;
  name: string;
  kind: string;
  protection?: string;
  summary?: string;
  description?: string;
  attributes?: string[];
  parameters?: Array<{
    name?: string;
    type?: string;
    defaultValue?: string;
    storageClass?: string;
  }>;
  templateParams?: string[];
  constraints?: string[];
  returnType?: string;
  baseTypes?: string[];
  members?: ApiSymbol[];
  sourceFile?: string;
  line?: number;
  column?: number;
  paramDocs?: Array<{ name?: string; description?: string }>;
  returnsDoc?: string;
  throwsDoc?: string[];
  seeAlso?: string[];
  references?: string[];
  referencedBy?: string[];
  examples?: string[];
  unittests?: string[];
};

type ApiModule = {
  qualifiedName: string;
  summary?: string;
  description?: string;
  sourceFile?: string;
  fileName?: string;
  imports?: string[];
  publicImports?: string[];
  symbols?: ApiSymbol[];
};

type SearchEntry = {
  kind: string;
  name: string;
  qualifiedName: string;
  summary?: string;
  url: string;
};

type TypeGraphEdge = {
  from: string;
  to: string;
  type: string;
};

const modulesRecord = ((indexData as { modules?: Record<string, ApiModule> })
  .modules ?? {}) as Record<string, ApiModule>;
const searchEntries = (
  ((searchData as { index?: SearchEntry[] }).index ?? []) as SearchEntry[]
).slice();
const typeEdges = (
  ((typeData as { graph?: { edges?: TypeGraphEdge[] } }).graph?.edges ??
    []) as TypeGraphEdge[]
).slice();

const symbolMap = new Map<string, ApiSymbol>();
const moduleSymbolMap = new Map<string, ApiSymbol[]>();
const moduleBySymbol = new Map<string, string>();
const searchByQualifiedName = new Map(
  searchEntries.map((entry) => [entry.qualifiedName, entry]),
);
const relatedTypeEdges = new Map<string, TypeGraphEdge[]>();
const symbolRoutes = ((routeData as { symbols?: Record<string, string> })
  .symbols ?? {}) as Record<string, string>;
const uniqueBySimpleName = new Map<string, string | null>();

const moduleNames = Object.keys(modulesRecord).sort((a, b) =>
  a.localeCompare(b),
);

const walkSymbols = (moduleName: string, symbols: ApiSymbol[]) => {
  for (const symbol of symbols) {
    symbolMap.set(symbol.qualifiedName, symbol);
    moduleBySymbol.set(symbol.qualifiedName, moduleName);
    if (!moduleSymbolMap.has(moduleName)) {
      moduleSymbolMap.set(moduleName, []);
    }
    moduleSymbolMap.get(moduleName)?.push(symbol);
    if (symbol.members && symbol.members.length > 0) {
      walkSymbols(moduleName, symbol.members);
    }
  }
};

for (const moduleName of moduleNames) {
  const symbols = modulesRecord[moduleName]?.symbols ?? [];
  walkSymbols(moduleName, symbols);
}

for (const qualifiedName of symbolMap.keys()) {
  const parts = qualifiedName.split(".");
  const simpleName = parts[parts.length - 1];
  const existing = uniqueBySimpleName.get(simpleName);
  if (existing === undefined) {
    uniqueBySimpleName.set(simpleName, qualifiedName);
  } else if (existing !== qualifiedName) {
    uniqueBySimpleName.set(simpleName, null);
  }
}

for (const edge of typeEdges) {
  if (!relatedTypeEdges.has(edge.from)) {
    relatedTypeEdges.set(edge.from, []);
  }
  relatedTypeEdges.get(edge.from)?.push(edge);
}

const modulePath = (moduleName: string) =>
  `/api/modules/${moduleName.replaceAll(".", "/")}`;
const trySymbolPath = (qualifiedName: string): string | null => {
  const fromGenerated = symbolRoutes[qualifiedName];
  if (fromGenerated) {
    return fromGenerated;
  }

  const moduleName = moduleBySymbol.get(qualifiedName);
  if (!moduleName) {
    return null;
  }

  const modulePrefix = `${moduleName}.`;
  if (!qualifiedName.startsWith(modulePrefix)) {
    return null;
  }

  const remainder = qualifiedName.slice(modulePrefix.length).split(".");
  return `/api/${moduleName.replaceAll(".", "/")}/${remainder.join("/")}`;
};

const symbolPath = (qualifiedName: string) => {
  const route = trySymbolPath(qualifiedName);
  if (!route) {
    throw new Error(`Missing symbol route: ${qualifiedName}`);
  }
  return route;
};

const cleanToken = (token: string): string =>
  token.replace(/^[^A-Za-z_]+|[^A-Za-z0-9_.]+$/g, "");

const resolveSymbolReference = (
  reference: string,
  contextModuleName?: string,
): { qualifiedName: string; path: string } | null => {
  const cleaned = cleanToken(reference.trim());
  if (!cleaned) {
    return null;
  }

  const directPath = trySymbolPath(cleaned);
  if (directPath) {
    return { qualifiedName: cleaned, path: directPath };
  }

  if (!cleaned.includes(".") && contextModuleName) {
    const inModule = `${contextModuleName}.${cleaned}`;
    const inModulePath = trySymbolPath(inModule);
    if (inModulePath) {
      return { qualifiedName: inModule, path: inModulePath };
    }
  }

  if (!cleaned.includes(".")) {
    const uniqueQualifiedName = uniqueBySimpleName.get(cleaned);
    if (uniqueQualifiedName) {
      const uniquePath = trySymbolPath(uniqueQualifiedName);
      if (uniquePath) {
        return { qualifiedName: uniqueQualifiedName, path: uniquePath };
      }
    }
  }

  return null;
};

type LinkedTextPart = { text: string; href?: string; qualifiedName?: string };

const linkifyTypeText = (
  text: string,
  contextModuleName?: string,
): LinkedTextPart[] => {
  const parts: LinkedTextPart[] = [];
  const tokenPattern = /[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/g;
  let lastIndex = 0;
  let match = tokenPattern.exec(text);
  while (match) {
    const start = match.index;
    const token = match[0];
    if (start > lastIndex) {
      parts.push({ text: text.slice(lastIndex, start) });
    }
    const resolved = resolveSymbolReference(token, contextModuleName);
    if (resolved) {
      parts.push({
        text: token,
        href: resolved.path,
        qualifiedName: resolved.qualifiedName,
      });
    } else {
      parts.push({ text: token });
    }
    lastIndex = tokenPattern.lastIndex;
    match = tokenPattern.exec(text);
  }

  if (lastIndex < text.length) {
    parts.push({ text: text.slice(lastIndex) });
  }

  return parts;
};

export {
  linkifyTypeText,
  moduleBySymbol,
  moduleNames,
  modulePath,
  modulesRecord,
  moduleSymbolMap,
  relatedTypeEdges,
  resolveSymbolReference,
  searchByQualifiedName,
  searchEntries,
  symbolMap,
  symbolPath,
  trySymbolPath,
};

export type { ApiModule, ApiSymbol, SearchEntry, TypeGraphEdge };
