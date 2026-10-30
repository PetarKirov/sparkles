# LDC's druntime and Phobos for x86_64-pc-windows-msvc, cross-built by
# `ldc-build-runtime` from the very source the host compiler was built from,
# so the runtime's ABI is always the compiler's (as dlang.nix does for WASI
# and Android). The C parts (druntime's `.c` files, Phobos' zlib) go through
# the fork's `clang-cl` against the xwin-splatted MSVC CRT + Windows SDK
# headers.
#
# Static libraries only: `win32-ldc2` links statically, and a shared runtime
# would need a full MSVC link of the DLLs here.
#
# The SDK is unfree, and so is this derivation's input closure: it is
# instantiated only by the Win32 shell (../shells/win32-cross.nix) and must
# never be pushed to a cache or pinned.
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  runCommand,
  runtimeShell,
  # The compiler: provides `ldc-build-runtime`, the `ldc2` that compiles the
  # runtime, and `.src`.
  ldc,
  # The raw clang of the LLVM `ldc` is built on: `clang`, `lld-link` and
  # `llvm-ar`.
  clang,
  # The xwin splat (`windows.sdk`): `crt/` and `sdk/` with headers and libs.
  winSdk,
}:
let
  target = "x86_64-pc-windows-msvc";

  # The LLVM install ships neither `clang-cl` nor `llvm-lib`, only the
  # drivers they name: `clang --driver-mode=cl` and `llvm-ar` (which picks
  # its `lib` mode from its name). CMake's MSVC-flavoured platform files want
  # `llvm-lib` as the archiver, though only its try-compile uses it: the
  # runtime archives through LDC. The Win32 shell reuses `clang-cl` for
  # ImportC.
  tools = runCommand "clang-cl-tools" { } ''
    mkdir -p $out/bin
    cat > $out/bin/clang-cl <<EOF
    #!${runtimeShell}
    exec ${clang}/bin/clang --driver-mode=cl "\$@"
    EOF
    chmod +x $out/bin/clang-cl
    for t in lld-link llvm-ar; do
      ln -s ${clang}/bin/$t $out/bin/$t
    done
    ln -s ${clang}/bin/llvm-ar $out/bin/llvm-lib
  '';

  cFlags = lib.concatMapStringsSep " " (dir: "/imsvc${winSdk}/${dir}") [
    "crt/include"
    "sdk/include/ucrt"
    "sdk/include/um"
    "sdk/include/shared"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "ldc-runtime-${target}";
  inherit (ldc) version src;

  nativeBuildInputs = [
    cmake
    ninja
  ];

  dontConfigure = true;
  # COFF archives: the host `strip` has nothing to do with them.
  dontStrip = true;

  buildPhase = ''
    runHook preBuild

    ${ldc}/bin/ldc-build-runtime --ninja \
      --ldc=${ldc}/bin/ldc2 \
      --ldcSrcDir="$PWD" \
      --buildDir="$PWD/build-${target}" \
      --dFlags="-mtriple=${target}" \
      "--targetSystem=Windows;MSVC" \
      CMAKE_SYSTEM_NAME=Windows \
      CMAKE_C_COMPILER=${tools}/bin/clang-cl \
      "CMAKE_C_FLAGS=--target=${target} ${cFlags}" \
      CMAKE_CXX_COMPILER=${tools}/bin/clang-cl \
      "CMAKE_CXX_FLAGS=--target=${target} ${cFlags}" \
      CMAKE_LINKER=${tools}/bin/lld-link \
      CMAKE_AR=${tools}/bin/llvm-lib \
      CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      BUILD_SHARED_LIBS=OFF

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 -t $out/lib build-${target}/lib/*.lib
    runHook postInstall
  '';

  passthru = {
    inherit target;
    clangCl = "${tools}/bin/clang-cl";
  };

  meta = {
    description = "LDC's druntime and Phobos for ${target}";
    homepage = "https://github.com/ldc-developers/ldc";
    license = with lib.licenses; [
      bsd3
      boost
    ];
    platforms = [ "x86_64-linux" ];
  };
}
