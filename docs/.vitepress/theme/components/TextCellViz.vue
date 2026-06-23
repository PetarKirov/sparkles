<script setup lang="ts">
// Interactive cell-explorer for the sparkles.base.text spec. Loads spk-text.wasm
// (the real sparkles.base.text compiled to wasm by `nix build .#text-wasm`) and,
// as you type, calls its `spk_segment` export to split the string into grapheme
// clusters and show each one over the terminal cells it occupies.
//
// SSR-safe: all WebAssembly/DOM work happens in onMounted (client only).
import { ref, computed, watch, onMounted, onUnmounted } from 'vue';
import TerminalCellGrid from './TerminalCellGrid.vue';

// Column width in rem; keep in sync with `--cell-w` in TerminalCellGrid.vue.
// Small enough that ~45+ columns fit the component width without overflowing.
const CELL_REM = 0.8;

type Cell = { glyph: string; width: number; cps: string[] };

const presets: { label: string; value: string }[] = [
  { label: 'mixed', value: 'aÁ世\u{1F1FA}\u{1F1F8}कि❤️' },
  {
    label: 'flags',
    value: '\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}\u{1F1EB}\u{1F1F7}',
  },
  { label: 'ZWJ family', value: '\u{1F469}‍\u{1F467}' },
  { label: 'Devanagari', value: 'नमस्ते' },
  { label: 'CJK', value: '世界終わり' },
  { label: 'emoji + VS', value: '❤️\u{1F44D}\u{1F3FD}' },
  { label: 'multiline', value: 'hello\n世界\n❤️ok' },
  {
    // The `drawBox` grand-tour frame from libs/core-cli/examples/unicode-box.d.
    // Joiners / variation selector / rocket are escaped so they're auditable.
    label: 'box drawing',
    value:
      '╭──╼ Grand tour 世界 \u{1F680} ╾───────────────────────╮\n' +
      '│ CJK 世界, emoji \u{1F469}\u200D\u{1F467} \u2764\uFE0F, and a clickable styled │\n' +
      '│ link — all wrapped and streamed together.     │\n' +
      '╰───────────────────────────────────────────────╯',
  },
];

const input = ref(presets[0].value);
const cells = ref<Cell[]>([]);
const total = ref(0);
const status = ref('loading…');
const mode = ref<'cards' | 'grid'>('cards');
const cols = ref(16);
const truncated = ref(false);
let exp: any = null;

// Max grapheme clusters we segment per update. The wasm scratch buffer keeps the
// input in [0, 40000) and the output triples from 40000, leaving room for ~2100
// triples; this cap stays well within that while covering multi-line inputs.
const MAX_CELLS = 512;

// Cap the column count to what fits the component's content width, so a grid row
// never overflows the TextCellViz box. `availPx` tracks the measured content-box
// width (kept current by a ResizeObserver); `maxCols` is the resulting ceiling.
const rootEl = ref<HTMLElement | null>(null);
const availPx = ref(0);
let ro: ResizeObserver | null = null;

function rootFontPx() {
  if (typeof window === 'undefined') return 16;
  return parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
}

const maxCols = computed(() => {
  const cellPx = CELL_REM * rootFontPx();
  // -1 leaves room for the grid container's 1px border.
  return Math.max(4, Math.floor((availPx.value - 1) / cellPx));
});

// Only ever clamp down: shrinking the viewport pulls the slider in, but widening
// it just raises the ceiling without moving the user's chosen value.
watch(maxCols, m => {
  if (cols.value > m) cols.value = m;
});

onMounted(() => {
  if (!rootEl.value || typeof ResizeObserver === 'undefined') return;
  // Seed synchronously (content width = clientWidth minus the 1rem×2 padding) so
  // maxCols is correct before the first preset click, then keep it live.
  availPx.value = rootEl.value.clientWidth - 2 * rootFontPx();
  ro = new ResizeObserver(entries => {
    availPx.value = entries[0].contentRect.width;
  });
  ro.observe(rootEl.value);
});

onUnmounted(() => ro?.disconnect());

function withBase(p: string) {
  const base = (import.meta as any).env?.BASE_URL ?? '/';
  return base.replace(/\/$/, '') + '/' + p;
}

function update() {
  if (!exp) return;
  const bytes = new TextEncoder().encode(input.value);
  const p = exp.spk_buf_ptr();
  if (bytes.length > exp.spk_buf_cap()) {
    status.value = 'input too long';
    return;
  }
  new Uint8Array(exp.memory.buffer).set(bytes, p);
  const outP = (p + 40000) & ~3;
  const n = exp.spk_segment(p, bytes.length, outP, MAX_CELLS);
  truncated.value = n >= MAX_CELLS;
  const o = new Uint32Array(exp.memory.buffer, outP, n * 3);
  const dec = new TextDecoder();
  const out: Cell[] = [];
  let sum = 0;
  for (let i = 0; i < n; i++) {
    const off = o[i * 3],
      len = o[i * 3 + 1],
      width = o[i * 3 + 2];
    const glyph = dec.decode(bytes.slice(off, off + len));
    const cps = Array.from(glyph).map(
      c => 'U+' + c.codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0'),
    );
    out.push({ glyph, width, cps });
    sum += width;
  }
  cells.value = out;
  total.value = sum;
  status.value = '';
}

// Visible width (in cells) of the widest line — the sum of cluster widths per
// line, line breaks resetting the run. Used to fit the grid to a preset.
function widestLineWidth(list: Cell[]): number {
  const lineBreak = /[\n\r\u2028\u2029]/;
  let max = 0;
  let cur = 0;
  for (const c of list) {
    if (lineBreak.test(c.glyph)) {
      if (cur > max) max = cur;
      cur = 0;
    } else {
      cur += c.width;
    }
  }
  return cur > max ? cur : max;
}

// Choosing a preset sizes the grid to its widest line, so it shows on one row
// (clamped to what fits the component — see maxCols).
function applyPreset(value: string) {
  input.value = value;
  update();
  cols.value = Math.min(
    maxCols.value,
    Math.max(4, widestLineWidth(cells.value)),
  );
}

onMounted(async () => {
  try {
    const mod = await WebAssembly.compileStreaming(
      fetch(withBase('spk-text.wasm')),
    );
    // The compute exports never call WASI at runtime, so stub every import.
    const imports: Record<string, Record<string, () => number>> = {};
    for (const imp of WebAssembly.Module.imports(mod)) {
      (imports[imp.module] ||= {})[imp.name] = () => 0;
    }
    const { exports } = await WebAssembly.instantiate(mod, imports as any);
    if ((exports as any).__wasm_call_ctors)
      (exports as any).__wasm_call_ctors();
    exp = exports;
    update();
  } catch (e: any) {
    status.value = 'failed to load wasm: ' + (e?.message ?? e);
  }
});
</script>

<template>
  <div ref="rootEl" class="tcv">
    <div class="tcv-controls">
      <div class="tcv-presets">
        Examples:
        <button
          v-for="p in presets"
          :key="p.label"
          class="tcv-preset"
          @click="applyPreset(p.value)"
        >
          {{ p.label }}
        </button>
      </div>
      <textarea
        v-model="input"
        class="tcv-input"
        rows="2"
        spellcheck="false"
        @input="update"
        aria-label="text to measure"
      ></textarea>
    </div>

    <div class="tcv-view-controls">
      <div class="tcv-modes" role="group" aria-label="presentation mode">
        <button
          class="tcv-mode"
          :class="{ active: mode === 'cards' }"
          @click="mode = 'cards'"
        >
          Cards
        </button>
        <button
          class="tcv-mode"
          :class="{ active: mode === 'grid' }"
          @click="mode = 'grid'"
        >
          Terminal grid
        </button>
      </div>
      <label v-if="mode === 'grid'" class="tcv-cols">
        columns
        <input
          v-model.number="cols"
          type="range"
          min="4"
          :max="maxCols"
          aria-label="terminal columns"
        />
        <span class="tcv-cols-val">{{ cols }}</span>
      </label>
    </div>

    <p v-if="status" class="tcv-status">{{ status }}</p>

    <TerminalCellGrid v-else-if="mode === 'grid'" :cells="cells" :cols="cols" />

    <div v-else class="tcv-grid">
      <div
        v-for="(c, i) in cells"
        :key="i"
        class="tcv-cell"
        :class="{ wide: c.width === 2, zero: c.width === 0 }"
        :style="{ '--cells': Math.max(c.width, 1) }"
      >
        <div class="tcv-glyph">{{ c.glyph }}</div>
        <div class="tcv-w">w={{ c.width }}</div>
        <div class="tcv-cp">
          <span v-for="cp in c.cps" :key="cp" class="tcv-cp-tok">{{ cp }}</span>
        </div>
      </div>
    </div>

    <p v-if="!status" class="tcv-total">
      <code>visibleWidth</code> = {{ total }} cell{{ total === 1 ? '' : 's' }} ·
      {{ cells.length }} cluster{{ cells.length === 1 ? '' : 's' }}
      <span v-if="truncated" class="tcv-trunc"
        >· showing first {{ MAX_CELLS }} clusters</span
      >
    </p>
  </div>
</template>

<style scoped>
.tcv {
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
.tcv-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.tcv-input {
  flex: 1 1 16rem;
  font-family: var(--vp-font-family-mono);
  font-size: 1.1rem;
  padding: 0.4rem 0.6rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  resize: vertical;
  line-height: 1.4;
}
.tcv-presets {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  align-items: center;
}
.tcv-preset {
  font-size: 0.8rem;
  padding: 0.25rem 0.5rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg-soft);
  cursor: pointer;
}
.tcv-preset:hover {
  border-color: var(--vp-c-brand-1);
}
.tcv-view-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: center;
  margin-top: 0.75rem;
}
.tcv-modes {
  display: inline-flex;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  overflow: hidden;
}
.tcv-mode {
  font-size: 0.8rem;
  padding: 0.25rem 0.6rem;
  border: none;
  background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-2);
  cursor: pointer;
}
.tcv-mode + .tcv-mode {
  border-left: 1px solid var(--vp-c-divider);
}
.tcv-mode:hover {
  color: var(--vp-c-brand-1);
}
.tcv-mode.active {
  background: var(--vp-c-brand-soft);
  color: var(--vp-c-brand-1);
}
.tcv-cols {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.8rem;
  color: var(--vp-c-text-2);
}
.tcv-cols-val {
  font-family: var(--vp-font-family-mono);
  min-width: 1.5rem;
  color: var(--vp-c-text-1);
}
.tcv-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 1rem;
}
.tcv-cell {
  --col: 2.5rem;
  width: calc(var(--cells) * var(--col));
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  padding: 0.4rem 0.2rem;
  text-align: center;
  background: var(--vp-c-bg-soft);
}
.tcv-cell.wide {
  background: var(--vp-c-brand-soft);
}
.tcv-cell.zero {
  width: 0.6rem;
  opacity: 0.6;
  background: var(--vp-c-bg-mute);
}
.tcv-glyph {
  font-family: var(--vp-font-family-mono);
  font-size: 1.5rem;
  line-height: 1.2;
}
.tcv-w {
  font-size: 0.7rem;
  color: var(--vp-c-text-2);
}
.tcv-cp {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 0 0.35rem;
  font-size: 0.58rem;
  line-height: 0.75rem;
  color: var(--vp-c-text-3);
}
.tcv-cp-tok {
  white-space: nowrap;
}
.tcv-status {
  color: var(--vp-c-text-2);
  font-style: italic;
  margin-top: 0.75rem;
}
.tcv-total {
  margin-top: 0.75rem;
  color: var(--vp-c-text-2);
  font-size: 0.9rem;
}
.tcv-trunc {
  color: var(--vp-c-warning-1, var(--vp-c-text-3));
}
</style>
