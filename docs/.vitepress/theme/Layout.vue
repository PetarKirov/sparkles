<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch, nextTick } from "vue";

import { useRoute } from "vitepress";
import DefaultTheme from "vitepress/theme";

const { Layout: VPLayout } = DefaultTheme;
const route = useRoute();

const EXPAND_BTN_CLS = "content-expand-btn";
const TABLE_WRAPPER_CLS = "table-expand-wrapper";
const CODE_ACTIONS_CLS = "code-block-actions";

// --- Reactive state ---
const isOverlayOpen = ref(false);
const hasCodeContent = ref(false);
const isCopied = ref(false);
const overlayRef = ref<HTMLElement | null>(null);
const overlayBodyRef = ref<HTMLElement | null>(null);
const closeButtonRef = ref<HTMLElement | null>(null);

// --- Non-reactive state (not used in template rendering) ---
let triggerElement: HTMLElement | null = null;
let scanController: AbortController | null = null;
let overlayGroupCounter = 0;
let copyTimeout: ReturnType<typeof setTimeout> | null = null;
let pendingContentEl: HTMLElement | null = null;

// --- Overlay ---
function openOverlay(contentEl: HTMLElement) {
  triggerElement = document.activeElement as HTMLElement | null;
  pendingContentEl = contentEl;
  isCopied.value = false;
  isOverlayOpen.value = true;
  document.body.style.overflow = "hidden";

  nextTick(() => {
    if (!overlayBodyRef.value || !pendingContentEl) return;

    const clone = pendingContentEl.cloneNode(true) as HTMLElement;
    pendingContentEl = null;

    // Remove expand buttons and actions bars from the clone
    clone
      .querySelectorAll(`.${EXPAND_BTN_CLS}, .${CODE_ACTIONS_CLS}`)
      .forEach((el) => el.remove());

    // Fix code group tab switching — cloned radio inputs share names with originals
    if (clone.classList?.contains("vp-code-group")) {
      fixClonedCodeGroupTabs(clone);
    }
    for (const group of clone.querySelectorAll(".vp-code-group")) {
      fixClonedCodeGroupTabs(group);
    }

    overlayBodyRef.value.appendChild(clone);
    hasCodeContent.value = !!overlayBodyRef.value.querySelector("pre code");

    closeButtonRef.value?.focus();
  });
}

function closeOverlay() {
  isOverlayOpen.value = false;
  document.body.style.overflow = "";

  if (overlayBodyRef.value) {
    overlayBodyRef.value.innerHTML = "";
  }

  if (copyTimeout) {
    clearTimeout(copyTimeout);
    copyTimeout = null;
  }
  isCopied.value = false;

  // Restore focus to the element that triggered the overlay
  if (triggerElement && typeof triggerElement.focus === "function") {
    triggerElement.focus();
    triggerElement = null;
  }
}

function copyOverlayCode() {
  if (!overlayBodyRef.value) return;
  const codeEl = overlayBodyRef.value.querySelector("pre code");
  if (!codeEl) return;

  navigator.clipboard.writeText(codeEl.textContent ?? "");
  isCopied.value = true;
  if (copyTimeout) clearTimeout(copyTimeout);
  copyTimeout = setTimeout(() => {
    isCopied.value = false;
  }, 2000);
}

// --- Focus trap ---
function handleOverlayKeydown(e: KeyboardEvent) {
  if (e.key === "Escape") {
    closeOverlay();
    return;
  }
  if (e.key !== "Tab" || !overlayRef.value) return;

  const focusable = overlayRef.value.querySelectorAll<HTMLElement>(
    'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
  );
  if (!focusable.length) return;

  const first = focusable[0];
  const last = focusable[focusable.length - 1];

  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault();
    last.focus();
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault();
    first.focus();
  }
}

// --- DOM scanning for expand buttons ---
function setupExpandButtons() {
  if (typeof document === "undefined") return;

  scanController?.abort();
  scanController = new AbortController();
  const { signal } = scanController;

  const root = document.querySelector(".vp-doc") ?? document;

  // Clean up old expand buttons
  root.querySelectorAll(`.${EXPAND_BTN_CLS}`).forEach((b) => b.remove());

  // Add a delegated listener for all moved copy buttons (VitePress's default
  // listener uses a direct child selector which breaks when we wrap the button)
  root.addEventListener(
    "click",
    (e) => {
      const target = e.target as HTMLElement;
      const btn = target.closest(
        `.${CODE_ACTIONS_CLS} button.copy`,
      ) as HTMLButtonElement;
      if (!btn || btn.classList.contains("copied")) return;

      const actionsBar = btn.closest(`.${CODE_ACTIONS_CLS}`) as HTMLElement;
      const parent = actionsBar.parentElement;
      if (!parent) return;

      const codeBlock = parent.classList.contains("vp-code-group")
        ? parent.querySelector('div[class*="language-"].active')
        : parent;

      const codeEl = codeBlock?.querySelector("pre code");
      if (codeEl) {
        navigator.clipboard.writeText(codeEl.textContent || "");
        btn.classList.add("copied");
        setTimeout(() => btn.classList.remove("copied"), 2000);
      }
    },
    { signal },
  );

  // Tables
  for (const table of root.querySelectorAll("table")) {
    let wrapper = table.closest(`.${TABLE_WRAPPER_CLS}`);
    if (!wrapper) {
      wrapper = document.createElement("div");
      wrapper.className = TABLE_WRAPPER_CLS;
      table.parentNode!.insertBefore(wrapper, table);
      wrapper.appendChild(table);
    }
    addExpandButton(wrapper as HTMLElement, table as HTMLElement, signal);
  }

  // Code groups — actions bar on the group container, over the tabs
  for (const group of root.querySelectorAll(".vp-code-group")) {
    if (group.querySelector(`.${CODE_ACTIONS_CLS}`)) continue;
    const actionsBar = document.createElement("div");
    actionsBar.className = CODE_ACTIONS_CLS;
    const expandBtn = createExpandButton(group as HTMLElement, signal);
    // Move the active tab's copy button into the actions bar, then expand
    syncCopyButton(group as HTMLElement, actionsBar);
    actionsBar.appendChild(expandBtn);
    group.appendChild(actionsBar);
    // Update copy button when tabs change
    for (const input of group.querySelectorAll(".tabs input")) {
      input.addEventListener(
        "change",
        () => nextTick(() => syncCopyButton(group as HTMLElement, actionsBar)),
        { signal },
      );
    }
  }

  // Standalone code blocks (not inside a code group)
  for (const block of root.querySelectorAll('div[class*="language-"]')) {
    if (block.closest(".vp-code-group")) continue;
    if (block.querySelector(`.${CODE_ACTIONS_CLS}`)) continue;
    const copyBtn = block.querySelector("button.copy") as any;
    const actionsBar = document.createElement("div");
    actionsBar.className = CODE_ACTIONS_CLS;
    if (copyBtn) {
      copyBtn._originalParent = block;
      actionsBar.appendChild(copyBtn);
    }
    actionsBar.appendChild(createExpandButton(block as HTMLElement, signal));
    block.appendChild(actionsBar);
  }
}

function fixClonedCodeGroupTabs(group: Element) {
  const suffix = `-overlay-${overlayGroupCounter++}`;
  for (const input of group.querySelectorAll(".tabs input")) {
    const oldId = input.id;
    input.id = oldId + suffix;
    (input as HTMLInputElement).name =
      (input as HTMLInputElement).name + suffix;
    const label = group.querySelector(`label[for="${oldId}"]`);
    if (label) label.setAttribute("for", input.id);
  }
}

function syncCopyButton(group: HTMLElement, actionsBar: HTMLElement) {
  // Return any previous copy button to its code block
  const prev = actionsBar.querySelector("button.copy") as any;
  if (prev && prev._originalParent) {
    prev._originalParent.appendChild(prev);
  }
  // Move the active tab's copy button into the actions bar
  const copyBtn = group.querySelector(
    'div[class*="language-"].active button.copy',
  ) as any;
  if (copyBtn) {
    if (!copyBtn._originalParent) {
      copyBtn._originalParent = copyBtn.parentElement;
    }
    actionsBar.appendChild(copyBtn);
  }
}

function createExpandButton(
  contentEl: HTMLElement,
  signal: AbortSignal,
): HTMLButtonElement {
  const btn = document.createElement("button");
  btn.className = EXPAND_BTN_CLS;
  btn.title = "Expand to fullscreen";
  btn.setAttribute("aria-label", "Expand to fullscreen");
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("width", "14");
  svg.setAttribute("height", "14");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute(
    "d",
    "M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3",
  );
  svg.appendChild(path);
  btn.appendChild(svg);
  btn.addEventListener("click", () => openOverlay(contentEl), { signal });
  return btn;
}

function addExpandButton(
  container: HTMLElement,
  contentEl: HTMLElement,
  signal: AbortSignal,
) {
  container.appendChild(createExpandButton(contentEl, signal));
}

// --- Lifecycle ---
onMounted(() => {
  setupExpandButtons();
});

onUnmounted(() => {
  scanController?.abort();
  scanController = null;
  if (copyTimeout) {
    clearTimeout(copyTimeout);
    copyTimeout = null;
  }
  if (isOverlayOpen.value) {
    document.body.style.overflow = "";
  }
});

watch(
  () => route.path,
  () => nextTick(setupExpandButtons),
);
</script>

<template>
  <VPLayout />
  <Teleport to="body">
    <div
      v-if="isOverlayOpen"
      ref="overlayRef"
      class="content-expand-overlay"
      role="dialog"
      aria-modal="true"
      @keydown="handleOverlayKeydown"
    >
      <div class="content-expand-backdrop" @click="closeOverlay" />
      <div class="content-expand-toolbar">
        <button
          v-if="hasCodeContent"
          class="content-expand-copy"
          :title="isCopied ? 'Copied!' : 'Copy code'"
          :aria-label="isCopied ? 'Copied!' : 'Copy code'"
          @click="copyOverlayCode"
        >
          <svg
            v-if="!isCopied"
            xmlns="http://www.w3.org/2000/svg"
            width="18"
            height="18"
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
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <polyline points="20 6 9 17 4 12" />
          </svg>
        </button>
        <button
          ref="closeButtonRef"
          class="content-expand-close"
          title="Close (Esc)"
          aria-label="Close"
          @click="closeOverlay"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <line x1="18" y1="6" x2="6" y2="18" />
            <line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>
      </div>
      <div class="content-expand-container">
        <div ref="overlayBodyRef" class="content-expand-body vp-doc" />
      </div>
    </div>
  </Teleport>
</template>
