# Slim repack of the upstream libghostty-vt for the dev shell. The flake's
# `.dev` output embeds zig + zig-package-cache store paths in the static
# archive's debug info (a 1.5 GiB closure for a 14 MiB output), while all we
# consume is the prebuilt shared library and the C headers: copy exactly
# those, plus a path-rewritten pkg-config file, into one self-contained
# output, leaving the static archive (and its dirty references) behind.
{ ... }:
{
  perSystem =
    { inputs', pkgs, ... }:
    let
      vt = inputs'.ghostty.packages.libghostty-vt;
    in
    {
      packages.libghostty-vt =
        pkgs.runCommand "libghostty-vt-${vt.version}"
          {
            meta = {
              description = "Ghostty VT library — shared library + C headers only (no zig closure)";
              inherit (vt.meta) platforms;
            };
          }
          ''
            mkdir -p $out/lib/pkgconfig
            cp -a ${vt}/lib/. $out/lib/
            cp -r ${vt.dev}/include $out/include
            substitute ${vt.dev}/share/pkgconfig/libghostty-vt.pc \
              $out/lib/pkgconfig/libghostty-vt.pc \
              --replace-fail ${vt.dev} $out \
              --replace-fail ${vt} $out
          '';
    };
}
