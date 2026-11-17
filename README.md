# nix-wasm-modules

The dub recipe modules Nix evaluation fetches by hash (docs/specs/wired/wasm on the main branch, D2): `<rev>/spk-dub-manifest.wasm` is `dub-manifest-nix-wasm` built at `<rev>`. Append only: a pin names a commit of this branch, and rewriting it breaks that pin.
