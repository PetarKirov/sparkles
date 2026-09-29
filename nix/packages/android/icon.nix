# `legacyPackages.mkAndroidIcon` — a launcher icon resource tree, rasterized
# from ONE committed SVG (`packages.hue-icon`: apps/hue/android/icon/
# ic_launcher.svg; `packages.terminal-icon`: apps/terminal/android/icon/).
#
# Why generate instead of checking in five PNGs: one source of truth, and the
# repo keeps its no-binaries property — `.svg` is already in hue.nix's
# `repoTextExts` (so hue-apk-repo can display its own icon source) while `.png`
# is not, meaning checked-in rasters would be excluded from that bundle anyway.
#
# The output is deliberately split in two, because they go to different places:
#
#   $out/res           the resource tree `aapt2 compile` walks. It may contain
#                      ONLY recognized resource directories — aapt2 rejects an
#                      unknown top-level name — so nothing else can live here.
#   $out/icon-512.png  the F-Droid listing icon
#                      (metadata/<appid>/en-US/images/icon.png). Independent of
#                      the APK: the client shows this one, while the launcher
#                      shows the mipmaps. Both are needed; see FDR3.
{ inputs, lib, ... }:
let
  # Whether this system can build Android at all (./host.nix).
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (androidHost system).supported rec {
      # Any app's icon from its SVG — hue's and the terminal's are two calls.
      legacyPackages.mkAndroidIcon =
        { name, source }:
        let
          # Android's density buckets, as multiples of the 48 dp baseline
          # (mdpi = 1×). `fdroid update` maps the directory suffix back to a
          # density and resizes to `density * 48 / 160`, so shipping the whole
          # ladder means nothing downstream has to invent pixels.
          densities = {
            mdpi = 48;
            hdpi = 72;
            xhdpi = 96;
            xxhdpi = 144;
            xxxhdpi = 192;
          };

          # `--skip-system-fonts` is a determinism guard, not an optimization:
          # with it, a stray <text> element renders as nothing everywhere
          # instead of picking up whatever fonts the build host happens to
          # have. The SVG has none, and this keeps it that way.
          render = out: px: ''
            resvg --skip-system-fonts --width ${toString px} --height ${toString px} \
              ${source} ${out}
          '';
        in
        pkgs.runCommand name
          {
            nativeBuildInputs = [ pkgs.resvg ];
            meta = {
              description = "${name}: launcher mipmap resource tree + F-Droid listing icon";
              platforms = (androidHost system).platforms;
            };
          }
          ''
            ${lib.concatStrings (
              lib.mapAttrsToList (bucket: px: ''
                mkdir -p $out/res/mipmap-${bucket}
                ${render "$out/res/mipmap-${bucket}/ic_launcher.png" px}
              '') densities
            )}

            ${render "$out/icon-512.png" 512}

            # stdenv exports SOURCE_DATE_EPOCH; clamp so the mtimes aapt2 and
            # zip carry into the APK do not change on every rebuild.
            find $out -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
          '';

      packages.hue-icon = legacyPackages.mkAndroidIcon {
        name = "hue-icon";
        source = ../../../apps/hue/android/icon/ic_launcher.svg;
      };

      packages.terminal-icon = legacyPackages.mkAndroidIcon {
        name = "terminal-icon";
        source = ../../../apps/terminal/android/icon/ic_launcher.svg;
      };
    };
}
