<script setup lang="ts">
import { computed } from "vue";
import {
  modulePath,
  modulesRecord,
  searchEntries,
  symbolPath,
} from "./api-data";

const props = defineProps<{
  moduleName: string;
}>();

const moduleData = computed(() => modulesRecord[props.moduleName]);
if (!moduleData.value) {
  throw new Error(`API module not found: ${props.moduleName}`);
}

const moduleSymbols = computed(() =>
  searchEntries.filter((entry) =>
    entry.qualifiedName.startsWith(`${props.moduleName}.`),
  ),
);
</script>

<template>
  <section class="api-page">
    <h1>{{ moduleName }}</h1>
    <p v-if="moduleData.summary">{{ moduleData.summary }}</p>
    <p v-if="moduleData.description">{{ moduleData.description }}</p>
    <p class="api-meta">
      Source:
      <code>{{
        moduleData.sourceFile ?? moduleData.fileName ?? "unknown"
      }}</code>
    </p>

    <div v-if="(moduleData.imports?.length ?? 0) > 0">
      <h2>Imports</h2>
      <ul class="api-list">
        <li v-for="importName in moduleData.imports" :key="importName">
          {{ importName }}
        </li>
      </ul>
    </div>

    <div v-if="(moduleData.publicImports?.length ?? 0) > 0">
      <h2>Public Imports</h2>
      <ul class="api-list">
        <li v-for="importName in moduleData.publicImports" :key="importName">
          <a :href="modulePath(importName)">{{ importName }}</a>
        </li>
      </ul>
    </div>

    <h2>Symbols</h2>
    <ul class="api-list">
      <li v-for="entry in moduleSymbols" :key="entry.qualifiedName">
        <a :href="symbolPath(entry.qualifiedName)">{{ entry.name }}</a>
        <span class="api-muted">({{ entry.kind }})</span>
      </li>
    </ul>
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
</style>
