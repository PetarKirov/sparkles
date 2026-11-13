# The iroh bridge for Android (fileset explorer FXS9): the same
# `libsparkles_iroh_send.so` as `packages.sparkles-iroh-send`, built inside
# `sendme`'s source tree and lock, for each ABI the APKs ship, and linked by
# the NDK's clang.
#
#   legacyPackages.irohSendAndroid   lib/<abi>/libsparkles_iroh_send.so
#
# nixpkgs' rustc carries the standard library for the host alone, and a
# cross rustc would be built from source. Upstream's prebuilt toolchain has
# the Android standard libraries, so it is assembled here from its
# components, pinned by hash, at the version nixpkgs' rustc is.
{ inputs, lib, ... }:
let
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      ndk = config.legacyPackages.androidNdk;
      version = "1.99.0";
      component =
        name: sha256:
        pkgs.fetchurl {
          url = "https://static.rust-lang.org/dist/${name}.tar.xz";
          inherit sha256;
        };
      components = [
        (component "rustc-${version}-x86_64-unknown-linux-gnu" "1mabc34xqxwcpql7qlk8gap8s1yysraxmvagphmdyprll2i1n5vp")
        (component "cargo-${version}-x86_64-unknown-linux-gnu" "1kk8fn61i979s45hyr4g0firxnv0rav2i5yd2iv0k4w0s8c4jryp")
        (component "rust-std-${version}-x86_64-unknown-linux-gnu" "0cwr2s8y10bbd2a2d9b4hpl0sh2d2xp5742fxasrc8dps3rdyn1y")
        (component "rust-std-${version}-aarch64-linux-android" "0qsii16n9k7qjxj5fcwz6yfwmlwajlcrf9yvq5d696cf2faia821")
        (component "rust-std-${version}-x86_64-linux-android" "0715p9yds7i1app00idf750gq650lfk6g9yy4452pn6d2dvh9jpa")
      ];
      # Upstream's toolchain, each component installed by its own script; the
      # host's binaries and libraries are patched for the store, the Android
      # standard libraries left as they are.
      toolchain = pkgs.stdenv.mkDerivation {
        pname = "rust-android-toolchain";
        inherit version;
        srcs = components;
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [
          pkgs.zlib
          pkgs.stdenv.cc.cc.lib
        ];
        dontUnpack = true;
        dontAutoPatchelf = true;
        installPhase = ''
          for c in $srcs; do
            mkdir -p work && tar -xJf "$c" -C work
            d=$(echo work/*/)
            bash "$d/install.sh" --prefix=$out --disable-ldconfig
            rm -rf work
          done
          rm -f $out/lib/rustlib/uninstall.sh
        '';
        # rustc's own libraries (libLLVM, librustc_driver) are beside it.
        postFixup = ''
          addAutoPatchelfSearchPath $out/lib
          autoPatchelf $out/bin $out/libexec $out/lib/*.so* $out/lib/rustlib/x86_64-unknown-linux-gnu
        '';
      };

      rustPlatform = pkgs.makeRustPlatform {
        rustc = toolchain;
        cargo = toolchain;
      };

      lock = (pkgs.callPackage ../../../libs/iroh-send/package.nix { }).lock;
      cargoDeps = rustPlatform.importCargoLock { lockFile = lock; };
      bridge = ../../../libs/iroh-send/rust;

      # Rust's spelling of each ABI's target.
      rustTarget = {
        "arm64-v8a" = "aarch64-linux-android";
        "x86_64" = "x86_64-linux-android";
      };
      envName = t: lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] t);
    in
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages.irohSendAndroid = pkgs.stdenv.mkDerivation (
        {
          pname = "sparkles-iroh-send-android";
          inherit (pkgs.sendme) version src;
          inherit cargoDeps;
          nativeBuildInputs = [
            rustPlatform.cargoSetupHook
            toolchain
          ];

          postPatch = ''
            cp ${bridge}/sparkles_iroh_send.rs ${bridge}/sparkles_iroh_receive.rs ${bridge}/iroh_collection.rs src/
            cat ${bridge}/targets.toml >> Cargo.toml
            cp ${lock} Cargo.lock
          '';

          # Every shipped library 16 KB-aligned (`pageAlignFlags`).
          RUSTFLAGS = "-C link-arg=${ndk.pageAlignFlags}";

          buildPhase = ''
            runHook preBuild
            ${lib.concatMapStrings (abi: ''
              cargo build --release --frozen --lib --target ${rustTarget.${abi}}
            '') (builtins.attrNames ndk.targets)}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            ${lib.concatMapStrings (abi: ''
              mkdir -p $out/lib/${abi}
              cp target/${rustTarget.${abi}}/release/libsparkles_iroh_send.so $out/lib/${abi}/
            '') (builtins.attrNames ndk.targets)}
            runHook postInstall
          '';
          dontStrip = true;
          dontPatchELF = true;
        }
        # Each target's linker, and the C compiler and archiver its crates'
        # build scripts use (`cc`): the NDK's.
        // lib.foldl' (
          acc: abi:
          let
            t = rustTarget.${abi};
            target = ndk.targets.${abi};
          in
          acc
          // {
            "CARGO_TARGET_${envName t}_LINKER" = target.cc;
            "CC_${builtins.replaceStrings [ "-" ] [ "_" ] t}" = target.cc;
            "CXX_${builtins.replaceStrings [ "-" ] [ "_" ] t}" = target.cxx;
            "AR_${builtins.replaceStrings [ "-" ] [ "_" ] t}" = ndk.ar;
          }
        ) { } (builtins.attrNames ndk.targets)
      );
    };
}
