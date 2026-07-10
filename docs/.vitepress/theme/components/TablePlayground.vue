<script setup lang="ts">
// Interactive playground for sparkles.core_cli.ui.table.drawTable. Loads
// spk-table.wasm (the REAL drawTable compiled to wasm by `nix build .#table-wasm`)
// and re-renders live as you tweak Storybook-style controls. All rendering logic
// lives in D; this component only builds a JSON request, calls `spk_table_render`,
// and colorizes the returned ANSI/box-drawing string.
//
// SSR-safe: all WebAssembly/DOM work happens in onMounted (client only).
import {
  ref,
  reactive,
  computed,
  watch,
  onMounted,
  onUnmounted,
  nextTick,
  shallowRef,
  defineAsyncComponent,
  markRaw,
  provide,
} from 'vue';
import { useData } from 'vitepress';
import TpgPanel from './TpgPanel.vue';
import { tpgKey } from './tpg-store';

// Site light/dark, used to pick the matching Shiki theme for the code panels.
const { isDark } = useData();

// ---- WASM loading -------------------------------------------------------
let exp: any = null;
const status = ref('loading…');
// Input JSON lives at [0, IN_CAP); output string is written from OUT_OFF.
const OUT_OFF = 180000;

function withBase(p: string) {
  const base = (import.meta as any).env?.BASE_URL ?? '/';
  return base.replace(/\/$/, '') + '/' + p;
}

onMounted(async () => {
  try {
    const mod = await WebAssembly.compileStreaming(
      fetch(withBase('spk-table.wasm')),
    );
    // drawTable allocates (GC) and reads the clock at init. Stub every WASI import
    // with a no-op EXCEPT the clock queries, which must return a non-zero value or
    // core.time's ctor divides by zero and traps.
    const imports: Record<string, Record<string, (...a: any[]) => number>> = {};
    for (const imp of WebAssembly.Module.imports(mod)) {
      (imports[imp.module] ||= {})[imp.name] = () => 0;
    }
    const W = imports.wasi_snapshot_preview1;
    if (W) {
      W.clock_res_get = (_id: number, resPtr: number) => {
        new DataView(exp.memory.buffer).setBigUint64(resPtr, 1n, true);
        return 0;
      };
      W.clock_time_get = (_id: number, _p: number, resPtr: number) => {
        new DataView(exp.memory.buffer).setBigUint64(resPtr, 0n, true);
        return 0;
      };
    }
    const { exports } = await WebAssembly.instantiate(mod, imports as any);
    exp = exports;
    // Runs the C-level init_array (sets up the GC). D `static this()` ctors do not
    // run under this druntime, but drawTable needs none (presets are a pure fn).
    (exports as any).__wasm_call_ctors?.();
    status.value = '';
    render();
  } catch (e: any) {
    status.value = 'failed to load wasm: ' + (e?.message ?? e);
  }
});

// ---- Controls -----------------------------------------------------------
type Al = 'inherit' | 'left' | 'center' | 'right' | 'decimal';
type VAl = 'inherit' | 'top' | 'middle' | 'bottom';

const props = reactive({
  border: true,
  columnSeparators: true,
  rowSeparators: false,
  headerRows: 1,
  headerCols: 0,
  maxWidth: 0,
  title: '',
  footer: '',
  preset: 'rounded',
  defaultAlign: 'left' as Al,
  defaultVAlign: 'top' as VAl,
});
const presetNames = ['rounded', 'square', 'ascii', 'double', 'heavy'];

// Data source: a simple grid (tab = column, newline = row) OR a raw cells/placements
// spec (JSON) used by the span/sparse samples and the advanced editor.
const dataMode = ref<'grid' | 'raw'>('grid');
const gridText = ref(
  'Node\t地域\tStatus\napi\t日本 🇯🇵\t✅ up\nweb\teu-west\t⚠ warn',
);
const rawMode = ref<'dense' | 'sparse'>('dense');
const rawData = ref('[]'); // JSON: Cell[][] (dense) or Placement[] (sparse)

// Per-column overrides, grown to the current column count.
const colAligns = ref<Al[]>([]);
const colVAligns = ref<VAl[]>([]);
const colMaxW = ref<number[]>([]);

const gridCells = computed<string[][]>(() =>
  gridText.value.split('\n').map(line => line.split('\t')),
);
const colCount = computed(() => {
  if (dataMode.value === 'grid')
    return gridCells.value.reduce((m, r) => Math.max(m, r.length), 0);
  try {
    const d = JSON.parse(rawData.value);
    if (rawMode.value === 'sparse')
      return d.reduce(
        (m: number, p: any) => Math.max(m, (p.col ?? 0) + (p.colSpan ?? 1)),
        0,
      );
    return d.reduce(
      (m: number, row: any[]) =>
        Math.max(
          m,
          row.reduce((s: number, c: any) => s + (c?.colSpan ?? 1), 0),
        ),
      0,
    );
  } catch {
    return 0;
  }
});

// Keep the per-column arrays sized to colCount without dropping user choices.
watch(
  colCount,
  n => {
    const grow = <T,>(a: T[], fill: T) => {
      while (a.length < n) a.push(fill);
      a.length = n;
    };
    grow(colAligns.value, 'inherit');
    grow(colVAligns.value, 'inherit');
    grow(colMaxW.value, 0);
  },
  { immediate: true },
);

// ---- Samples ------------------------------------------------------------
const samples: { label: string; apply: () => void }[] = [
  {
    label: 'Basic',
    apply: () => {
      dataMode.value = 'grid';
      gridText.value =
        'Service\tRegion\tStatus\napi\tus-east\tup\nweb\teu-west\tup\ndb\tap-south\tdown';
      Object.assign(props, {
        headerRows: 1,
        headerCols: 0,
        rowSeparators: false,
        preset: 'rounded',
      });
    },
  },
  {
    label: 'Styled + CJK/emoji',
    apply: () => {
      dataMode.value = 'grid';
      const g = '\u001b[32m✅ up\u001b[39m';
      const w = '\u001b[33m⚠ warn\u001b[39m';
      const b = (s: string) => `\u001b[1m${s}\u001b[22m`;
      gridText.value = `${b('Node')}\t${b('地域')}\t${b('Status')}\napi 🚀\t日本 🇯🇵\t${g}\nweb\teu-west\t${w}`;
      Object.assign(props, { headerRows: 1, headerCols: 1, preset: 'rounded' });
    },
  },
  {
    label: 'Spans',
    apply: () => {
      dataMode.value = 'raw';
      rawMode.value = 'dense';
      rawData.value = JSON.stringify(
        [
          [{ content: '四半期売上 (Quarterly Sales)', colSpan: 3 }],
          [{ content: 'Region' }, { content: 'Q1' }, { content: 'Q2' }],
          [{ content: 'North 🌎' }, { content: '1200' }, { content: '1350' }],
          [{ content: '日本' }, { content: '980' }, { content: '1100' }],
        ],
        null,
        2,
      );
      Object.assign(props, { headerRows: 2, headerCols: 1, preset: 'rounded' });
      colAligns.value = ['left', 'right', 'right'];
    },
  },
  {
    label: 'Sparse',
    apply: () => {
      dataMode.value = 'raw';
      rawMode.value = 'sparse';
      rawData.value = JSON.stringify(
        [
          { row: 0, col: 0, content: 'diagonal 🚀' },
          { row: 1, col: 1, content: '日本語' },
          { row: 2, col: 2, content: '\u001b[36mcells\u001b[39m' },
        ],
        null,
        2,
      );
      Object.assign(props, { headerRows: 0, headerCols: 0, preset: 'rounded' });
    },
  },
  {
    label: 'Wrapping',
    apply: () => {
      dataMode.value = 'grid';
      gridText.value =
        'id\tdescription\n1\tA fairly long description that will not fit a narrow terminal and must wrap\n2\t日本語のテキストは全角文字で構成されています';
      Object.assign(props, {
        headerRows: 1,
        headerCols: 0,
        maxWidth: 44,
        preset: 'rounded',
      });
    },
  },
  {
    label: 'Decimal + title',
    apply: () => {
      dataMode.value = 'grid';
      gridText.value =
        'Item\tUnit price\tQty\nWidget\t3.5\t120\nGadget\t12.75\t8\nGizmo\t0.99\t1500';
      Object.assign(props, {
        headerRows: 1,
        headerCols: 0,
        preset: 'rounded',
        title: 'Invoice',
        footer: '3 line items',
      });
      // Align.decimal makes the price column line up on its decimal point.
      colAligns.value = ['left', 'decimal', 'right'];
    },
  },
];

// ---- Build spec + render -----------------------------------------------
function currentSpec() {
  const p: any = {
    border: props.border,
    columnSeparators: props.columnSeparators,
    rowSeparators: props.rowSeparators,
    headerRows: props.headerRows,
    headerCols: props.headerCols,
    maxWidth: props.maxWidth,
    preset: props.preset,
    defaultAlign: props.defaultAlign,
    defaultVAlign: props.defaultVAlign,
  };
  const n = colCount.value;
  if (colAligns.value.slice(0, n).some(a => a !== 'inherit'))
    p.columnAligns = colAligns.value.slice(0, n);
  if (colVAligns.value.slice(0, n).some(a => a !== 'inherit'))
    p.columnVAligns = colVAligns.value.slice(0, n);
  if (colMaxW.value.slice(0, n).some(w => w > 0))
    p.columnMaxWidths = colMaxW.value.slice(0, n);
  if (props.title) p.title = props.title;
  if (props.footer) p.footer = props.footer;

  if (dataMode.value === 'grid')
    return { mode: 'dense', cells: gridCells.value, props: p };
  const data = JSON.parse(rawData.value);
  return rawMode.value === 'sparse'
    ? { mode: 'sparse', placements: data, props: p }
    : { mode: 'dense', cells: data, props: p };
}

const output = ref('');
const errored = ref(false);

function render() {
  if (!exp) return;
  let json: string;
  try {
    json = JSON.stringify(currentSpec());
  } catch (e: any) {
    output.value = 'invalid data JSON: ' + (e?.message ?? e);
    errored.value = true;
    return;
  }
  const bytes = new TextEncoder().encode(json);
  const p = exp.spk_buf_ptr();
  const cap = exp.spk_buf_cap();
  if (bytes.length > OUT_OFF) {
    output.value = 'input too large';
    errored.value = true;
    return;
  }
  new Uint8Array(exp.memory.buffer).set(bytes, p);
  const outP = (p + OUT_OFF) & ~3;
  const n = exp.spk_table_render(p, bytes.length, outP, cap - OUT_OFF);
  const bytesOut = new Uint8Array(exp.memory.buffer, outP, Math.abs(n));
  const text = new TextDecoder().decode(bytesOut);
  errored.value = n < 0;
  output.value = n < 0 ? 'render error: ' + text : text;
}

// Re-render on any control change.
watch(
  [props, gridText, rawData, dataMode, rawMode, colAligns, colVAligns, colMaxW],
  render,
  {
    deep: true,
  },
);

function applySample(s: { apply: () => void }) {
  // title/footer are frame decorations only the "Decimal + title" sample sets;
  // clear them first so a set title doesn't bleed onto the samples that omit it.
  props.title = '';
  props.footer = '';
  s.apply();
  render();
}

// In the grid editor a Tab is a column separator, so insert one at the caret instead
// of letting the browser move focus. (Shift+Tab is left alone as a keyboard escape
// hatch out of the textarea.)
function insertTab(e: KeyboardEvent) {
  const ta = e.target as HTMLTextAreaElement;
  const start = ta.selectionStart ?? gridText.value.length;
  const end = ta.selectionEnd ?? start;
  gridText.value =
    gridText.value.slice(0, start) + '\t' + gridText.value.slice(end);
  nextTick(() => {
    ta.selectionStart = ta.selectionEnd = start + 1;
  });
}

// ---- Fullscreen (Teleport the live widget to <body>; Esc to exit) -------
const isFullscreen = ref(false);
function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape' && isFullscreen.value) closeFs();
}
function openFs() {
  isFullscreen.value = true;
  if (typeof document !== 'undefined') {
    document.body.style.overflow = 'hidden';
    window.addEventListener('keydown', onKey);
  }
  nudgeDock();
}
function closeFs() {
  isFullscreen.value = false;
  if (typeof document !== 'undefined') {
    document.body.style.overflow = '';
    window.removeEventListener('keydown', onKey);
  }
  nudgeDock();
}
function toggleFs() {
  isFullscreen.value ? closeFs() : openFs();
}
// ---- Dockable panels (Dockview) ----------------------------------------
// The three content blocks (Controls / Data / Output) are Dockview panels the
// reader can drag, dock, split and resize. Dockview is a DOM library, so it is
// loaded client-only (this whole widget renders under <ClientOnly>); a static
// top-level import would be pulled into the SSR build via the component's global
// registration in theme/index.mts. Panels are declared as named slots
// (#controls / #data / #output), so every reactive ref above stays in this one
// <script setup> scope — no store/provide-inject needed.
import type { DockviewApi, DockviewReadyEvent } from 'dockview-vue';
const DockviewVue = defineAsyncComponent(() =>
  import('dockview-vue').then(m => m.DockviewVue),
);
// dockview-vue resolves a panel's `component` name against this map. All three
// panels use the one TpgPanel, distinguished by `params.section`. markRaw keeps Vue
// from making the component definition reactive.
const dvComponents = { panel: markRaw(TpgPanel) };

// Use dockview's built-in GitHub themes (the same palette Shiki uses for the code
// panels) via the `theme` prop, switched with the site's light/dark. These are the
// plain theme descriptors dockview-vue exports as `themeGithubLight/Dark`; inlining
// them keeps dockview out of the SSR bundle (the component itself is async-loaded).
const DV_THEME_LIGHT = {
  name: 'githubLight',
  className: 'dockview-theme-github-light',
  colorScheme: 'light',
};
const DV_THEME_DARK = {
  name: 'githubDark',
  className: 'dockview-theme-github-dark',
  colorScheme: 'dark',
};
const dvTheme = computed(() => (isDark.value ? DV_THEME_DARK : DV_THEME_LIGHT));

const dvApi = shallowRef<DockviewApi | null>(null);
const dockEl = ref<HTMLElement | null>(null);
let dvDisposable: { dispose(): void } | null = null;
let saveTimer: ReturnType<typeof setTimeout> | null = null;

// Versioned key so a panel-id/schema change self-invalidates stale layouts. (v4:
// renamed Data→Input and added the single-column mobile default.)
const LS_KEY = 'sparkles.tpg.dock.v4';
const canLS = () => typeof window !== 'undefined' && !!window.localStorage;

function saveLayout() {
  if (!dvApi.value || !canLS()) return;
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(dvApi.value.toJSON()));
  } catch {}
}
// onDidLayoutChange fires rapidly mid-drag; coalesce writes.
function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(saveLayout, 300);
}
function dropLayout() {
  if (!canLS()) return;
  try {
    localStorage.removeItem(LS_KEY);
  } catch {}
}
function restoreLayout(): boolean {
  if (!dvApi.value || !canLS()) return false;
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(LS_KEY);
  } catch {
    return false;
  }
  if (!raw) return false;
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch {
    dropLayout();
    return false;
  }
  // Guard before fromJSON: if the saved layout references a component this build no
  // longer knows (e.g. after a schema change), Dockview throws *asynchronously* in a
  // panel mounted hook — past any try/catch here — leaving a half-built dock. So
  // validate up front that every panel uses our sole 'panel' component; otherwise
  // discard and fall back to defaults.
  const panels = parsed?.panels;
  const known =
    panels &&
    typeof panels === 'object' &&
    Object.values(panels).every((p: any) => p?.contentComponent === 'panel');
  if (!known) {
    dropLayout();
    return false;
  }
  try {
    dvApi.value.fromJSON(parsed);
    return true;
  } catch {
    dropLayout();
    return false;
  }
}
// Every panel is a TpgPanel; `section` picks what it renders. `position` with a
// referencePanel and NO direction adds the panel as another tab in that panel's
// group; `direction` splits off a new group. The default: Output (+ D code tab) in
// the main area on the right; a left column with the three control groups tabbed
// together on top and Data (+ Raw spec tab) below.
function addPanel(
  id: string,
  title: string,
  position?: Record<string, unknown>,
  inactive = false,
) {
  dvApi.value!.addPanel({
    id,
    component: 'panel',
    title,
    params: { section: id },
    inactive, // secondary tabs are added without stealing focus from the primary
    ...(position ? { position } : {}),
  });
}
// Below this viewport width the dock defaults to the single-column mobile layout.
const MOBILE_BREAKPOINT = 768;

// Desktop: two columns. Left column top→bottom (Separators & frame, then Per-column,
// then Input; Style & width split to the right of Separators to form the top row);
// right column is Output (+ D code below, Raw spec as a background tab beside Output).
function buildDesktopLayout() {
  addPanel('output', 'Output');
  addPanel('separators', 'Separators & frame', {
    referencePanel: 'output',
    direction: 'left',
  });
  addPanel('percol', 'Per-column', {
    referencePanel: 'separators',
    direction: 'below',
  });
  addPanel('data', 'Input', { referencePanel: 'percol', direction: 'below' });
  addPanel('style', 'Style & width', {
    referencePanel: 'separators',
    direction: 'right',
  });
  addPanel('dcode', 'D code', { referencePanel: 'output', direction: 'below' });
  addPanel('rawspec', 'Raw spec', { referencePanel: 'output' }, true);
}

// Mobile: one column of three stacked tab groups — Controls (Separators & frame /
// Style & width / Per-column), Input (Input / Raw spec), Output (Output / D code).
function buildMobileLayout() {
  // Controls group.
  addPanel('separators', 'Separators & frame');
  addPanel('style', 'Style & width', { referencePanel: 'separators' }, true);
  addPanel('percol', 'Per-column', { referencePanel: 'separators' }, true);
  // Input group, below.
  addPanel('data', 'Input', {
    referencePanel: 'separators',
    direction: 'below',
  });
  addPanel('rawspec', 'Raw spec', { referencePanel: 'data' }, true);
  // Output group, below.
  addPanel('output', 'Output', { referencePanel: 'data', direction: 'below' });
  addPanel('dcode', 'D code', { referencePanel: 'output' }, true);
}

function buildDefaultLayout() {
  if (!dvApi.value) return;
  const mobile =
    typeof window !== 'undefined' && window.innerWidth <= MOBILE_BREAKPOINT;
  if (mobile) buildMobileLayout();
  else buildDesktopLayout();
}

// The control panels (Separators & frame / Style & width / Per-column) have short,
// fixed content. Pin their group(s) to a FIXED height (min = max) that fits it: they
// never scroll, and — because they don't grow to take an equal share — the extra
// vertical space flows to the Input row (and Output column), which is what makes room
// for the taller data samples. Idempotent + looks groups up by panel id, so it works
// after both a fresh build and a fromJSON restore.
const CONTROL_HEIGHT = 230;
function applyControlConstraints() {
  const api = dvApi.value;
  if (!api) return;
  const seen = new Set<string>();
  for (const id of ['separators', 'style', 'percol']) {
    const group = api.getPanel(id)?.group;
    if (group && !seen.has(group.id)) {
      seen.add(group.id);
      try {
        group.api.setConstraints({
          minimumHeight: CONTROL_HEIGHT,
          maximumHeight: CONTROL_HEIGHT,
        });
      } catch {}
    }
  }
}
function resetLayout() {
  dropLayout();
  const api = dvApi.value;
  if (!api) return;
  api.clear();
  buildDefaultLayout();
  applyControlConstraints();
}
function onReady(e: DockviewReadyEvent) {
  dvApi.value = e.api;
  // Subscribe BEFORE building the layout so the initial panel adds (and any later
  // drag/dock/resize) are persisted — otherwise the first change that fires is the
  // default build, before anyone is listening, and nothing saves until much later.
  dvDisposable = e.api.onDidLayoutChange(scheduleSave);
  if (!restoreLayout()) buildDefaultLayout();
  applyControlConstraints();
  // Give Dockview an explicit initial size on the next tick — it normally sizes
  // itself from a ResizeObserver, but nudging guards against a late first measure
  // (and makes it deterministic for headless rendering).
  nudgeDock();
}
// Dockview auto-resizes via its own ResizeObserver, but a Teleport (fullscreen
// toggle) can move the node before it re-measures — nudge it on the next tick.
function nudgeDock() {
  nextTick(() => {
    const el = dockEl.value;
    if (el && dvApi.value) dvApi.value.layout(el.clientWidth, el.clientHeight);
  });
}

onUnmounted(() => {
  if (typeof document !== 'undefined') {
    document.body.style.overflow = '';
    window.removeEventListener('keydown', onKey);
  }
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveLayout(); // flush any pending layout write
  }
  dvDisposable?.dispose();
});

// ---- ANSI (SGR) → HTML --------------------------------------------------
const FG: Record<number, string> = {
  30: '#4c566a',
  31: '#bf616a',
  32: '#a3be8c',
  33: '#ebcb8b',
  34: '#81a1c1',
  35: '#b48ead',
  36: '#88c0d0',
  37: '#e5e9f0',
  90: '#616e88',
  91: '#d08770',
  92: '#8fbcbb',
  93: '#ebcb8b',
  94: '#5e81ac',
  95: '#b48ead',
  96: '#8fbcbb',
  97: '#eceff4',
};
function esc(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
type Style = {
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
  fg: string;
  bg: string;
};
const resetStyle = (): Style => ({
  bold: false,
  dim: false,
  italic: false,
  underline: false,
  inverse: false,
  fg: '',
  bg: '',
});
function applySgr(codes: string, st: Style) {
  for (const codeStr of (codes || '0').split(';')) {
    const c = parseInt(codeStr || '0', 10);
    if (c === 0) Object.assign(st, resetStyle());
    else if (c === 1) st.bold = true;
    else if (c === 2) st.dim = true;
    else if (c === 3) st.italic = true;
    else if (c === 4) st.underline = true;
    else if (c === 7) st.inverse = true;
    else if (c === 22) st.bold = st.dim = false;
    else if (c === 23) st.italic = false;
    else if (c === 24) st.underline = false;
    else if (c === 27) st.inverse = false;
    else if (c === 39) st.fg = '';
    else if (c === 49) st.bg = '';
    else if (FG[c]) st.fg = FG[c];
    else if (c >= 40 && c <= 47) st.bg = FG[c - 10];
    else if (c >= 100 && c <= 107) st.bg = FG[c - 10];
  }
}
function styleCss(st: Style): string {
  const d: string[] = [];
  if (st.bold) d.push('font-weight:700');
  if (st.dim) d.push('opacity:.6');
  if (st.italic) d.push('font-style:italic');
  if (st.underline) d.push('text-decoration:underline');
  const fg = st.inverse ? st.bg : st.fg;
  const bg = st.inverse ? st.fg || 'var(--vp-c-text-1)' : st.bg;
  if (fg) d.push('color:' + fg);
  if (bg) d.push('background:' + bg);
  return d.join(';');
}

// Lay the rendered output onto a real terminal grid — the same trick as
// TerminalCellGrid.vue: each grapheme occupies a fixed cell whose width comes from
// `spk_segment` (the SAME oracle drawTable padded with), and `font-size` == the cell
// height with `line-height: 1`, so box-drawing glyphs fill their cell and connect
// across borders. Alignment AND line-joining are thus independent of the browser's
// glyph metrics. ANSI SGR escapes set the per-cell colour/weight; plain padding
// spaces are skipped (the empty grid column already reserves the gap).
const IN_MAX = 115000;
const TRIP_OFF = 120000;
const MAX_TRIPLES = 11000;
const gridOut = computed(() => {
  const s = output.value;
  if (errored.value || !exp) return { html: '', cols: 0 };
  const bytes = new TextEncoder().encode(s);
  if (bytes.length > IN_MAX) return { html: '', cols: 0 };
  const p = exp.spk_buf_ptr();
  new Uint8Array(exp.memory.buffer).set(bytes, p);
  const tripOff = (p + TRIP_OFF) & ~3;
  const n = exp.spk_segment(p, bytes.length, tripOff, MAX_TRIPLES);
  const tri = new Uint32Array(exp.memory.buffer, tripOff, n * 3);
  const dec = new TextDecoder();
  const sgrRe = /^\u001b\[([0-9;]*)m$/;
  const st = resetStyle();
  let html = '';
  let row = 0;
  let col = 0;
  let cols = 0;
  for (let i = 0; i < n; i++) {
    const off = tri[i * 3],
      len = tri[i * 3 + 1],
      w = tri[i * 3 + 2];
    const seg = bytes.subarray(off, off + len);
    if (w === 0) {
      if (len === 1 && seg[0] === 0x0a) {
        row++;
        col = 0;
        continue;
      } // newline → new row
      if (seg[0] === 0x1b) {
        // ANSI escape (SGR) → update style, no cell
        const m = sgrRe.exec(dec.decode(seg));
        if (m) applySgr(m[1], st);
        continue;
      }
      continue; // stray zero-width
    }
    const sty = styleCss(st);
    const raw = dec.decode(seg);
    if (!(raw === ' ' && !sty)) {
      html += `<span class="tpg-gc" style="grid-column:${col + 1}/span ${w};grid-row:${row + 1}${sty ? ';' + sty : ''}">${esc(raw)}</span>`;
    }
    col += w;
    if (col > cols) cols = col;
  }
  return { html, cols };
});

// ---- "Show D code" snippet ---------------------------------------------
const dcode = computed(() => {
  const q = (s: string) =>
    '"' +
    s
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"')
      .replace(/\u001b/g, '\\x1b') +
    '"';
  const parts: string[] = [];
  if (!props.border) parts.push('border: false');
  if (!props.columnSeparators) parts.push('columnSeparators: false');
  if (props.rowSeparators) parts.push('rowSeparators: true');
  if (props.headerRows) parts.push(`headerRows: ${props.headerRows}`);
  if (props.headerCols) parts.push(`headerCols: ${props.headerCols}`);
  if (props.maxWidth) parts.push(`maxWidth: ${props.maxWidth}`);
  if (props.title) parts.push(`title: ${q(props.title)}`);
  if (props.footer) parts.push(`footer: ${q(props.footer)}`);
  if (props.preset !== 'rounded')
    parts.push(`glyphs: stylePresets[${q(props.preset)}]`);
  if (props.defaultAlign !== 'left')
    parts.push(`defaultAlign: Align.${props.defaultAlign}`);
  if (props.defaultVAlign !== 'top')
    parts.push(`defaultVAlign: VAlign.${props.defaultVAlign}`);
  const n = colCount.value;
  const ca = colAligns.value.slice(0, n);
  if (ca.some(a => a !== 'inherit'))
    parts.push(`columnAligns: [${ca.map(a => 'Align.' + a).join(', ')}]`);
  const cv = colVAligns.value.slice(0, n);
  if (cv.some(a => a !== 'inherit'))
    parts.push(`columnVAligns: [${cv.map(a => 'VAlign.' + a).join(', ')}]`);
  const cw = colMaxW.value.slice(0, n);
  if (cw.some(w => w > 0)) parts.push(`columnMaxWidths: [${cw.join(', ')}]`);
  const propStr = parts.length
    ? `TableProps(\n    ${parts.join(',\n    ')},\n)`
    : 'TableProps.init';

  if (dataMode.value === 'grid') {
    const rows = gridCells.value
      .map(r => '    [' + r.map(q).join(', ') + ']')
      .join(',\n');
    return `drawTable([\n${rows},\n], ${propStr})`;
  }
  return `// ${rawMode.value} spec — see the JSON editor above\ndrawTable(/* … */, ${propStr})`;
});

// ---- Syntax highlighting (Shiki) for the Raw spec / D code panels ------
// Shiki is what VitePress highlights code blocks with, so the panels match the
// site. It is loaded client-only (dynamic import in onMounted; this component is
// under <ClientOnly> and SSR-evaluated) with just the json + d grammars and the
// github light/dark themes. Until it resolves, the panels fall back to plain <pre>.
const highlighter = shallowRef<{
  codeToHtml: (code: string, opts: any) => string;
} | null>(null);
onMounted(async () => {
  try {
    const { createHighlighter } = await import('shiki');
    highlighter.value = await createHighlighter({
      themes: ['github-light', 'github-dark'],
      langs: ['json', 'd'],
    });
  } catch {
    // leave null → panels show plain <pre> fallbacks
  }
});
function highlight(code: string, lang: 'json' | 'd'): string {
  const h = highlighter.value;
  if (!h) return '';
  try {
    return h.codeToHtml(code, {
      lang,
      theme: isDark.value ? 'github-dark' : 'github-light',
    });
  } catch {
    return '';
  }
}
// Recompute when the source, the highlighter, or the site theme changes.
const rawSpecHtml = computed(() =>
  highlight(JSON.stringify(currentSpec(), null, 2), 'json'),
);
const dcodeHtml = computed(() => highlight(dcode.value, 'd'));

// Expose the engine to the Dockview panels (TpgPanel injects this). Refs/reactives
// keep their reactivity across provide/inject; the panels read and write them so
// every panel drives the same render pipeline.
provide(tpgKey, {
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
});
</script>

<template>
  <div class="tpg-host">
    <Teleport to="body" :disabled="!isFullscreen">
      <div class="tpg" :class="{ 'tpg--fs': isFullscreen }">
        <!-- Top bar: samples (or status) + fullscreen toggle -->
        <div class="tpg-bar">
          <div v-if="!status" class="tpg-samples">
            Samples:
            <button
              v-for="s in samples"
              :key="s.label"
              class="tpg-chip"
              @click="applySample(s)"
            >
              {{ s.label }}
            </button>
          </div>
          <span v-else class="tpg-status">{{ status }}</span>
          <button
            v-if="!status"
            class="tpg-fsbtn"
            title="Reset panel layout"
            aria-label="Reset panel layout"
            @click="resetLayout"
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <polyline points="1 4 1 10 7 10" />
              <path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10" />
            </svg>
          </button>
          <button
            class="tpg-fsbtn"
            :title="
              isFullscreen ? 'Exit fullscreen (Esc)' : 'Expand to fullscreen'
            "
            :aria-label="
              isFullscreen ? 'Exit fullscreen' : 'Expand to fullscreen'
            "
            @click="toggleFs"
          >
            <svg
              v-if="!isFullscreen"
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path
                d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"
              />
            </svg>
            <svg
              v-else
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M4 14h6m0 0v6m0-6l-7 7M20 10h-6m0 0V4m0 6l7-7" />
            </svg>
          </button>
        </div>

        <template v-if="!status">
          <!-- Dockable panels: Controls / Data / Output as draggable, dockable,
              resizable Dockview panels. Each panel is a TpgPanel selected by
              params.section; all three share one render engine via provide/inject
              (dockview-vue resolves the `component` name against :components). -->
          <div ref="dockEl" class="tpg-dock">
            <DockviewVue
              class="tpg-dv"
              :components="dvComponents"
              :theme="dvTheme"
              @ready="onReady"
            />
          </div>
        </template>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
/* Self-hosted FiraCode Nerd Font Mono (subset: Latin + box-drawing + shapes, no
  ligatures) so the box-drawing frame renders identically on every device instead
  of relying on whatever monospace the visitor happens to have. Built from
  nixpkgs#nerd-fonts.fira-code; regenerate the woff2 in docs/public/fonts/. */
@font-face {
  font-family: 'FiraCodePlayground';
  src: url('/fonts/firacode-nerd-mono-regular.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: 'FiraCodePlayground';
  src: url('/fonts/firacode-nerd-mono-bold.woff2') format('woff2');
  font-weight: 700;
  font-style: normal;
  font-display: swap;
}
.tpg {
  --tpg-mono: 'FiraCodePlayground', var(--vp-font-family-mono), monospace;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
/* Fullscreen: the real (live) widget is Teleported to <body> and pinned. It becomes
  a flex column (bar + dock) so the dock grows to fill the viewport; the dock owns
  its own internal scrolling, so the page itself does not scroll. */
.tpg--fs {
  position: fixed;
  inset: 0;
  z-index: 100;
  margin: 0;
  border: none;
  border-radius: 0;
  padding: 1.25rem clamp(1rem, 4vw, 3rem);
  background: var(--vp-c-bg);
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

/* Top bar */
.tpg-bar {
  display: flex;
  align-items: flex-start;
  gap: 0.75rem;
  margin-bottom: 0.9rem;
}
.tpg-samples {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  align-items: center;
  flex: 1;
  font-size: 0.85rem;
  color: var(--vp-c-text-2);
}
.tpg-status {
  flex: 1;
  color: var(--vp-c-text-2);
  font-style: italic;
}
.tpg-chip {
  font-size: 0.8rem;
  padding: 0.25rem 0.55rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg-soft);
  cursor: pointer;
}
.tpg-chip:hover {
  border-color: var(--vp-c-brand-1);
}
/* Fullscreen toggle — matches the doc-wide expand button look. */
.tpg-fsbtn {
  flex: none;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  padding: 0;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-2);
  cursor: pointer;
  transition:
    color 0.15s ease,
    border-color 0.15s ease;
}
.tpg-fsbtn:hover {
  color: var(--vp-c-brand-1);
  border-color: var(--vp-c-brand-1);
}

/* Dockable panels (Dockview). The three content blocks live in draggable,
  resizable Dockview panels. The dock needs an explicit height; `resize: vertical`
  lets the reader grow the whole board (the same native-resize idiom the textareas
  use). In fullscreen it flex-grows to fill the viewport instead. */
.tpg-dock {
  height: 82vh;
  /* Tall enough that the desktop layout's left column — two control rows (each
    pinned to fit its content) plus the Input row — shows the Input tab in full,
    not squeezed. */
  min-height: 740px;
  resize: vertical;
  overflow: hidden;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
}
.tpg--fs .tpg-dock {
  height: auto;
  min-height: 0;
  flex: 1;
  resize: none;
}
/* The single-column mobile default stacks three groups, so give the inline dock
  more vertical room on narrow screens. */
@media (max-width: 768px) {
  .tpg-dock {
    height: 78vh;
    min-height: 540px;
  }
}
.tpg-dv {
  width: 100%;
  height: 100%;
}
/* Round the tab corners to match the site's rounded surfaces — the (non-spaced)
  github theme ships square tabs. Top corners only, so each tab still meets its
  panel body flush below. The dockview DOM is built imperatively, so reach the tabs
  with :deep from the scoped .tpg-dock root. */
.tpg-dock :deep(.dv-tab) {
  border-radius: 6px 6px 0 0;
}
</style>
