<script setup lang="ts">
// Renders glossary entries from glossary.json (via glossary.data.mts).
//
// Without `owner` it renders every entry, grouped by owner with shared terms
// first — the /glossary page. With `owner` it renders only that package's
// entries, for a specification's Terminology section. Every term's anchor is
// its stable id, so `/glossary#<id>` links resolve on the glossary page.
import { computed } from 'vue';
import { withBase } from 'vitepress';
import {
  data as entries,
  type RenderedGlossaryEntry,
} from '../glossary.data.mts';

const props = defineProps<{ owner?: string }>();

const byId = new Map(entries.map(e => [e.id, e]));

const byTerm = (a: RenderedGlossaryEntry, b: RenderedGlossaryEntry) =>
  a.term.localeCompare(b.term, 'en', { sensitivity: 'base' });

const groups = computed(() => {
  const owners = props.owner
    ? [props.owner]
    : [...new Set(entries.map(e => e.owner))].sort((a, b) =>
        a === 'global' ? -1 : b === 'global' ? 1 : a.localeCompare(b),
      );
  return owners.map(owner => ({
    owner,
    title: owner === 'global' ? 'Shared terms' : owner,
    entries: entries.filter(e => e.owner === owner).sort(byTerm),
  }));
});

const href = (link: string) => (link.startsWith('/') ? withBase(link) : link);
const termHref = (id: string) => withBase(`/glossary#${id}`);
</script>

<template>
  <div class="glossary">
    <section v-for="g in groups" :key="g.owner" class="glossary-group">
      <h2
        v-if="!props.owner"
        :id="`terms-${g.owner.replace(/[^a-z0-9]+/g, '-')}`"
      >
        <code v-if="g.owner !== 'global'">{{ g.title }}</code>
        <template v-else>{{ g.title }}</template>
      </h2>
      <div v-for="e in g.entries" :key="e.id" class="glossary-entry">
        <h3 :id="e.id" tabindex="-1">
          {{ e.term }}
          <a
            class="header-anchor"
            :href="`#${e.id}`"
            :aria-label="`Permalink to ${e.term}`"
            >&#8203;</a
          >
        </h3>
        <p v-if="e.aliases?.length" class="glossary-aliases">
          Also:
          <span v-for="(a, i) in e.aliases" :key="a"
            ><em>{{ a }}</em
            ><template v-if="i < e.aliases.length - 1">, </template></span
          >
        </p>
        <p class="glossary-definition" v-html="e.definitionHtml" />
        <p v-if="e.authority?.length" class="glossary-meta">
          Source:
          <span v-for="(a, i) in e.authority" :key="a.link">
            <a :href="href(a.link)">{{ a.text }}</a
            ><template v-if="i < e.authority.length - 1"> · </template>
          </span>
        </p>
        <p v-if="e.seeAlso?.length" class="glossary-meta">
          See also:
          <span v-for="(s, i) in e.seeAlso" :key="s">
            <a :href="termHref(s)">{{ byId.get(s)?.term ?? s }}</a
            ><template v-if="i < e.seeAlso.length - 1">, </template>
          </span>
        </p>
      </div>
    </section>
  </div>
</template>

<style scoped>
.glossary-entry h3 {
  margin-top: 28px;
}
.glossary-aliases,
.glossary-meta {
  margin: 4px 0;
  font-size: 0.9em;
  color: var(--vp-c-text-2);
}
</style>
