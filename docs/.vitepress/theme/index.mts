import DefaultTheme from 'vitepress/theme-without-fonts';
import type { EnhanceAppContext } from 'vitepress';
import Layout from './Layout.vue';
import TextCellViz from './components/TextCellViz.vue';
import TablePlayground from './components/TablePlayground.vue';
import GlossaryList from './components/GlossaryList.vue';
import InstallInstructions from './InstallInstructions.vue';
// Dockview stylesheet powers the drawTable playground's dockable panels. Importing
// it here (the theme entry) is SSR-safe — it is plain CSS, extracted by Vite — and
// loads it once site-wide. The dockview-vue *component* is client-only and is
// dynamically imported inside TablePlayground.vue instead.
import 'dockview-vue/dist/styles/dockview.css';
// The design system's properties (generated; see custom.css's mapping block),
// before the stylesheet that maps VitePress's variables from them.
import './spk.css';
import './custom.css';

export default {
  ...DefaultTheme,
  Layout,
  enhanceApp({ app }: EnhanceAppContext) {
    app.component('TextCellViz', TextCellViz);
    app.component('TablePlayground', TablePlayground);
    app.component('GlossaryList', GlossaryList);
    app.component('InstallInstructions', InstallInstructions);
  },
};
