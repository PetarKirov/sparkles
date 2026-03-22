{ pkgs }:
let
  inherit (pkgs) lib;
  isDarwin = pkgs.stdenv.isDarwin;

  cleanLdcConfig = lib.pipe "${pkgs.ldc}/etc/ldc2.conf" [
    builtins.readFile
    (lib.splitString "\n")
    (lib.filter (line: !(lib.hasInfix "/lib/clang/" line && lib.hasInfix "/lib/darwin" line)))
    lib.concatLines
    (pkgs.writeText "ldc2-clean.conf")
  ];

  ldc =
    if isDarwin then
      pkgs.writeShellScriptBin "ldc2" ''
        exec ${pkgs.ldc}/bin/ldc2 -conf=${cleanLdcConfig} "$@"
      ''
    else
      pkgs.ldc;

  clangUnwrapped = pkgs.clangStdenv.cc.cc;
in
{
  inherit ldc;

  env = lib.optionalAttrs isDarwin {
    CC = "${clangUnwrapped}/bin/clang";
    CXX = "${clangUnwrapped}/bin/clang++";
    SDKROOT = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
    MACOSX_DEPLOYMENT_TARGET = "14.0";
  };

  # Caps open-file limit so D's std.process.fork() child doesn't overflow
  # when casting rlim_cur to int (phobos bug with unlimited NOFILE).
  nofileLimit = 131072;
}
