<script setup lang="ts">
// The metadata strip above a specification's title.
//
// A specification states its acceptance state, owner and review date as YAML
// front matter (see docs/guidelines/spec-prose.md, "Front Matter"), so the
// prose never has to. This renders those fields; a page without a recognized
// `status` renders nothing.
import { computed } from 'vue';
import { useData, withBase } from 'vitepress';

const { frontmatter } = useData();

const states = {
  draft: { label: 'Draft', type: 'warning' },
  accepted: { label: 'Accepted', type: 'tip' },
  superseded: { label: 'Superseded', type: 'danger' },
} as const;

const meta = computed(() => {
  const fm = frontmatter.value;
  const state = states[fm.status as keyof typeof states];
  if (!state) return null;
  // YAML reads `2026-08-17` as a Date, which reaches the client as an ISO
  // timestamp string; show the calendar date either way.
  const raw =
    fm.reviewed instanceof Date
      ? fm.reviewed.toISOString()
      : String(fm.reviewed ?? '');
  const reviewed = /^\d{4}-\d{2}-\d{2}/.exec(raw)?.[0] ?? raw;
  const by = typeof fm.supersededBy === 'string' ? fm.supersededBy : '';
  return {
    ...state,
    owner: typeof fm.owner === 'string' ? fm.owner : '',
    reviewed,
    supersededBy: by && by.startsWith('/') ? withBase(by) : by,
  };
});
</script>

<template>
  <p v-if="meta" class="spec-front-matter">
    <span :class="['VPBadge', meta.type]">{{ meta.label }}</span>
    <span v-if="meta.owner"
      >Owner <code>{{ meta.owner }}</code></span
    >
    <span v-if="meta.reviewed">Reviewed {{ meta.reviewed }}</span>
    <span v-if="meta.supersededBy">
      Superseded by <a :href="meta.supersededBy">{{ meta.supersededBy }}</a>
    </span>
  </p>
</template>

<style scoped>
.spec-front-matter {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 16px;
  margin: 0 0 16px;
  font-size: 14px;
  color: var(--vp-c-text-2);
}
.spec-front-matter .VPBadge {
  margin-left: 0;
  transform: none;
}
</style>
