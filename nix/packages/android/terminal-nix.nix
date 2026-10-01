# The terminal's Nix flavour: an app (`dev.petar_kirov.sparkles.terminal.nix`)
# that installs nix-on-droid's bootstrap on first start and runs its `login`.
# See docs/apps/terminal/android.md.
#
#   terminal-nix-apk                debug-signed; downloads the bootstrap
#   terminal-nix-apk-offline        both ABIs' bootstraps inside   (--impure)
#   terminal-nix-apk-unsigned       the release build, signed outside Nix
#   terminal-nix-bootstrap-<arch>   the bootstrap zip alone        (--impure)
#
# The bootstrap comes from the `nix-on-droid` input's
# `lib.bootstrapPackages`: every path in it is the app's data dir, so it is
# built for this app's id. Its first boot fetches nix-on-droid from the
# branch below, which has `build.androidAppId`, until a release branch does.
#
# `legacyPackages`, so `nix flake check` and CI never evaluate them: each
# fetches nix-on-droid and its nixpkgs, and a bootstrap needs `--impure` (it
# reads `builtins.storePath`).
{ inputs, lib, ... }:
let
  # Whether this system can build Android at all (./host.nix).
  androidHost = import ./host.nix { inherit inputs; };

  appId = "dev.petar_kirov.sparkles.terminal.nix";
  # Where the app's `am` server listens. Not Termux's layout
  # (`files/apps/<id>/termux-am/am.sock`): with this id that is 115 bytes,
  # over the 107 a Unix socket path can have.
  amSocket = "/data/data/${appId}/files/apps/termux-am/am.sock";
in
{
  perSystem =
    { config, system, ... }:
    let
      # The bootstrap is device content — a Linux userland for the device's
      # CPU — so a macOS host takes the x86_64-linux build of it.
      bootstrapPackages =
        arch:
        inputs.nix-on-droid.lib.bootstrapPackages {
          system = if lib.hasSuffix "-linux" system then system else "x86_64-linux";
          inherit arch;
          androidAppId = appId;
          nixOnDroidChannelURL = "https://github.com/PetarKirov/nix-on-droid/archive/feat/android-app-id.tar.gz";
          nixOnDroidFlakeURL = "github:PetarKirov/nix-on-droid/feat/android-app-id";
          # Every `android-integration` tool the app serves (its `am` server,
          # apps/terminal/src/am_server.d), on from first boot, and where that
          # server listens. Not `unsupported`: Termux's untested leftovers.
          initialSettings =
            lib.genAttrs (map (tool: "android-integration.${tool}.enable") [
              "am"
              "termux-open"
              "termux-open-url"
              "xdg-open"
              "termux-setup-storage"
              "termux-reload-settings"
              "termux-wake-lock"
              "termux-wake-unlock"
            ]) (_: true)
            // {
              "android-integration.am.socketPath" = amSocket;
            };
        };
      bootstrapZip = arch: "${(bootstrapPackages arch).bootstrapZip}/bootstrap-${arch}.zip";

      inherit (config.legacyPackages) mkTerminalApk;
      common = {
        inherit appId;
        label = "sparkles:terminal";
        pname = "sparkles-terminal-nix";
        iconSvg = ../../../apps/terminal/android/icon/ic_launcher_nix.svg;
        session = {
          mode = "bootstrap";
          bootstrapUrl = "https://nix-on-droid.unboiled.info/bootstrap-sparkles";
          inherit amSocket;
        };
      };
    in
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages = {
        terminal-nix-apk = mkTerminalApk common;
        terminal-nix-apk-offline = mkTerminalApk (
          common
          // {
            pname = "sparkles-terminal-nix-offline";
            bootstraps = {
              aarch64 = bootstrapZip "aarch64";
              x86_64 = bootstrapZip "x86_64";
            };
          }
        );
        terminal-nix-apk-unsigned = mkTerminalApk (
          common
          // {
            debug = false;
            sign = false;
          }
        );
        terminal-nix-bootstrap-aarch64 = (bootstrapPackages "aarch64").bootstrapZip;
        terminal-nix-bootstrap-x86_64 = (bootstrapPackages "x86_64").bootstrapZip;
      };
    };
}
