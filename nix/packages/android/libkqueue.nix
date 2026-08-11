# mheily/libkqueue cross-built for Android, one static archive per ABI,
# linked into libhue.so. The app seccomp policy denies io_uring_setup and
# the library has no epoll fallback (SPEC §3.4), so the Android triple
# selects the kqueue PEER backend over this epoll shim — the same pair
# Linux CI exercises via `EventHorizonLibkqueue` (fiber-echo `-c libkqueue`
# + nixpkgs' host `pkgs.libkqueue`; no parallel host package here).
#
# `src = pkgs.libkqueue.src` pins the same version the host shell links.
# Needs CMake (generated headers); cross-built with the NDK toolchain. The
# D side has its own extern(C) bindings, so only the archive is consumed.
{ lib, ... }:
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

      libkqueue-android = pkgs.stdenv.mkDerivation {
        pname = "libkqueue-android";
        version = pkgs.libkqueue.version;
        src = pkgs.libkqueue.src;

        nativeBuildInputs = [ pkgs.cmake ];
        dontUseCmakeConfigure = true; # per-ABI configure below

        # Two Android-isms:
        # - The NDK toolchain file sets CMAKE_SYSTEM_NAME=Android, which
        #   libkqueue's OS dispatch does not recognize ("unsupported host
        #   os"). Android IS its Linux platform (epoll/eventfd/signalfd/
        #   timerfd all present in bionic), so widen the match.
        # - bionic has NO pthread cancellation (pthread_setcancelstate /
        #   pthread_testcancel / PTHREAD_CANCEL_*), which libkqueue uses to
        #   make its kevent wait a cancellation point. Stub them to no-ops:
        #   sound for this consumer, which never pthread_cancels a thread
        #   parked in kevent (fibers unwind via in-loop cancellation, not
        #   thread cancellation).
        postPatch = ''
          substituteInPlace CMakeLists.txt \
            --replace-fail 'elseif(CMAKE_SYSTEM_NAME STREQUAL Linux)' \
              'elseif(CMAKE_SYSTEM_NAME MATCHES "^(Linux|Android)$")'

          {
            echo ""
            echo "/* Android/bionic: no pthread cancellation; stub the"
            echo " * cancellation-point plumbing (libkqueue.nix). */"
            echo "#ifdef __ANDROID__"
            echo "#ifndef PTHREAD_CANCEL_DISABLE"
            echo "#define PTHREAD_CANCEL_DISABLE 0"
            echo "#define PTHREAD_CANCEL_ENABLE 1"
            echo "#define pthread_setcancelstate(state, oldstate) (0)"
            echo "#define pthread_testcancel() ((void) 0)"
            echo "/* The monitor thread SELF-exits when the last kqueue"
            echo " * closes (kq_cnt == 0 breaks its loop); pthread_cancel is"
            echo " * the belt-and-braces path for teardown orders bionic"
            echo " * cannot express. A no-op leaves the thread to the"
            echo " * process teardown, which is how Android ends apps"
            echo " * anyway. */"
            echo "#define pthread_cancel(t) (0)"
            echo "#define PTHREAD_CANCELED ((void *) -1)"
            echo "#endif"
            echo "#endif"
          } >> src/common/private.h
        '';

        buildPhase = ''
          runHook preBuild

          # ANDROID_PLATFORM is 23, not minSdk (21): bionic hides sigwaitinfo
          # below API 23 (__INTRODUCED_IN), and libkqueue's monitor thread
          # waits on it. The practical floor moves to Android 6.0 — already
          # implied by the 16 KB-page targetSdk-35 posture (pageAlignFlags).
          ${lib.concatMapStrings (t: ''
            cmake -S . -B build-${t.abi} \
              -DCMAKE_TOOLCHAIN_FILE=${ndk.ndkRoot}/build/cmake/android.toolchain.cmake \
              -DANDROID_ABI=${t.abi} \
              -DANDROID_PLATFORM=android-23 \
              -DCMAKE_BUILD_TYPE=Release \
              -DSTATIC_KQUEUE=ON \
              -DENABLE_TESTING=OFF
            cmake --build build-${t.abi} -j$NIX_BUILD_CORES
          '') (lib.attrValues ndk.targets)}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          ${lib.concatMapStrings (t: ''
            install -Dm644 build-${t.abi}/libkqueue.a $out/lib/${t.abi}/libkqueue.a
          '') (lib.attrValues ndk.targets)}
          runHook postInstall
        '';

        meta = {
          description = "libkqueue (kqueue-over-epoll shim) cross-built for Android, per ABI";
          homepage = "https://github.com/mheily/libkqueue";
          license = lib.licenses.bsd2;
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.libkqueue-android = libkqueue-android;
    };
}
