// @sparkles-pkgs/wired: sparkles:wired as WebAssembly, for Node.js and
// browsers (docs/specs/wired/wasm, WW13). One module, `spk-wired.wasm`, the
// documentation site's playground module, answers every call through its one
// export, `spk_wired_run`: a JSON request in, a JSON response out.
import { ConsoleStdout, File, OpenFile, WASI } from '@bjorn3/browser_wasi_shim';

const defaultModule = new URL('./spk-wired.wasm', import.meta.url);

// The module's bytes: given, from a Response, or fetched from a URL (read
// from disk for a file: URL, which fetch does not serve in Node.js).
async function bytesOf(source) {
  if (source instanceof ArrayBuffer || ArrayBuffer.isView(source))
    return source;
  if (typeof Response !== 'undefined' && source instanceof Response)
    return new Uint8Array(await source.arrayBuffer());
  const url =
    source === undefined ? defaultModule : new URL(source, import.meta.url);
  if (url.protocol === 'file:') {
    const { readFile } = await import('node:fs/promises');
    return readFile(url);
  }
  const response = await fetch(url);
  if (!response.ok) throw new Error(`cannot fetch ${url}: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

/**
 * Instantiates the module and returns its operations. `source` is the module
 * itself (bytes, a Response, or a URL); by default the `spk-wired.wasm` this
 * package ships. Each call returns a separate instance.
 */
export async function load(source) {
  const wasi = new WASI(
    [],
    [],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered(line => console.log(line)),
      ConsoleStdout.lineBuffered(line => console.error(line)),
    ],
    { debug: false },
  );
  const { instance } = await WebAssembly.instantiate(await bytesOf(source), {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  // A reactor: `_initialize` starts druntime once, before any call.
  wasi.initialize(instance);
  return new Wired(instance.exports);
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The module's operations; see `load`. */
export class Wired {
  #exports;

  constructor(exports) {
    this.#exports = exports;
  }

  /** The largest request, in UTF-8 bytes, the module's buffer holds. */
  get capacity() {
    return Math.floor(this.#exports.spk_buf_cap() / 2);
  }

  #run(request) {
    const x = this.#exports;
    const bytes = encoder.encode(JSON.stringify(request));
    const base = x.spk_buf_ptr();
    const half = this.capacity;
    if (bytes.length > half)
      throw new RangeError(
        `the request is ${bytes.length} bytes; the module holds ${half}`,
      );
    new Uint8Array(x.memory.buffer).set(bytes, base);
    const n = x.spk_wired_run(base, bytes.length, base + half, half);
    if (n < 0)
      throw new RangeError('the response does not fit in the module’s buffer');
    const response = JSON.parse(
      decoder.decode(new Uint8Array(x.memory.buffer, base + half, n)),
    );
    if (response.fault !== undefined) throw new TypeError(response.fault);
    return response;
  }

  /** The document `text` parses to: `{ tree }`, or `{ error }`. */
  parse(format, text, name) {
    return this.#run({ op: 'parse', format, text, name });
  }

  /** `text` written canonically: `{ text }`, or `{ error }`. */
  format(format, text, name) {
    return this.#run({ op: 'format', format, text, name });
  }

  /**
   * `text` decoded as a dub recipe: `{ recipe }`, or `{ error }`. `name`
   * chooses the form, as dub's file names do: `….json` is JSON, `….d` a
   * single-file package's embedded recipe, anything else SDL.
   */
  recipe(text, name = 'dub.sdl') {
    return this.#run({
      op: 'recipe',
      format: name.endsWith('.json') ? 'json' : 'sdl',
      text,
      name,
    });
  }
}
