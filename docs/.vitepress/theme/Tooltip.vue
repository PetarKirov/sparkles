<script setup lang="ts">
import { ref, nextTick } from 'vue';

const props = withDefaults(
  defineProps<{
    text: string;
    placement?: 'top' | 'bottom';
  }>(),
  {
    placement: 'top',
  },
);

const isVisible = ref(false);
const triggerRef = ref<HTMLElement | null>(null);
const tooltipStyle = ref({ top: '0px', left: '0px', opacity: '0' });

function showTooltip() {
  isVisible.value = true;
  nextTick(() => {
    const trigger = triggerRef.value;
    if (!trigger) return;

    const rect = trigger.getBoundingClientRect();
    const scrollX = window.scrollX;
    const scrollY = window.scrollY;

    let top = 0;
    let left = 0;

    if (props.placement === 'top') {
      left = rect.left + scrollX + rect.width / 2;
      top = rect.top + scrollY - 8;
    } else if (props.placement === 'bottom') {
      left = rect.left + scrollX + rect.width / 2;
      top = rect.bottom + scrollY + 8;
    }

    tooltipStyle.value = {
      top: `${top}px`,
      left: `${left}px`,
      opacity: '1',
    };
  });
}

function hideTooltip() {
  isVisible.value = false;
  tooltipStyle.value = { top: '0px', left: '0px', opacity: '0' };
}
</script>

<template>
  <span
    ref="triggerRef"
    class="tooltip-trigger"
    @mouseenter="showTooltip"
    @mouseleave="hideTooltip"
    @focusin="showTooltip"
    @focusout="hideTooltip"
  >
    <slot />
  </span>

  <Teleport to="body">
    <Transition name="fade">
      <div
        v-if="isVisible"
        class="tooltip-content-global"
        :class="`placement-${placement}`"
        :style="tooltipStyle"
      >
        {{ text }}
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.tooltip-trigger {
  display: inline-flex;
  cursor: help;
}

.tooltip-content-global {
  position: absolute;
  background-color: var(--vp-c-bg-elv, #1e1e20);
  color: var(--vp-c-text-1, #fffff5);
  text-align: center;
  padding: 8px 12px;
  border-radius: 6px;
  border: 1px solid var(--vp-c-divider, rgba(82, 82, 89, 0.32));
  box-shadow: var(--vp-shadow-3);
  white-space: normal;
  width: 240px;
  z-index: 9999;
  font-size: 12px;
  font-weight: normal;
  line-height: 1.4;
  pointer-events: none;
}

.placement-top {
  transform: translate(-50%, -100%);
}

.placement-top::after {
  content: '';
  position: absolute;
  top: 100%;
  left: 50%;
  transform: translateX(-50%);
  border-width: 6px;
  border-style: solid;
  border-color: var(--vp-c-divider, rgba(82, 82, 89, 0.32)) transparent
    transparent transparent;
}

.placement-bottom {
  transform: translate(-50%, 0);
}

.placement-bottom::after {
  content: '';
  position: absolute;
  bottom: 100%;
  left: 50%;
  transform: translateX(-50%);
  border-width: 6px;
  border-style: solid;
  border-color: transparent transparent
    var(--vp-c-divider, rgba(82, 82, 89, 0.32)) transparent;
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.15s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0 !important;
}
</style>
