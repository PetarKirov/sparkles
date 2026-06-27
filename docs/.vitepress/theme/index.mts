import DefaultTheme from 'vitepress/theme-without-fonts';
import type { EnhanceAppContext } from 'vitepress';
import Layout from './Layout.vue';
import TextCellViz from './components/TextCellViz.vue';
import InstallInstructions from './InstallInstructions.vue';
import './custom.css';

export default {
  ...DefaultTheme,
  Layout,
  enhanceApp({ app }: EnhanceAppContext) {
    app.component('TextCellViz', TextCellViz);
    app.component('InstallInstructions', InstallInstructions);
  },
};
