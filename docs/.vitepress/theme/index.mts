import DefaultTheme from 'vitepress/theme-without-fonts';
import type { EnhanceAppContext } from 'vitepress';
import Layout from './Layout.vue';
import TextCellViz from './components/TextCellViz.vue';
import TablePlayground from './components/TablePlayground.vue';
import InstallInstructions from './InstallInstructions.vue';
// Dockview stylesheet powers the drawTable playground's dockable panels. Importing
// it here (the theme entry) is SSR-safe — it is plain CSS, extracted by Vite — and
// loads it once site-wide. The dockview-vue *component* is client-only and is
// dynamically imported inside TablePlayground.vue instead.
import 'dockview-vue/dist/styles/dockview.css';
import './custom.css';

export default {
  ...DefaultTheme,
  Layout,
  enhanceApp({ app }: EnhanceAppContext) {
    app.component('TextCellViz', TextCellViz);
    app.component('TablePlayground', TablePlayground);
    app.component('InstallInstructions', InstallInstructions);
  },
};
