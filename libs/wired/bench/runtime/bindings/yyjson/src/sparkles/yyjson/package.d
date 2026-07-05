/**
D bindings for [yyjson](https://github.com/ibireme/yyjson), imported through
ImportC. The header (and the `-lyyjson` link flag) resolve through the
`yyjson.pc` installed by the ISA-preset build in
`nix/packages/wired-bench-yyjson.nix`.
*/
module sparkles.yyjson;

public import sparkles.yyjson.yyjson_c;
