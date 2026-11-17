/** Where and why `text` failed to parse or decode. */
export interface WiredError {
  name: string;
  /** 1-based. */
  line: number;
  /** 1-based, in Unicode scalars. */
  column: number;
  /** The `SdlErrorCode` (or JSON parse error code) member's name. */
  code: string;
  message: string;
}

export type Format = 'json' | 'sdl';

/** An SDL value: its kind and its canonical SDL spelling. */
export interface SdlValue {
  kind: string;
  text: string;
}

/** An SDL tag, as `parse('sdl', …)` returns it. */
export interface SdlTag {
  name: string;
  line: number;
  values: SdlValue[];
  attributes: { name: string; value: SdlValue }[];
  children: SdlTag[];
}

export type Answer<K extends string, T> =
  ({ [P in K]: T } & { error?: undefined }) | { error: WiredError };

/** A dub recipe, its empty fields left out, named as sparkles:dub-manifest's D fields. */
export type Recipe = Record<string, unknown>;

export declare class Wired {
  /** The largest request, in UTF-8 bytes, the module's buffer holds. */
  readonly capacity: number;
  parse(format: 'sdl', text: string, name?: string): Answer<'tree', SdlTag[]>;
  parse(format: 'json', text: string, name?: string): Answer<'tree', unknown>;
  format(format: Format, text: string, name?: string): Answer<'text', string>;
  recipe(text: string, name?: string): Answer<'recipe', Recipe>;
}

/**
 * Instantiates the module: `source` is its bytes, a Response, or a URL; by
 * default the `spk-wired.wasm` this package ships.
 */
export declare function load(
  source?: BufferSource | Response | URL | string,
): Promise<Wired>;
