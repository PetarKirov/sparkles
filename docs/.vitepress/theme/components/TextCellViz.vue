<script setup lang="ts">
// Interactive cell-explorer for the sparkles.base.text spec. Loads spk-text.wasm
// (the real sparkles.base.text compiled to wasm by `nix build .#text-wasm`) and,
// as you type, calls its `spk_segment` export to split the string into grapheme
// clusters and show each one over the terminal cells it occupies.
//
// SSR-safe: all WebAssembly/DOM work happens in onMounted (client only).
import { ref, onMounted } from 'vue';

type Cell = { glyph: string; width: number; cps: string[] };

const presets: { label: string; value: string }[] = [
  { label: 'mixed', value: 'aÁ世\u{1F1FA}\u{1F1F8}कि❤️' },
  {
    label: 'flags',
    value: '\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}\u{1F1EB}\u{1F1F7}',
  },
  { label: 'ZWJ family', value: '\u{1F469}‍\u{1F467}' },
  { label: 'Devanagari', value: 'नमस्ते' },
  { label: 'CJK', value: '世界終わり' },
  { label: 'emoji + VS', value: '❤️\u{1F600}\u{1F3FD}' },
];

const input = ref(presets[0].value);
const cells = ref<Cell[]>([]);
const total = ref(0);
const status = ref('loading…');
let exp: any = null;

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
  const n = exp.spk_segment(p, bytes.length, outP, 64);
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
  <div class="tcv">
    <div class="tcv-controls">
      <div class="tcv-presets">
        Examples:
        <button
          v-for="p in presets"
          :key="p.label"
          class="tcv-preset"
          @click="
            input = p.value;
            update();
          "
        >
          {{ p.label }}
        </button>
      </div>
      <input
        v-model="input"
        class="tcv-input"
        spellcheck="false"
        @input="update"
        aria-label="text to measure"
      />
    </div>

    <p v-if="status" class="tcv-status">{{ status }}</p>

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
</style>
