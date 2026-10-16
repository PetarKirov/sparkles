# Host-built E5 fixtures. No output contacts a device. Build with --impure:
# nix build --file docs/research/android-dev-env/device-validation/current-target.nix apk
{
  sparkles ? builtins.getFlake (toString ../../../..),
}:
let
  host = "x86_64-linux";
  appId = "dev.petar_kirov.sparkles.terminal.t36";
  pkgs = sparkles.inputs.nixpkgs.legacyPackages.${host};
  bootstrap = sparkles.inputs.nix-on-droid.lib.bootstrapPackages {
    system = host;
    arch = "aarch64";
    androidAppId = appId;
  };
  proot = bootstrap.prootTermux;
  # The normal package embeds its loader but does not install it separately.
  # Build that same revision's freestanding loader with the existing NDK,
  # without rebuilding the older bootstrap cross-toolchain.
  loader = pkgs.stdenvNoCC.mkDerivation {
    pname = "android-proot-loader";
    inherit (proot) version src;
    nativeBuildInputs = [ pkgs.gnumake ];
    dontConfigure = true;
    dontStrip = true;
    buildPhase = ''
      make -C src loader/loader \
        CC=${sparkles.legacyPackages.${host}.androidNdk.targets."arm64-v8a".cc} \
        CFLAGS='-O2 -fno-stack-protector'
    '';
    installPhase = ''
      install -Dm755 src/loader/loader $out/libexec/proot-loader
    '';
  };
  hello =
    sparkles.inputs.nix-on-droid.inputs.nixpkgs-for-bootstrap.legacyPackages.aarch64-linux.hello;
  closure = pkgs.closureInfo { rootPaths = [ hello ]; };
in
{
  inherit proot loader hello;
  helloPath = pkgs.writeText "hello-path" "${hello}/bin/hello\n";
  glibcClosure =
    pkgs.runCommand "android-exec-glibc-closure.tar"
      {
        nativeBuildInputs = [ pkgs.gnutar ];
      }
      ''
        # Toybox tar applies directory modes immediately. Nix's read-only store
        # modes would prevent an unprivileged app from creating their children.
        tar --format=gnu --mode=u+w -cf $out --files-from ${closure}/store-paths
      '';
  apk = sparkles.legacyPackages.${host}.mkTerminalApk {
    inherit appId;
    pname = "terminal-t36-proot";
    label = "terminal target 36 PRoot probe";
    targetSdk = 36;
    extraNativeLibs."arm64-v8a" = {
      "libproot.so" = "${proot}/bin/proot-static";
      "libproot-loader.so" = "${loader}/libexec/proot-loader";
    };
  };
}
