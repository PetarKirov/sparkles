<script setup lang="ts">
import { ref, computed } from 'vue';

interface Segment {
  text: string;
  link: string | null;
  copyText: string;
}

const props = defineProps<{
  segments: Segment[];
}>();

const filteredSegments = computed(() => {
  return props.segments.filter(s => s.text !== 'Home');
});

const copiedIndex = ref<number | null>(null);
const copiedAll = ref(false);
const activeTooltipIndex = ref<number | null>(null);
let timeoutId: ReturnType<typeof setTimeout> | null = null;

function copySegment(text: string, index: number) {
  if (!text) return;
  navigator.clipboard.writeText(text);
  copiedIndex.value = index;
  copiedAll.value = false;
  activeTooltipIndex.value = null; // Hide tooltip immediately on click
  if (timeoutId) clearTimeout(timeoutId);
  timeoutId = setTimeout(() => {
    copiedIndex.value = null;
  }, 2000);
}

function copyAll() {
  const lastSeg = props.segments[props.segments.length - 1];
  if (!lastSeg || !lastSeg.copyText) return;
  navigator.clipboard.writeText(lastSeg.copyText);
  copiedAll.value = true;
  copiedIndex.value = null;
  if (timeoutId) clearTimeout(timeoutId);
  timeoutId = setTimeout(() => {
    copiedAll.value = false;
  }, 2000);
}
</script>

<template>
  <div class="breadcrumbs-container">
    <div class="breadcrumbs-list">
      <template v-for="(segment, idx) in filteredSegments" :key="idx">
        <!-- separator -->
        <span v-if="idx > 0" class="breadcrumb-separator">/</span>

        <!-- segment wrapper -->
        <div
          class="breadcrumb-segment-wrapper"
          @mouseenter="activeTooltipIndex = idx"
          @mouseleave="activeTooltipIndex = null"
        >
          <!-- styled inline code snippet -->
          <a
            v-if="segment.link"
            :href="segment.link"
            class="breadcrumb-segment-link"
          >
            <code>{{ segment.text }}</code>
          </a>
          <span v-else class="breadcrumb-segment-text">
            <code>{{ segment.text }}</code>
          </span>

          <!-- tooltip copy button shown on hover -->
          <div
            v-if="segment.copyText && activeTooltipIndex === idx"
            class="breadcrumb-tooltip"
          >
            <button
              class="breadcrumb-tooltip-btn"
              @click.stop="copySegment(segment.copyText, idx)"
              :aria-label="'Copy path up to ' + segment.text"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                <path
                  d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"
                />
              </svg>
              <span>{{ copiedIndex === idx ? 'Copied!' : 'Copy path' }}</span>
            </button>
          </div>
        </div>
      </template>
    </div>

    <!-- always visible copy button for entire path -->
    <button
      class="breadcrumb-copy-all-btn"
      @click="copyAll"
      title="Copy entire path"
      aria-label="Copy entire path"
    >
      <svg
        v-if="!copiedAll"
        xmlns="http://www.w3.org/2000/svg"
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
        <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
      </svg>
      <svg
        v-else
        xmlns="http://www.w3.org/2000/svg"
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <polyline points="20 6 9 17 4 12" />
      </svg>
      <span class="copy-all-label">{{
        copiedAll ? 'Copied!' : 'Copy Path'
      }}</span>
    </button>
  </div>
</template>

<style scoped>
.breadcrumbs-container {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 12px;
  margin-bottom: 24px;
  font-size: 14px;
}

.breadcrumbs-list {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 1px;
}

.breadcrumb-separator {
  color: var(--vp-c-text-3);
  user-select: none;
}

.breadcrumb-segment-wrapper {
  position: relative;
  display: inline-flex;
  align-items: center;
}

.breadcrumb-segment-link code {
  color: var(--vp-c-brand-1);
  transition: color 0.2s;
  cursor: pointer;
}

.breadcrumb-segment-link:hover code {
  color: var(--vp-c-brand-2);
  background-color: var(--vp-c-brand-soft);
}

.breadcrumb-segment-text code {
  color: var(--vp-c-text-1);
  font-weight: 600;
}

.breadcrumb-segment-wrapper code {
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  background-color: var(--vp-code-bg);
  padding: 3px 6px;
  border-radius: 4px;
  border: 1px solid var(--vp-c-divider-light, rgba(82, 82, 89, 0.18));
}

/* Tooltip copy button shown on hover */
.breadcrumb-tooltip {
  position: absolute;
  bottom: 100%;
  left: 50%;
  transform: translateX(-50%) translateY(-6px);
  background-color: var(--vp-c-bg-elv, #1e1e20);
  border: 1px solid var(--vp-c-divider);
  border-radius: 4px;
  padding: 4px 8px;
  display: block;
  z-index: 100;
  box-shadow: var(--vp-shadow-3);
  white-space: nowrap;
}

.breadcrumb-tooltip::after {
  content: '';
  position: absolute;
  top: 100%;
  left: 50%;
  transform: translateX(-50%);
  border-width: 5px;
  border-style: solid;
  border-color: var(--vp-c-divider) transparent transparent transparent;
}

.breadcrumb-tooltip-btn {
  display: flex;
  align-items: center;
  gap: 4px;
  color: var(--vp-c-text-2);
  font-size: 11px;
  font-weight: 500;
  border: none;
  background: transparent;
  cursor: pointer;
  padding: 0;
}

.breadcrumb-tooltip-btn:hover {
  color: var(--vp-c-text-1);
}

/* Always visible copy button at the end */
.breadcrumb-copy-all-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 10px;
  font-size: 12px;
  font-weight: 500;
  color: var(--vp-c-text-2);
  background-color: var(--vp-code-bg);
  border: 1px solid var(--vp-c-divider);
  border-radius: 4px;
  cursor: pointer;
  transition: all 0.2s;
  height: 26px;
}

.breadcrumb-copy-all-btn:hover {
  color: var(--vp-c-text-1);
  border-color: var(--vp-c-text-3);
  background-color: var(--vp-c-bg-elv);
}

.copy-all-label {
  font-family: var(--vp-font-family-base);
}
</style>
