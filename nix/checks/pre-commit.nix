{ lib, ... }:
{
  perSystem =
    { ... }:
    {
      pre-commit.settings.hooks.rustfmt.enable = lib.mkForce false;
    };
}
