# Host-built E5 and E6 fixtures. No output contacts a device. Build with --impure:
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
  # Experimental E6 source only: persist the native PRoot route through the
  # first activation too, not just in the bootstrap's initial login script.
  nativeSource = pkgs.applyPatches {
    name = "nix-on-droid-native-proot-source";
    src = sparkles.inputs.nix-on-droid.outPath;
    patches = [ ./native-proot.patch ];
  };
  nativeBootstrap =
    (import "${nativeSource}/pkgs" {
      nixpkgs = sparkles.inputs.nix-on-droid.inputs.nixpkgs-for-bootstrap;
      system = "aarch64-linux";
      _nativeSystem = host;
      androidAppId = appId;
      nixpkgsChannelURL = "https://github.com/NixOS/nixpkgs/archive/49ee0e94463abada1de470c9c07bfc12b36dcf40.tar.gz";
      nixOnDroidChannelURL = "http://127.0.0.1:18314/nix-on-droid-native-proot.tar.gz";
    }).customPkgs;
  nativeLibs = {
    "libproot.so" = "${proot}/bin/proot-static";
    "libproot-loader.so" = "${loader}/libexec/proot-loader";
  };
in
{
  inherit
    proot
    loader
    hello
    nativeSource
    ;
  bootstrapZip = nativeBootstrap.bootstrapZip;
  sourceTarball =
    pkgs.runCommand "nix-on-droid-native-proot.tar.gz"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        tar -C ${nativeSource} --sort=name --owner=0 --group=0 --numeric-owner \
          --mtime=@1 --transform 'flags=r;s,^,nix-on-droid/,' -czf $out .
      '';
  bootstrapApk = sparkles.legacyPackages.${host}.mkTerminalApk {
    inherit appId;
    pname = "terminal-t36-bootstrap";
    label = "terminal target 36 Nix probe";
    targetSdk = 36;
    session = {
      mode = "bootstrap-shell";
      amSocket = "/data/data/${appId}/files/apps/termux-am/am.sock";
    };
    bootstraps.aarch64 = "${nativeBootstrap.bootstrapZip}/bootstrap-aarch64.zip";
    extraNativeLibs."arm64-v8a" = nativeLibs;
  };
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
    extraNativeLibs."arm64-v8a" = nativeLibs;
  };
}
