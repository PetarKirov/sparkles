<script setup lang="ts">
// Terminal-grid presentation for the cell explorer. Given the flat list of
// grapheme-cluster cells produced by TextCellViz (via spk_segment), lay them out
// on a real monospace terminal grid: each cluster occupies one cell whose width
// (1 or 2 columns) comes from its leading scalar, zero-width clusters fold into
// the preceding cell (kitty's "add the code point to the previous cell"), a line
// break (LF/CR/CRLF/LS/PS) starts a new row, and the line wraps to a new row once
// a cluster no longer fits in `cols` columns.
//
// Per-cell details (glyph, code points, width, row, col) surface through a
// GUI-inspector tooltip that follows the cursor on hover and pins on click.
import { computed, ref, onMounted, onUnmounted } from 'vue';

type Cell = { glyph: string; width: number; cps: string[] };
type PlacedCell = {
  glyph: string;
  width: number;
  cps: string[];
  row: number;
  col: number;
  zero: boolean;
  key: number;
};

const props = defineProps<{ cells: Cell[]; cols: number }>();

// Walk the clusters like a terminal cursor: advance by each cluster's width,
// wrap at `cols`, and absorb zero-width clusters into the previous cell.
const placed = computed<PlacedCell[]>(() => {
  const cols = Math.max(1, props.cols);
  const out: PlacedCell[] = [];
  let row = 0;
  let col = 0;
  let key = 0;
  for (const c of props.cells) {
    // A line break (LF/CR/CRLF/LS/PS) ends the current row like a terminal cursor.
    if (/[\n\r\u2028\u2029]/.test(c.glyph)) {
      row++;
      col = 0;
      continue;
    }
    if (c.width === 0) {
      const prev = out[out.length - 1];
      if (prev && !prev.zero) {
        prev.cps = prev.cps.concat(c.cps);
        continue;
      }
      // A leading zero-width cluster with nothing to attach to gets its own
      // marker slot (rendered narrow, never advances past one column).
      out.push({ ...c, cps: [...c.cps], row, col, zero: true, key: key++ });
      continue;
    }
    if (col + c.width > cols) {
      row++;
      col = 0;
    }
    out.push({ ...c, cps: [...c.cps], row, col, zero: false, key: key++ });
    col += c.width;
  }
  return out;
});

const rows = computed(() =>
  placed.value.reduce((m, c) => Math.max(m, c.row + 1), 0),
);

const hovered = ref<PlacedCell | null>(null);
const pinned = ref<PlacedCell | null>(null);
const pointer = ref({ x: 0, y: 0 });

const active = computed(() => pinned.value ?? hovered.value);

function onCellEnter(cell: PlacedCell, e: MouseEvent) {
  hovered.value = cell;
  pointer.value = { x: e.clientX, y: e.clientY };
}
function onCellMove(e: MouseEvent) {
  pointer.value = { x: e.clientX, y: e.clientY };
}
function onCellLeave() {
  hovered.value = null;
}
function onCellClick(cell: PlacedCell, e: MouseEvent) {
  e.stopPropagation();
  pinned.value = pinned.value?.key === cell.key ? null : cell;
}
function onDocClick() {
  pinned.value = null;
}

onMounted(() => document.addEventListener('click', onDocClick));
onUnmounted(() => document.removeEventListener('click', onDocClick));
</script>

<template>
  <div class="tcv-term-wrap">
    <div
      class="tcv-term"
      :style="{
        '--cols': props.cols,
        '--rows': rows,
        gridTemplateColumns: `repeat(${props.cols}, var(--cell-w))`,
      }"
    >
      <div
        v-for="c in placed"
        :key="c.key"
        class="tcv-tcell"
        :class="{
          wide: c.width === 2,
          zero: c.zero,
          pinned: pinned?.key === c.key,
        }"
        :style="{
          gridColumn: `${c.col + 1} / span ${Math.max(c.width, 1)}`,
          gridRow: c.row + 1,
        }"
        @mouseenter="onCellEnter(c, $event)"
        @mousemove="onCellMove"
        @mouseleave="onCellLeave"
        @click="onCellClick(c, $event)"
      >
        <span class="tcv-tglyph">{{ c.glyph }}</span>
      </div>
    </div>

    <div
      v-if="active"
      class="tcv-inspector"
      :style="{ left: pointer.x + 14 + 'px', top: pointer.y + 14 + 'px' }"
    >
      <div class="tcv-insp-head">
        <span class="tcv-insp-glyph">{{ active.glyph }}</span>
        <span v-if="pinned" class="tcv-insp-pin">📌 pinned</span>
      </div>
      <dl class="tcv-insp-rows">
        <div>
          <dt>width</dt>
          <dd>{{ active.width }}</dd>
        </div>
        <div>
          <dt>row</dt>
          <dd>{{ active.row }}</dd>
        </div>
        <div>
          <dt>col</dt>
          <dd>{{ active.col }}</dd>
        </div>
        <div>
          <dt>cp</dt>
          <dd class="tcv-insp-cps">
            <span v-for="cp in active.cps" :key="cp" class="tcv-insp-cp">{{
              cp
            }}</span>
          </dd>
        </div>
      </dl>
    </div>
  </div>
</template>

<style scoped>
.tcv-term-wrap {
  margin-top: 1rem;
}
.tcv-term {
  /* Size each cell to the monospace character box so box-drawing glyphs span the
    whole cell and connect across borders: --cell-w is the column advance
    (≈ 0.6em for a monospace font) and --cell-h is the matching 1em line box.
    Keep --cell-w in sync with CELL_REM in TextCellViz.vue (the column-fit cap). */
  --cell-w: 0.8rem;
  --cell-h: calc(var(--cell-w) / 0.6);
  position: relative;
  display: grid;
  grid-auto-rows: var(--cell-h);
  width: calc(var(--cols) * var(--cell-w) + 1px);
  border: 1px solid var(--vp-c-divider);
  /* The glyph fills the cell (font-size = line box, line-height 1), so adjacent
    box-drawing strokes meet with no padding between them. */
  font-family: var(--vp-font-family-mono);
  font-size: var(--cell-h);
  line-height: 1;
  /* Draw the full terminal grid (including empty cells) as a background so the
    horizontal/vertical lines show through transparent cells. */
  background-image:
    linear-gradient(var(--vp-c-divider) 1px, transparent 1px),
    linear-gradient(90deg, var(--vp-c-divider) 1px, transparent 1px);
  background-size: var(--cell-w) var(--cell-h);
  background-position: -1px -1px;
}
.tcv-tcell {
  display: flex;
  align-items: center;
  justify-content: center;
  height: var(--cell-h);
  cursor: pointer;
  background: transparent;
}
.tcv-tcell:hover {
  outline: 2px solid var(--vp-c-brand-1);
  outline-offset: -2px;
  z-index: 1;
}
.tcv-tcell.pinned {
  outline: 2px solid var(--vp-c-brand-1);
  outline-offset: -2px;
  background: var(--vp-c-brand-soft);
  z-index: 1;
}
.tcv-tcell.wide {
  background: var(--vp-c-brand-soft);
}
.tcv-tcell.zero {
  opacity: 0.6;
  background: var(--vp-c-bg-mute);
}
.tcv-tglyph {
  font: inherit;
  line-height: 1;
  /* A cluster can render as several glyphs (e.g. a base + an inapplicable
    modifier); keep them on one line instead of wrapping/stacking in the cell. */
  white-space: nowrap;
}

.tcv-inspector {
  position: fixed;
  z-index: 9999;
  min-width: 9rem;
  padding: 0.5rem 0.6rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background-color: var(--vp-c-bg-elv);
  box-shadow: var(--vp-shadow-3);
  pointer-events: none;
}
.tcv-insp-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  margin-bottom: 0.4rem;
}
.tcv-insp-glyph {
  font-family: var(--vp-font-family-mono);
  font-size: 1.6rem;
  line-height: 1;
}
.tcv-insp-pin {
  font-size: 0.65rem;
  color: var(--vp-c-text-2);
}
.tcv-insp-rows {
  margin: 0;
  display: grid;
  gap: 0.15rem 0;
  font-size: 0.78rem;
}
.tcv-insp-rows > div {
  display: flex;
  gap: 0.5rem;
}
.tcv-insp-rows dt {
  width: 3rem;
  color: var(--vp-c-text-3);
}
.tcv-insp-rows dd {
  margin: 0;
  font-family: var(--vp-font-family-mono);
  color: var(--vp-c-text-1);
}
.tcv-insp-cps {
  display: flex;
  flex-wrap: wrap;
  gap: 0.15rem 0.35rem;
}
.tcv-insp-cp {
  white-space: nowrap;
}
</style>
