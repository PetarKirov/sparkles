<script setup>
import DefaultTheme from "vitepress/theme";
import { useRoute } from "vitepress";
import { onMounted, onUnmounted, watch, nextTick } from "vue";

const { Layout } = DefaultTheme;
const route = useRoute();

const EXPAND_BTN_CLS = "content-expand-btn";
const TABLE_WRAPPER_CLS = "table-expand-wrapper";
const CODE_ACTIONS_CLS = "code-block-actions";

let overlay = null;

function createOverlay() {
  overlay = document.createElement("div");
  overlay.className = "content-expand-overlay";
  overlay.setAttribute("aria-modal", "true");
  overlay.setAttribute("role", "dialog");
  overlay.innerHTML = `
    <div class="content-expand-backdrop"></div>
    <div class="content-expand-toolbar">
      <button class="content-expand-close" title="Close (Esc)" aria-label="Close">
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24"
          fill="none" stroke="currentColor" stroke-width="2"
          stroke-linecap="round" stroke-linejoin="round">
          <line x1="18" y1="6" x2="6" y2="18"/>
          <line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
    <div class="content-expand-container">
      <div class="content-expand-body vp-doc"></div>
    </div>
  `;
  overlay.style.display = "none";

  overlay
    .querySelector(".content-expand-backdrop")
    .addEventListener("click", closeOverlay);
  overlay
    .querySelector(".content-expand-close")
    .addEventListener("click", closeOverlay);

  document.body.appendChild(overlay);
}

function setupExpandButtons() {
  document.querySelectorAll(`.${EXPAND_BTN_CLS}`).forEach((b) => b.remove());

  // Tables
  for (const table of document.querySelectorAll(".vp-doc table")) {
    let wrapper = table.closest(`.${TABLE_WRAPPER_CLS}`);
    if (!wrapper) {
      wrapper = document.createElement("div");
      wrapper.className = TABLE_WRAPPER_CLS;
      table.parentNode.insertBefore(wrapper, table);
      wrapper.appendChild(table);
    }
    addExpandButton(wrapper, table);
  }

  // Code groups — actions bar on the group container, over the tabs
  for (const group of document.querySelectorAll(".vp-doc .vp-code-group")) {
    if (group.querySelector(`.${CODE_ACTIONS_CLS}`)) continue;
    const actionsBar = document.createElement("div");
    actionsBar.className = CODE_ACTIONS_CLS;
    const expandBtn = createExpandButton(group);
    // Move the active tab's copy button into the actions bar, then expand
    syncCopyButton(group, actionsBar);
    actionsBar.appendChild(expandBtn);
    group.appendChild(actionsBar);
    // Update copy button when tabs change
    for (const input of group.querySelectorAll(".tabs input")) {
      input.addEventListener("change", () => syncCopyButton(group, actionsBar));
    }
  }

  // Standalone code blocks (not inside a code group)
  for (const block of document.querySelectorAll(
    '.vp-doc div[class*="language-"]',
  )) {
    if (block.closest(".vp-code-group")) continue;
    if (block.querySelector(`.${CODE_ACTIONS_CLS}`)) continue;
    const copyBtn = block.querySelector("button.copy");
    const actionsBar = document.createElement("div");
    actionsBar.className = CODE_ACTIONS_CLS;
    if (copyBtn) actionsBar.appendChild(copyBtn);
    actionsBar.appendChild(createExpandButton(block));
    block.appendChild(actionsBar);
  }
}

let overlayGroupCounter = 0;

function fixClonedCodeGroupTabs(group) {
  const suffix = `-overlay-${overlayGroupCounter++}`;
  for (const input of group.querySelectorAll(".tabs input")) {
    const oldId = input.id;
    input.id = oldId + suffix;
    input.name = input.name + suffix;
    const label = group.querySelector(`label[for="${oldId}"]`);
    if (label) label.setAttribute("for", input.id);
  }
}

function syncCopyButton(group, actionsBar) {
  // Return any previous copy button to its code block
  const prev = actionsBar.querySelector("button.copy");
  if (prev) {
    const prevBlock = group.querySelector(
      'div[class*="language-"]:not(.active)',
    );
    if (prevBlock) prevBlock.appendChild(prev);
  }
  // Move the active tab's copy button into the actions bar
  const copyBtn = group.querySelector(
    'div[class*="language-"].active button.copy',
  );
  if (copyBtn) actionsBar.appendChild(copyBtn);
}

function createExpandButton(contentEl) {
  const btn = document.createElement("button");
  btn.className = EXPAND_BTN_CLS;
  btn.title = "Expand to fullscreen";
  btn.setAttribute("aria-label", "Expand to fullscreen");
  btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24"
    fill="none" stroke="currentColor" stroke-width="2"
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/>
  </svg>`;
  btn.addEventListener("click", () => openOverlay(contentEl));
  return btn;
}

function addExpandButton(container, contentEl) {
  container.appendChild(createExpandButton(contentEl));
}

function openOverlay(contentEl) {
  if (!overlay) return;
  const body = overlay.querySelector(".content-expand-body");
  body.innerHTML = "";

  const clone = contentEl.cloneNode(true);

  // Extract the copy button before removing actions bars that contain it
  const toolbar = overlay.querySelector(".content-expand-toolbar");
  const existingCopy = toolbar.querySelector("button.copy");
  if (existingCopy) existingCopy.remove();

  const copyBtn = clone.querySelector("button.copy");
  if (copyBtn) {
    copyBtn.remove();
    toolbar.insertBefore(copyBtn, toolbar.firstChild);
  }

  // Now remove expand buttons and actions bars from the clone
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

  body.appendChild(clone);

  overlay.style.display = "";
  document.body.style.overflow = "hidden";
  overlay.querySelector(".content-expand-close").focus();
}

function closeOverlay() {
  if (!overlay) return;
  overlay.style.display = "none";
  document.body.style.overflow = "";
  overlay.querySelector(".content-expand-body").innerHTML = "";
}

function handleKeydown(e) {
  if (e.key === "Escape" && overlay && overlay.style.display !== "none") {
    closeOverlay();
  }
}

onMounted(() => {
  createOverlay();
  setupExpandButtons();
  document.addEventListener("keydown", handleKeydown);
});

onUnmounted(() => {
  document.removeEventListener("keydown", handleKeydown);
  if (overlay) {
    overlay.remove();
    overlay = null;
  }
});

watch(
  () => route.path,
  () => nextTick(setupExpandButtons),
);
</script>

<template>
  <Layout />
</template>
