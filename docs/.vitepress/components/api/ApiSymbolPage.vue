<script setup lang="ts">
import { computed } from "vue";
import {
  linkifyTypeText,
  moduleBySymbol,
  modulePath,
  relatedTypeEdges,
  resolveSymbolReference,
  symbolMap,
  symbolPath,
} from "./api-data";

const props = defineProps<{
  qualifiedName: string;
}>();

const symbol = computed(() => symbolMap.get(props.qualifiedName));
if (!symbol.value) {
  throw new Error(`API symbol not found: ${props.qualifiedName}`);
}

const moduleName = computed(() => moduleBySymbol.get(props.qualifiedName));
if (!moduleName.value) {
  throw new Error(`Module not found for symbol: ${props.qualifiedName}`);
}

const signature = computed(() => {
  const current = symbol.value;
  if (!current) {
    return "";
  }

  const params = (current.parameters ?? [])
    .map((param) => `${param.type ?? ""} ${param.name ?? ""}`.trim())
    .join(", ");
  const templateParams = (current.templateParams ?? []).join(", ");
  const templatePart = templateParams ? `!(${templateParams})` : "";

  if (
    current.kind === "function" ||
    current.kind === "constructor" ||
    current.kind === "destructor"
  ) {
    return `${current.returnType ?? "void"} ${current.name}${templatePart}(${params})`.trim();
  }

  return `${current.kind} ${current.name}${templatePart}`.trim();
});

const outgoingTypeEdges = computed(
  () => relatedTypeEdges.get(props.qualifiedName) ?? [],
);
const contextModule = computed(() => moduleName.value ?? undefined);

const linkifiedSignature = computed(() =>
  linkifyTypeText(signature.value, contextModule.value),
);
const linkifiedBaseTypes = computed(() =>
  (symbol.value?.baseTypes ?? []).map((typeName) => ({
    typeName,
    resolved: resolveSymbolReference(typeName, contextModule.value),
  })),
);
const linkifiedReferences = computed(() =>
  (symbol.value?.references ?? []).map((reference) => ({
    reference,
    resolved: resolveSymbolReference(reference, contextModule.value),
  })),
);
const linkifiedReferencedBy = computed(() =>
  (symbol.value?.referencedBy ?? []).map((reference) => ({
    reference,
    resolved: resolveSymbolReference(reference, contextModule.value),
  })),
);
const linkifiedSeeAlso = computed(() =>
  (symbol.value?.seeAlso ?? []).map((reference) => ({
    reference,
    resolved: resolveSymbolReference(reference, contextModule.value),
  })),
);
</script>

<template>
  <section class="api-page">
    <p class="api-meta">
      <a :href="modulePath(moduleName ?? '')">{{ moduleName }}</a>
    </p>
    <h1>{{ symbol?.name }}</h1>

    <p class="api-meta">
      {{ symbol?.kind
      }}<span v-if="symbol?.protection"> | {{ symbol?.protection }}</span>
    </p>
    <p v-if="signature" class="api-signature">
      <code>
        <template
          v-for="(part, idx) in linkifiedSignature"
          :key="`signature-${idx}`"
        >
          <a v-if="part.href" :href="part.href">{{ part.text }}</a>
          <template v-else>{{ part.text }}</template>
        </template>
      </code>
    </p>
    <p v-if="symbol?.summary">{{ symbol.summary }}</p>
    <p v-if="symbol?.description">{{ symbol.description }}</p>

    <p class="api-meta">
      Source:
      <code
        >{{ symbol?.sourceFile ?? "unknown" }}:{{ symbol?.line ?? 0 }}:{{
          symbol?.column ?? 0
        }}</code
      >
    </p>

    <div v-if="(symbol?.attributes?.length ?? 0) > 0">
      <h2>Attributes</h2>
      <ul class="api-list">
        <li v-for="attribute in symbol?.attributes" :key="attribute">
          <code>{{ attribute }}</code>
        </li>
      </ul>
    </div>

    <div v-if="(symbol?.constraints?.length ?? 0) > 0">
      <h2>Constraints</h2>
      <ul class="api-list">
        <li v-for="constraint in symbol?.constraints" :key="constraint">
          <code>{{ constraint }}</code>
        </li>
      </ul>
    </div>

    <div v-if="(symbol?.baseTypes?.length ?? 0) > 0">
      <h2>Base Types</h2>
      <ul class="api-list">
        <li v-for="entry in linkifiedBaseTypes" :key="entry.typeName">
          <a v-if="entry.resolved" :href="entry.resolved.path">{{
            entry.typeName
          }}</a>
          <template v-else>{{ entry.typeName }}</template>
        </li>
      </ul>
    </div>

    <div v-if="(symbol?.parameters?.length ?? 0) > 0">
      <h2>Signature Parameters</h2>
      <ul class="api-list">
        <li v-for="param in symbol?.parameters" :key="param.name">
          <code>
            <template
              v-for="(part, idx) in linkifyTypeText(
                param.type ?? '',
                contextModule,
              )"
              :key="`${param.name ?? 'param'}-${idx}`"
            >
              <a v-if="part.href" :href="part.href">{{ part.text }}</a>
              <template v-else>{{ part.text }}</template>
            </template>
            <template v-if="param.name"> {{ param.name }}</template>
            <template v-if="param.defaultValue">
              = {{ param.defaultValue }}</template
            >
          </code>
        </li>
      </ul>
    </div>

    <div v-if="(symbol?.paramDocs?.length ?? 0) > 0">
      <h2>Parameters</h2>
      <ul class="api-list">
        <li v-for="param in symbol?.paramDocs" :key="param.name">
          <code>{{ param.name }}</code>
          <span v-if="param.description"> - {{ param.description }}</span>
        </li>
      </ul>
    </div>

    <div v-if="symbol?.returnsDoc">
      <h2>Returns</h2>
      <p>{{ symbol.returnsDoc }}</p>
    </div>

    <div v-if="(symbol?.throwsDoc?.length ?? 0) > 0">
      <h2>Throws</h2>
      <ul class="api-list">
        <li v-for="throwsDoc in symbol?.throwsDoc" :key="throwsDoc">
          {{ throwsDoc }}
        </li>
      </ul>
    </div>

    <div v-if="(symbol?.examples?.length ?? 0) > 0">
      <h2>Ddoc Examples</h2>
      <pre
        v-for="(example, idx) in symbol?.examples"
        :key="`${props.qualifiedName}-example-${idx}`"
      ><code>{{ example }}</code></pre>
    </div>

    <div v-if="(symbol?.unittests?.length ?? 0) > 0">
      <h2>Unittests</h2>
      <pre
        v-for="(testCode, idx) in symbol?.unittests"
        :key="`${props.qualifiedName}-unittest-${idx}`"
      ><code>{{ testCode }}</code></pre>
    </div>

    <div v-if="(symbol?.members?.length ?? 0) > 0">
      <h2>Members</h2>
      <ul class="api-list">
        <li v-for="member in symbol?.members" :key="member.qualifiedName">
          <a :href="symbolPath(member.qualifiedName)">{{ member.name }}</a>
          <span class="api-muted">({{ member.kind }})</span>
        </li>
      </ul>
    </div>

    <div v-if="linkifiedReferences.length > 0">
      <h2>References</h2>
      <ul class="api-list">
        <li v-for="entry in linkifiedReferences" :key="entry.reference">
          <a v-if="entry.resolved" :href="entry.resolved.path">{{
            entry.reference
          }}</a>
          <template v-else>{{ entry.reference }}</template>
        </li>
      </ul>
    </div>

    <div v-if="linkifiedReferencedBy.length > 0">
      <h2>Referenced By</h2>
      <ul class="api-list">
        <li v-for="entry in linkifiedReferencedBy" :key="entry.reference">
          <a v-if="entry.resolved" :href="entry.resolved.path">{{
            entry.reference
          }}</a>
          <template v-else>{{ entry.reference }}</template>
        </li>
      </ul>
    </div>

    <div v-if="linkifiedSeeAlso.length > 0">
      <h2>See Also</h2>
      <ul class="api-list">
        <li v-for="entry in linkifiedSeeAlso" :key="entry.reference">
          <a v-if="entry.resolved" :href="entry.resolved.path">{{
            entry.reference
          }}</a>
          <template v-else>{{ entry.reference }}</template>
        </li>
      </ul>
    </div>

    <div v-if="outgoingTypeEdges.length > 0">
      <h2>Type Graph Links</h2>
      <ul class="api-list">
        <li
          v-for="edge in outgoingTypeEdges"
          :key="`${edge.type}:${edge.from}:${edge.to}`"
        >
          <code>{{ edge.type }}</code>
          <template v-if="resolveSymbolReference(edge.from, contextModule)">
            <a :href="resolveSymbolReference(edge.from, contextModule)?.path">{{
              edge.from
            }}</a>
          </template>
          <template v-else>{{ edge.from }}</template>
          <span> -> </span>
          <template v-if="resolveSymbolReference(edge.to, contextModule)">
            <a :href="resolveSymbolReference(edge.to, contextModule)?.path">{{
              edge.to
            }}</a>
          </template>
          <template v-else>{{ edge.to }}</template>
        </li>
      </ul>
    </div>
  </section>
</template>

<style scoped>
.api-page {
  display: grid;
  gap: 0.8rem;
}

.api-list {
  margin: 0;
  padding-left: 1.25rem;
}

.api-meta,
.api-muted {
  color: var(--vp-c-text-2);
}

pre {
  margin: 0;
}

.api-signature a {
  text-decoration: underline;
}
</style>
