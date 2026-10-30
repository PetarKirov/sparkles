// The site's one host for Sparkles' WebAssembly modules (docs/specs/toolchain/
// wasm-modules.md, TCM7). Every component loads its module here and never
// instantiates one or stubs WASI imports itself.
//
// The WASI preview 1 imports come from @bjorn3/browser_wasi_shim: a real clock
// (`clock_time_get` reads `performance.now()` and `Date`), standard output and
// error forwarded line by line to the console, empty arguments and environment.
// A module is a reactor: `_initialize` starts druntime and runs its module
// constructors, once, before any other export is called.
//
// Only syntax that type stripping erases, so node runs it as it is: the
// agreement check (`ci --check-wasm-modules`, TCM9) loads the modules through
// this file too.
import { ConsoleStdout, File, OpenFile, WASI } from '@bjorn3/browser_wasi_shim';

/** The exports every Sparkles module has (TCM5), plus its own. */
export interface SparklesModule {
  memory: WebAssembly.Memory;
  spk_buf_ptr(): number;
  spk_buf_cap(): number;
  spk_segment(ptr: number, len: number, outPtr: number, outCap: number): number;
  [name: string]: any;
}

/**
 * Instantiates a module from its bytes or its HTTP response and initializes
 * it. Each call is a separate instance with its own memory.
 */
export async function instantiateModule(
  source: BufferSource | Response | PromiseLike<Response>,
): Promise<SparklesModule> {
  const wasi = new WASI(
    [],
    [],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((line: string) => console.log(line)),
      ConsoleStdout.lineBuffered((line: string) => console.error(line)),
    ],
    // The shim traces every call to the console unless told not to.
    { debug: false },
  );
  const imports = { wasi_snapshot_preview1: wasi.wasiImport };
  const { instance } =
    source instanceof ArrayBuffer || ArrayBuffer.isView(source)
      ? await WebAssembly.instantiate(source, imports)
      : await WebAssembly.instantiateStreaming(source, imports);
  wasi.initialize(instance as any);
  return instance.exports as unknown as SparklesModule;
}

const loaded = new Map<string, Promise<SparklesModule>>();

/** The module at `url`, fetched and initialized once per page. */
export function loadModule(url: string): Promise<SparklesModule> {
  let module = loaded.get(url);
  if (!module) {
    module = instantiateModule(fetch(url));
    loaded.set(url, module);
  }
  return module;
}
