// Build-time loader for the glossary (docs/.vitepress/glossary.json).
//
// The JSON is the single source of truth; `ci --check-glossary` validates it
// with the D schema in libs/docs/src/sparkles/docs/glossary.d. This loader only
// renders each definition's inline Markdown with the site's own renderer, so
// code spans and links look exactly as they do in a page.
import fs from 'node:fs';
import {
  createMarkdownRenderer,
  defineLoader,
  type SiteConfig,
} from 'vitepress';

export interface GlossaryLink {
  text: string;
  link: string;
}

export interface GlossaryEntry {
  id: string;
  term: string;
  aliases?: string[];
  summary: string;
  definition: string;
  authority?: GlossaryLink[];
  owner: string;
  seeAlso?: string[];
}

export interface RenderedGlossaryEntry extends GlossaryEntry {
  definitionHtml: string;
}

declare const data: RenderedGlossaryEntry[];
export { data };

export default defineLoader({
  watch: ['../glossary.json'],
  async load(files: string[]): Promise<RenderedGlossaryEntry[]> {
    const entries: GlossaryEntry[] = JSON.parse(
      fs.readFileSync(files[0], 'utf8'),
    );
    const config = (globalThis as { VITEPRESS_CONFIG?: SiteConfig })
      .VITEPRESS_CONFIG;
    if (!config)
      throw new Error('glossary loader ran outside a VitePress build');
    const md = await createMarkdownRenderer(
      config.srcDir,
      config.markdown,
      config.site.base,
      config.logger,
    );
    return entries.map(e => ({
      ...e,
      definitionHtml: md.renderInline(e.definition, {}),
    }));
  },
});
