<script setup lang="ts">
// Hover cards for glossary links.
//
// A page links a term with an ordinary Markdown link to its glossary entry
// (`../glossary.md#canonical-witness`), so the link works on GitHub, in an
// editor, and in a plain-text read. On the site, hovering or focusing such a
// link shows the entry's term and one-sentence summary, read from the same
// glossary.json the glossary page renders. Nothing in the page is rewritten:
// one delegated listener recognizes the links, so new pages need no markup.
import { onMounted, onUnmounted, ref, watch } from 'vue';
import { useData, useRoute } from 'vitepress';
import {
  data as entries,
  type RenderedGlossaryEntry,
} from '../glossary.data.mts';

const byId = new Map(entries.map(e => [e.id, e]));
const { site } = useData();
const route = useRoute();

const entry = ref<RenderedGlossaryEntry | null>(null);
const style = ref<Record<string, string>>({});
const cardId = 'glossary-hover-card';

let anchor: HTMLAnchorElement | null = null;
let showTimer: ReturnType<typeof setTimeout> | undefined;
let hideTimer: ReturnType<typeof setTimeout> | undefined;
let pending: HTMLAnchorElement | null = null;

/** The glossary entry an anchor links to, if it is a glossary link. */
function entryFor(a: HTMLAnchorElement): RenderedGlossaryEntry | undefined {
  if (!a.hash) return undefined;
  const url = new URL(a.href, location.href);
  if (url.origin !== location.origin) return undefined;
  const base = site.value.base.replace(/\/$/, '');
  const path = url.pathname.slice(base.length);
  if (!/^\/glossary(\.html)?$/.test(path)) return undefined;
  return byId.get(decodeURIComponent(url.hash.slice(1)));
}

function place(a: HTMLAnchorElement) {
  const r = a.getBoundingClientRect();
  const width = Math.min(360, window.innerWidth - 32);
  const left = Math.max(16, Math.min(r.left, window.innerWidth - width - 16));
  const below = window.innerHeight - r.bottom > 160 || r.top < 160;
  style.value = {
    left: `${left}px`,
    width: `${width}px`,
    ...(below
      ? { top: `${r.bottom + 6}px` }
      : { bottom: `${window.innerHeight - r.top + 6}px` }),
  };
}

function open(a: HTMLAnchorElement, e: RenderedGlossaryEntry) {
  hide(0);
  anchor = a;
  place(a);
  entry.value = e;
  a.setAttribute('aria-describedby', cardId);
}

/** Opens the card for `a`: at once for focus, after `delay` for a hover. */
function show(a: HTMLAnchorElement, e: RenderedGlossaryEntry, delay: number) {
  clearTimeout(hideTimer);
  clearTimeout(showTimer);
  pending = null;
  if (!delay) return open(a, e);
  pending = a;
  showTimer = setTimeout(() => {
    pending = null;
    open(a, e);
  }, delay);
}

function hide(delay: number) {
  clearTimeout(showTimer);
  clearTimeout(hideTimer);
  pending = null;
  const close = () => {
    anchor?.removeAttribute('aria-describedby');
    anchor = null;
    entry.value = null;
  };
  if (delay) hideTimer = setTimeout(close, delay);
  else close();
}

function linkFrom(target: EventTarget | null): HTMLAnchorElement | null {
  return target instanceof Element ? target.closest('a[href]') : null;
}

function onOver(ev: Event) {
  const a = linkFrom(ev.target);
  const e = a && entryFor(a);
  if (a && e) show(a, e, ev.type === 'focusin' ? 0 : 200);
}

// Leaving a link affects only that link's card or pending hover; a scroll that
// slides another link out from under the pointer must not cancel a focus card.
function onOut(ev: Event) {
  const a = linkFrom(ev.target);
  if (!a) return;
  if (a === anchor) hide(ev.type === 'focusout' ? 0 : 150);
  else if (a === pending) {
    clearTimeout(showTimer);
    pending = null;
  }
}

function onKey(ev: KeyboardEvent) {
  if (ev.key === 'Escape') hide(0);
}

// Follow the link while the page scrolls (focusing an off-screen link scrolls
// it into view, so closing here would hide the card from keyboard users).
const follow = () => anchor && place(anchor);
const keepOpen = () => clearTimeout(hideTimer);

// A client-side navigation removes the link without a mouseout.
watch(
  () => route.path,
  () => hide(0),
);

onMounted(() => {
  document.addEventListener('mouseover', onOver);
  document.addEventListener('mouseout', onOut);
  document.addEventListener('focusin', onOver);
  document.addEventListener('focusout', onOut);
  document.addEventListener('keydown', onKey);
  window.addEventListener('scroll', follow, { passive: true });
});

onUnmounted(() => {
  document.removeEventListener('mouseover', onOver);
  document.removeEventListener('mouseout', onOut);
  document.removeEventListener('focusin', onOver);
  document.removeEventListener('focusout', onOut);
  document.removeEventListener('keydown', onKey);
  window.removeEventListener('scroll', follow);
  hide(0);
});
</script>

<template>
  <Teleport to="body">
    <div
      v-if="entry"
      :id="cardId"
      class="glossary-hover"
      role="tooltip"
      :style="style"
      @mouseenter="keepOpen"
      @mouseleave="hide(150)"
    >
      <div class="glossary-hover-term">{{ entry.term }}</div>
      <div class="glossary-hover-summary">{{ entry.summary }}</div>
    </div>
  </Teleport>
</template>

<style scoped>
.glossary-hover {
  position: fixed;
  z-index: 100;
  padding: 10px 14px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  background: var(--vp-c-bg-elv);
  box-shadow: var(--vp-shadow-3);
  font-size: 14px;
  line-height: 1.5;
  color: var(--vp-c-text-1);
}
.glossary-hover-term {
  font-weight: 600;
  margin-bottom: 2px;
}
.glossary-hover-summary {
  color: var(--vp-c-text-2);
}
</style>
