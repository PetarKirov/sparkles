<script setup lang="ts">
// One Dockview panel body for the drawTable playground. Which section it renders is
// chosen by `params.section`, set when the panel is added in TablePlayground. All
// reactive state comes from the injected store (see tpg-store.ts) so every panel
// drives the same render pipeline.
import { inject, computed, ref, watch, nextTick, onMounted } from 'vue';
import { tpgKey } from './tpg-store';
import TpgNumber from './TpgNumber.vue';

type Section =
  | 'separators'
  | 'style'
  | 'percol'
  | 'data'
  | 'rawspec'
  | 'output'
  | 'dcode';

// dockview-vue wraps a panel's own params one level deep: the `params` prop it
// passes is `{ params: <what we set in addPanel>, api, containerApi, tabLocation }`.
// So the section we chose lives at `params.params.section`.
const panelProps = defineProps<{
  params: { params: { section: Section } };
}>();
const section = computed(() => panelProps.params?.params?.section);

const store = inject(tpgKey)!;
const {
  props,
  presetNames,
  colCount,
  colAligns,
  colVAligns,
  colMaxW,
  dataMode,
  rawMode,
  gridText,
  rawData,
  currentSpec,
  insertTab,
  output,
  errored,
  gridOut,
  dcode,
  rawSpecHtml,
  dcodeHtml,
} = store;

// Grow the data textarea to fit its content so samples (which load anywhere from a
// few lines to a large JSON spec) are shown without an internal textarea scrollbar.
// A CSS max-height caps it; past that it scrolls. Only the Input panel renders a
// textarea, so this is a no-op elsewhere.
const taEl = ref<HTMLTextAreaElement | null>(null);
function fitTextarea() {
  const el = taEl.value;
  if (!el) return;
  el.style.height = 'auto';
  // Add the border (offsetHeight − clientHeight) since the box is border-box, else
  // the content is short by the border width and the textarea scrolls by a pixel.
  const chrome = el.offsetHeight - el.clientHeight;
  el.style.height = `${el.scrollHeight + chrome}px`;
}
watch([gridText, rawData, dataMode], () => nextTick(fitTextarea));
onMounted(() => nextTick(fitTextarea));
</script>

<template>
  <div class="tpg-panel" :class="{ 'tpg-outsec': section === 'output' }">
    <!-- Separators & frame -->
    <template v-if="section === 'separators'">
      <label class="tpg-check"
        ><input type="checkbox" v-model="props.border" /> border</label
      >
      <label class="tpg-check"
        ><input type="checkbox" v-model="props.columnSeparators" />
        columnSeparators</label
      >
      <label class="tpg-check"
        ><input type="checkbox" v-model="props.rowSeparators" />
        rowSeparators</label
      >
      <div class="tpg-row">
        <label
          >headerRows
          <TpgNumber
            v-model="props.headerRows"
            :min="0"
            :max="8"
            aria-label="headerRows"
        /></label>
        <label
          >headerCols
          <TpgNumber
            v-model="props.headerCols"
            :min="0"
            :max="8"
            aria-label="headerCols"
        /></label>
      </div>
    </template>

    <!-- Style & width -->
    <template v-else-if="section === 'style'">
      <div class="tpg-row">
        <label
          >preset
          <select v-model="props.preset">
            <option v-for="p in presetNames" :key="p" :value="p">
              {{ p }}
            </option>
          </select>
        </label>
        <label
          >maxWidth
          <TpgNumber
            v-model="props.maxWidth"
            :min="0"
            :max="120"
            aria-label="maxWidth"
        /></label>
      </div>
      <div class="tpg-row">
        <label
          >defaultAlign
          <select v-model="props.defaultAlign">
            <option
              v-for="a in ['left', 'center', 'right']"
              :key="a"
              :value="a"
            >
              {{ a }}
            </option>
          </select>
        </label>
        <label
          >defaultVAlign
          <select v-model="props.defaultVAlign">
            <option
              v-for="a in ['top', 'middle', 'bottom']"
              :key="a"
              :value="a"
            >
              {{ a }}
            </option>
          </select>
        </label>
      </div>
    </template>

    <!-- Per-column overrides -->
    <template v-else-if="section === 'percol'">
      <p class="tpg-hint" v-if="colCount === 0">No columns yet.</p>
      <div class="tpg-percol">
        <div v-for="c in colCount" :key="c" class="tpg-colcard">
          <div class="tpg-colhead">col {{ c - 1 }}</div>
          <select v-model="colAligns[c - 1]" aria-label="align">
            <option
              v-for="a in ['inherit', 'left', 'center', 'right']"
              :key="a"
              :value="a"
            >
              {{ a }}
            </option>
          </select>
          <select v-model="colVAligns[c - 1]" aria-label="valign">
            <option
              v-for="a in ['inherit', 'top', 'middle', 'bottom']"
              :key="a"
              :value="a"
            >
              {{ a }}
            </option>
          </select>
          <TpgNumber
            v-model="colMaxW[c - 1]"
            :min="0"
            :max="60"
            :aria-label="`col ${c - 1} max width`"
          />
        </div>
      </div>
    </template>

    <!-- Data -->
    <template v-else-if="section === 'data'">
      <div class="tpg-seg" role="group">
        <button
          class="tpg-segbtn"
          :class="{ active: dataMode === 'grid' }"
          @click="dataMode = 'grid'"
        >
          Grid
        </button>
        <button
          class="tpg-segbtn"
          :class="{ active: dataMode === 'raw' }"
          @click="dataMode = 'raw'"
        >
          Raw cells
        </button>
        <template v-if="dataMode === 'raw'">
          <button
            class="tpg-segbtn tpg-segbtn--gap"
            :class="{ active: rawMode === 'dense' }"
            @click="rawMode = 'dense'"
          >
            Cell[][]
          </button>
          <button
            class="tpg-segbtn"
            :class="{ active: rawMode === 'sparse' }"
            @click="rawMode = 'sparse'"
          >
            Placement[]
          </button>
        </template>
      </div>
      <textarea
        v-if="dataMode === 'grid'"
        ref="taEl"
        v-model="gridText"
        class="tpg-ta"
        rows="4"
        spellcheck="false"
        aria-label="grid data (tab = column, newline = row)"
        @input="fitTextarea"
        @keydown.tab.exact.prevent="insertTab"
      ></textarea>
      <textarea
        v-else
        ref="taEl"
        v-model="rawData"
        class="tpg-ta tpg-mono"
        rows="7"
        spellcheck="false"
        aria-label="raw cell JSON"
        @input="fitTextarea"
      ></textarea>
      <p class="tpg-hint" v-if="dataMode === 'grid'">
        Tab separates columns; newline separates rows. Paste ANSI/emoji freely.
      </p>
    </template>

    <!-- Raw spec (JSON): the exact request sent to spk_table_render -->
    <template v-else-if="section === 'rawspec'">
      <p class="tpg-hint">
        The exact request sent to <code>spk_table_render</code>. Read-only
        preview of the current controls.
      </p>
      <div v-if="rawSpecHtml" class="tpg-code" v-html="rawSpecHtml"></div>
      <pre v-else class="tpg-json">{{
        JSON.stringify(currentSpec(), null, 2)
      }}</pre>
    </template>

    <!-- Output: a fixed-cell terminal grid -->
    <template v-else-if="section === 'output'">
      <pre v-if="errored" class="tpg-render tpg-err">{{ output }}</pre>
      <div v-else class="tpg-render">
        <div
          class="tpg-grid"
          :style="{
            gridTemplateColumns: `repeat(${gridOut.cols}, var(--cell-w))`,
          }"
          v-html="gridOut.html"
        ></div>
      </div>
    </template>

    <!-- D code: the drawTable(...) call for the current controls/data -->
    <template v-else>
      <div v-if="dcodeHtml" class="tpg-code" v-html="dcodeHtml"></div>
      <pre v-else class="tpg-json">{{ dcode }}</pre>
    </template>
  </div>
</template>

<style scoped>
/* Each panel body fills its Dockview panel and scrolls independently. The monospace
  font var (--tpg-mono) and the woff2 @font-face are defined on the ancestor .tpg in
  TablePlayground.vue and inherit down into this dockview-mounted subtree. */
.tpg-panel {
  height: 100%;
  overflow: auto;
  padding: 0.85rem;
  box-sizing: border-box;
}

.tpg-ta {
  width: 100%;
  font-family: var(--tpg-mono);
  font-size: 0.9rem;
  padding: 0.4rem 0.6rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  resize: vertical;
  /* Auto-grown to content by fitTextarea(); this caps very large samples (past the
    cap the textarea scrolls). box-sizing so the JS height math includes padding. */
  box-sizing: border-box;
  min-height: 5.5rem;
  max-height: 60vh;
  overflow-y: auto;
}
.tpg-mono {
  font-size: 0.8rem;
}
.tpg-hint {
  font-size: 0.72rem;
  color: var(--vp-c-text-3);
  margin: 0.35rem 0 0;
}
.tpg-seg {
  display: inline-flex;
  flex-wrap: wrap;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  overflow: hidden;
  margin-bottom: 0.4rem;
}
.tpg-segbtn {
  font-size: 0.8rem;
  padding: 0.2rem 0.6rem;
  border: none;
  border-left: 1px solid var(--vp-c-divider);
  background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-2);
  cursor: pointer;
}
.tpg-segbtn:first-child {
  border-left: none;
}
/* A visual gap between the data-mode and raw-mode toggle groups. */
.tpg-segbtn--gap {
  margin-left: 0.4rem;
  border-left: 1px solid var(--vp-c-divider);
}
.tpg-segbtn.active {
  background: var(--vp-c-brand-soft);
  color: var(--vp-c-brand-1);
}
.tpg-check {
  display: block;
  font-size: 0.85rem;
  margin: 0.15rem 0;
  cursor: pointer;
}
.tpg-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.6rem;
  margin: 0.35rem 0;
}
.tpg-row label,
.tpg-colcard select,
.tpg-colcard input {
  font-size: 0.82rem;
  color: var(--vp-c-text-2);
}
.tpg-row select,
.tpg-row .tpg-num {
  margin-left: 0.3rem;
}
select {
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  border: 1px solid var(--vp-c-divider);
  border-radius: 5px;
  padding: 0.12rem 0.3rem;
}
.tpg-percol {
  display: flex;
  gap: 0.4rem;
  overflow-x: auto;
  padding-bottom: 0.2rem;
}
.tpg-colcard {
  flex: none;
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  padding: 0.35rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg);
}
.tpg-colcard .tpg-num {
  align-self: center;
}
.tpg-colhead {
  font-size: 0.7rem;
  color: var(--vp-c-text-3);
  text-align: center;
}

/* Output — the Dockview panel supplies the height; the render box just scrolls. */
.tpg-outsec {
  min-width: 0;
}
.tpg-render {
  padding: 0.75rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg-alt);
  color: var(--vp-c-text-1);
  overflow: auto;
}
.tpg-err {
  font-family: var(--tpg-mono);
  white-space: pre-wrap;
  color: var(--vp-c-danger-1, var(--vp-c-text-2));
  margin: 0;
}
/* Terminal grid: every glyph is one fixed cell. `--cell-w` is the monospace column
  advance and `--cell-h = --cell-w / 0.6` its matching line box (FiraCode's advance
  is 0.6em). With `font-size: var(--cell-h)` and `line-height: 1` each box-drawing
  glyph fills its whole cell, so strokes meet across cell borders — the same
  technique as TerminalCellGrid.vue. Wide (CJK/emoji) cells span 2 columns. */
.tpg-grid {
  --cell-w: 0.58rem;
  --cell-h: calc(var(--cell-w) / 0.6);
  display: grid;
  grid-auto-rows: var(--cell-h);
  width: max-content;
  font-family: var(--tpg-mono);
  font-size: var(--cell-h);
  line-height: 1;
}
.tpg-gc {
  display: flex;
  align-items: center;
  justify-content: center;
  height: var(--cell-h);
  overflow: hidden;
  white-space: nowrap;
}
.tpg-json {
  font-family: var(--tpg-mono);
  font-size: 0.75rem;
  padding: 0.6rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg-soft);
  overflow-x: auto;
  margin-top: 0.4rem;
}
/* Shiki-highlighted Raw spec / D code. The `.shiki <pre>` comes from v-html, so it
  carries no scope attribute — reach it with :deep. Keep the site's code-block
  chrome (VitePress bg + our mono font) and let Shiki's token colors show through. */
.tpg-code {
  margin-top: 0.4rem;
}
.tpg-code :deep(.shiki) {
  font-family: var(--tpg-mono);
  font-size: 0.75rem;
  padding: 0.6rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-code-block-bg, var(--vp-c-bg-alt)) !important;
  overflow-x: auto;
  margin: 0;
}
.tpg-code :deep(.shiki code) {
  display: block;
  white-space: pre;
}
</style>
