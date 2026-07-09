// Shared reactive store passed from TablePlayground.vue to its Dockview panels.
//
// dockview-vue (v7) renders each panel as a *detached* component tree resolved by
// name from the `:components` map — it does not forward the parent's slots. It does,
// however, merge the parent DockviewVue instance's `provides` into each panel's app
// context, so a `provide()` in TablePlayground is injectable in the panel component.
// This key carries the whole engine (control refs, computeds, render helpers) across
// that seam so all three panels drive the one shared drawTable render pipeline.
import type { InjectionKey } from 'vue';

// The store is a bag of refs/reactives/computeds/functions; typing every field buys
// little here (esbuild strips types, and the panel just forwards them to the
// template), so keep it loose.
export type TpgStore = Record<string, any>;

export const tpgKey: InjectionKey<TpgStore> = Symbol('tpgStore');
