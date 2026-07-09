<script setup lang="ts">
// A small numeric stepper: a number input flanked by always-visible −/+ buttons.
// Native <input type=number> spinners are hover-only in Chromium and don't theme
// well in dark mode, so we render our own buttons and hide the native ones. Value
// is clamped to [min, max] on every change (button, typing, or wheel).
const props = defineProps<{
  modelValue: number;
  min?: number;
  max?: number;
  step?: number;
  ariaLabel?: string;
}>();
const emit = defineEmits<{ 'update:modelValue': [number] }>();

function clamp(v: number): number {
  if (Number.isNaN(v)) v = props.min ?? 0;
  if (props.min != null && v < props.min) v = props.min;
  if (props.max != null && v > props.max) v = props.max;
  return v;
}
function set(v: number) {
  const c = clamp(v);
  if (c !== props.modelValue) emit('update:modelValue', c);
}
const stepBy = (d: number) =>
  set((props.modelValue || 0) + d * (props.step ?? 1));
function onInput(e: Event) {
  set(Number((e.target as HTMLInputElement).value));
}
</script>

<template>
  <span class="tpg-num">
    <button
      type="button"
      class="tpg-num-btn"
      tabindex="-1"
      aria-label="decrement"
      :disabled="min != null && modelValue <= min"
      @click="stepBy(-1)"
    >
      −
    </button>
    <input
      class="tpg-num-input"
      type="number"
      :value="modelValue"
      :min="min"
      :max="max"
      :step="step ?? 1"
      :aria-label="ariaLabel"
      @input="onInput"
    />
    <button
      type="button"
      class="tpg-num-btn"
      tabindex="-1"
      aria-label="increment"
      :disabled="max != null && modelValue >= max"
      @click="stepBy(1)"
    >
      +
    </button>
  </span>
</template>

<style scoped>
.tpg-num {
  display: inline-flex;
  align-items: stretch;
  border: 1px solid var(--vp-c-divider);
  border-radius: 5px;
  overflow: hidden;
  background: var(--vp-c-bg);
  vertical-align: middle;
}
.tpg-num-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 1.35rem;
  padding: 0;
  border: none;
  background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-2);
  font-size: 0.95rem;
  line-height: 1;
  cursor: pointer;
  user-select: none;
}
.tpg-num-btn:hover:not(:disabled) {
  color: var(--vp-c-brand-1);
  background: var(--vp-c-brand-soft);
}
.tpg-num-btn:disabled {
  opacity: 0.4;
  cursor: default;
}
.tpg-num-input {
  width: 2.4rem;
  padding: 0.12rem 0.2rem;
  border: none;
  border-left: 1px solid var(--vp-c-divider);
  border-right: 1px solid var(--vp-c-divider);
  background: transparent;
  color: var(--vp-c-text-1);
  font-size: 0.82rem;
  text-align: center;
  /* Hide the native spinners — the −/+ buttons replace them. */
  appearance: textfield;
  -moz-appearance: textfield;
}
.tpg-num-input::-webkit-inner-spin-button,
.tpg-num-input::-webkit-outer-spin-button {
  -webkit-appearance: none;
  margin: 0;
}
</style>
