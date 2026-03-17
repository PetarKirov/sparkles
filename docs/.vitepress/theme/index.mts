import DefaultTheme from "vitepress/theme";
import ApiIndexPage from "../components/api/ApiIndexPage.vue";
import ApiModulePage from "../components/api/ApiModulePage.vue";
import ApiSymbolPage from "../components/api/ApiSymbolPage.vue";
// import "./custom.css";

export default {
  ...DefaultTheme,
  enhanceApp({ app }) {
    app.component("ApiIndexPage", ApiIndexPage);
    app.component("ApiModulePage", ApiModulePage);
    app.component("ApiSymbolPage", ApiSymbolPage);
  },
};
