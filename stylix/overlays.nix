{
  lib,
  pkgs,
  config,
  options,
  ...
}:
{
  options.stylix.overlays.enable = config.lib.stylix.mkEnableTarget "packages via overlays" true;

  imports = map (
    f:
    let
      file = import f;
      attrs =
        if builtins.isFunction file then
          file {
            inherit
              lib
              pkgs
              config
              options
              ;
          }
        else
          file;
    in
    {
      _file = f;
      options = attrs.options or { };
      config.nixpkgs.overlays = lib.mkIf config.stylix.overlays.enable [
        attrs.overlay
      ];
    }
  ) (import ./autoload.nix { inherit lib; } "overlay");
}
