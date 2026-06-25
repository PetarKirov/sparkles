<script setup lang="ts">
import { ref } from 'vue';

const props = defineProps<{
  pkg: string;
}>();

// Generate a unique name for the radio group to prevent interference between multiple instances
const groupName = 'install-group-' + Math.floor(Math.random() * 1000000);

const activeTab = ref(0);
</script>

<template>
  <div class="vp-code-group vp-adaptive-theme">
    <div class="tabs">
      <input
        type="radio"
        :name="groupName"
        :id="groupName + '-tab-0'"
        :checked="activeTab === 0"
        @change="activeTab = 0"
      />
      <label data-title="dub add" :for="groupName + '-tab-0'">dub add</label>

      <input
        type="radio"
        :name="groupName"
        :id="groupName + '-tab-1'"
        :checked="activeTab === 1"
        @change="activeTab = 1"
      />
      <label data-title="Single-file" :for="groupName + '-tab-1'"
        >Single-file</label
      >

      <input
        type="radio"
        :name="groupName"
        :id="groupName + '-tab-2'"
        :checked="activeTab === 2"
        @change="activeTab = 2"
      />
      <label data-title="dub.sdl" :for="groupName + '-tab-2'">dub.sdl</label>

      <input
        type="radio"
        :name="groupName"
        :id="groupName + '-tab-3'"
        :checked="activeTab === 3"
        @change="activeTab = 3"
      />
      <label data-title="dub.json" :for="groupName + '-tab-3'">dub.json</label>
    </div>

    <div class="blocks">
      <!-- 0: dub add -->
      <div
        class="language-sh vp-adaptive-theme"
        :class="{ active: activeTab === 0 }"
      >
        <button title="Copy Code" class="copy"></button>
        <span class="lang">sh</span>
        <pre
          class="shiki shiki-themes github-light github-dark vp-code"
          tabindex="0"
        ><code><span class="line"><span style="--shiki-light:#6F42C1;--shiki-dark:#B392F0;">dub</span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;"> add </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">{{ pkg }}</span></span></code></pre>
      </div>

      <!-- 1: Single-file -->
      <div
        class="language-d vp-adaptive-theme"
        :class="{ active: activeTab === 1 }"
      >
        <button title="Copy Code" class="copy"></button>
        <span class="lang">d</span>
        <pre
          class="shiki shiki-themes github-light github-dark vp-code"
          tabindex="0"
        ><code><span class="line"><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;font-style:italic;">#!/usr/bin/env dub</span></span>
<span class="line"><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;font-style:italic;">/+ dub.sdl:</span></span>
<span class="line"><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;font-style:italic;">    dependency &quot;</span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;font-style:italic;font-weight:bold;">{{ pkg }}</span><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;font-style:italic;">&quot; version &quot;*&quot;</span></span>
<span class="line"><span style="--shiki-light:#6A737D;--shiki-dark:#6A737D;font-style:italic;">+/</span></span></code></pre>
      </div>

      <!-- 2: dub.sdl -->
      <div
        class="language-d vp-adaptive-theme"
        :class="{ active: activeTab === 2 }"
      >
        <button title="Copy Code" class="copy"></button>
        <span class="lang">sdl</span>
        <pre
          class="shiki shiki-themes github-light github-dark vp-code"
          tabindex="0"
        ><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">dependency </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;{{ pkg }}&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;"> version </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;*&quot;</span></span></code></pre>
      </div>

      <!-- 3: dub.json -->
      <div
        class="language-json vp-adaptive-theme"
        :class="{ active: activeTab === 3 }"
      >
        <button title="Copy Code" class="copy"></button>
        <span class="lang">json</span>
        <pre
          class="shiki shiki-themes github-light github-dark vp-code"
          tabindex="0"
        ><code><span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">{</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;dependencies&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">: {</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">        </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;{{ pkg }}&quot;</span><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">: </span><span style="--shiki-light:#032F62;--shiki-dark:#9ECBFF;">&quot;*&quot;</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">    }</span></span>
<span class="line"><span style="--shiki-light:#24292E;--shiki-dark:#E1E4E8;">}</span></span></code></pre>
      </div>
    </div>
  </div>
</template>
