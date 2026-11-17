<script setup lang="ts">
// The JSON/SDL playground of sparkles:wired (docs/specs/wired/wasm, WW12).
// Loads spk-wired.wasm (the real sparkles:wired and dub recipe schema built
// for wasm32-wasip1 by `nix build .#wired-wasm`) and, as you type, sends
// `spk_wired_run` one JSON request: parse to a document tree, write the
// canonical form, or decode a dub recipe exactly as the Nix module does.
//
// SSR-safe: all WebAssembly work happens in onMounted (client only).
import { ref, watch, onMounted } from 'vue';
import { loadModule } from '../wasi';

type Format = 'sdl' | 'json';
type Op = 'parse' | 'format' | 'recipe';
type WiredError = {
  name: string;
  line: number;
  column: number;
  code: string;
  message: string;
};

const presets: { label: string; format: Format; op: Op; text: string }[] = [
  {
    label: 'SDL document',
    format: 'sdl',
    op: 'parse',
    text: 'server "web" port=8080 {\n    // values keep their kinds\n    started 2026/11/17 12:30:00\n    ratio 0.75\n    tags "edge" "tls"\n}\n',
  },
  {
    label: 'dub.sdl recipe',
    format: 'sdl',
    op: 'recipe',
    text: 'name "app"\ndependency "sparkles:base" path="../.."\n\nconfiguration "application" {\n    targetType "executable"\n}\n',
  },
  {
    label: 'dub.json recipe',
    format: 'json',
    op: 'recipe',
    text: '{\n  "name": "app",\n  "dependencies": { "sparkles:base": { "path": "../.." } },\n  "dflags-ldc": ["-O"]\n}\n',
  },
  {
    label: 'JSON document',
    format: 'json',
    op: 'format',
    text: '{"name":"wired","formats":["json","sdl"],"nested":{"ok":true,"n":-2.5e3}}',
  },
  {
    label: 'a recipe error',
    format: 'sdl',
    op: 'recipe',
    text: 'name "app"\ntargetTyp "library"\n',
  },
];

const format = ref<Format>('sdl');
const op = ref<Op>('parse');
const input = ref(presets[0].text);
const output = ref('');
const error = ref<WiredError | null>(null);
const status = ref('loading the module…');

let exp: any = null;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function withBase(p: string) {
  const base = (import.meta as any).env?.BASE_URL ?? '/';
  return base.replace(/\/$/, '') + '/' + p;
}

function applyPreset(p: (typeof presets)[number]) {
  format.value = p.format;
  op.value = p.op;
  input.value = p.text;
}

function run() {
  if (!exp) return;
  const request = encoder.encode(
    JSON.stringify({ op: op.value, format: format.value, text: input.value }),
  );
  const base = exp.spk_buf_ptr();
  const half = Math.floor(exp.spk_buf_cap() / 2);
  if (request.length > half) {
    status.value = 'input too long for the module’s buffer';
    return;
  }
  new Uint8Array(exp.memory.buffer).set(request, base);
  const n = exp.spk_wired_run(base, request.length, base + half, half);
  if (n < 0) {
    status.value = 'the response does not fit the module’s buffer';
    return;
  }
  const response = JSON.parse(
    decoder.decode(new Uint8Array(exp.memory.buffer, base + half, n)),
  );
  status.value = '';
  error.value = response.error ?? null;
  if (response.fault) status.value = response.fault;
  else if ('text' in response) output.value = response.text;
  else if ('tree' in response)
    output.value = JSON.stringify(response.tree, null, 2);
  else if ('recipe' in response)
    output.value = JSON.stringify(response.recipe, null, 2);
  else output.value = '';
}

watch([format, op, input], run);

onMounted(async () => {
  try {
    exp = await loadModule(withBase('spk-wired.wasm'));
    status.value = '';
    run();
  } catch (e: any) {
    status.value = 'failed to load wasm: ' + (e?.message ?? e);
  }
});
</script>

<template>
  <div class="wpg">
    <div class="wpg-presets">
      Examples:
      <button
        v-for="p in presets"
        :key="p.label"
        class="wpg-chip"
        @click="applyPreset(p)"
      >
        {{ p.label }}
      </button>
    </div>
    <div class="wpg-controls">
      <div class="wpg-group" role="group" aria-label="format">
        <button
          class="wpg-chip"
          :class="{ active: format === 'sdl' }"
          @click="format = 'sdl'"
        >
          SDL
        </button>
        <button
          class="wpg-chip"
          :class="{ active: format === 'json' }"
          @click="format = 'json'"
        >
          JSON
        </button>
      </div>
      <div class="wpg-group" role="group" aria-label="operation">
        <button
          class="wpg-chip"
          :class="{ active: op === 'parse' }"
          @click="op = 'parse'"
        >
          Document tree
        </button>
        <button
          class="wpg-chip"
          :class="{ active: op === 'format' }"
          @click="op = 'format'"
        >
          Canonical text
        </button>
        <button
          class="wpg-chip"
          :class="{ active: op === 'recipe' }"
          @click="op = 'recipe'"
        >
          dub recipe
        </button>
      </div>
    </div>
    <div class="wpg-panes">
      <textarea
        v-model="input"
        class="wpg-input"
        rows="12"
        spellcheck="false"
        aria-label="document text"
      ></textarea>
      <div class="wpg-out">
        <div v-if="error" class="wpg-error" role="alert">
          <strong>{{ error.name }}:{{ error.line }}:{{ error.column }}</strong>
          <code>{{ error.code }}</code> — {{ error.message }}
        </div>
        <pre v-else class="wpg-result">{{ output }}</pre>
      </div>
    </div>
    <p v-if="status" class="wpg-status">{{ status }}</p>
  </div>
</template>

<style scoped>
.wpg {
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
.wpg-presets,
.wpg-controls,
.wpg-group {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  align-items: center;
}
.wpg-controls {
  margin: 0.6rem 0;
  gap: 1rem;
}
.wpg-chip {
  border: 1px solid var(--vp-c-divider);
  border-radius: 999px;
  padding: 0.1rem 0.7rem;
  font-size: 0.85rem;
  background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-1);
  cursor: pointer;
}
.wpg-chip.active {
  border-color: var(--vp-c-brand-1);
  color: var(--vp-c-brand-1);
}
.wpg-panes {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr));
  gap: 0.75rem;
}
.wpg-input,
.wpg-result {
  font-family: var(--vp-font-family-mono);
  font-size: 0.85rem;
  line-height: 1.45;
  margin: 0;
  padding: 0.5rem 0.7rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  min-height: 14rem;
  max-height: 28rem;
  overflow: auto;
  white-space: pre;
}
.wpg-input {
  resize: vertical;
  width: 100%;
  box-sizing: border-box;
}
.wpg-error {
  padding: 0.6rem 0.8rem;
  border-radius: 6px;
  border: 1px solid var(--vp-c-danger-2);
  background: var(--vp-c-danger-soft);
  color: var(--vp-c-text-1);
  font-size: 0.9rem;
}
.wpg-status {
  margin: 0.5rem 0 0;
  font-size: 0.85rem;
  color: var(--vp-c-text-2);
}
</style>
