<script setup lang="ts">
import {
  moduleNames,
  modulePath,
  modulesRecord,
  searchEntries,
  symbolPath,
} from "./api-data";
</script>

<template>
  <section class="api-page">
    <h1>API Index</h1>
    <p class="api-meta">
      Modules: <strong>{{ moduleNames.length }}</strong> | Symbols:
      <strong>{{ searchEntries.length }}</strong>
    </p>

    <h2>Modules</h2>
    <ul class="api-list">
      <li v-for="moduleName in moduleNames" :key="moduleName">
        <a :href="modulePath(moduleName)">{{ moduleName }}</a>
        <span v-if="modulesRecord[moduleName]?.summary" class="api-muted">
          - {{ modulesRecord[moduleName]?.summary }}
        </span>
      </li>
    </ul>

    <h2>Symbols</h2>
    <ul class="api-list">
      <li v-for="entry in searchEntries" :key="entry.qualifiedName">
        <a :href="symbolPath(entry.qualifiedName)">{{ entry.qualifiedName }}</a>
        <span class="api-kind">({{ entry.kind }})</span>
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

.api-kind {
  color: var(--vp-c-text-3);
  margin-left: 0.35rem;
}
</style>
