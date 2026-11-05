# `programs.materialcraft` for NixOS and home-manager.
#
# The option set is shared; `kind` selects only the behaviour the target module system can express:
# home-manager installs the package, the MIME association and the palette variable per user, NixOS
# does the same for the whole system.
#
# There is deliberately no `settings` option. MaterialCraft keeps its state in eframe's RON store
# (`app.ron` under `$XDG_DATA_HOME/materialcraft`), not in a JSON preferences file, and this branch
# does not add a settings overlay. A follow-up that introduces a JSON preferences file can add one.
#
# `paletteFile` is exported as `CRAFT_PALETTE_FILE` for the shared palette loader. It is inert
# until the theming branch lands.
{ kind }:
{
  config,
  lib,
  pkgs,
  # The package of this flake; `flake.nix` passes it through `_module.args`, so importing the
  # module directly needs no overlay.
  materialcraftPackage ? pkgs.materialcraft,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.materialcraft;

  # The same list as `packaging/linux/ai.storyteller.materialcraft.desktop` (`MimeType=`).
  mimeTypes = [ "application/x-materialcraft" ];

  desktopFile = "ai.storyteller.materialcraft.desktop";

  associations = lib.genAttrs mimeTypes (_: [ desktopFile ]);
in
{
  options.programs.materialcraft = {
    enable = mkEnableOption "MaterialCraft";

    package = mkOption {
      type = types.package;
      default = materialcraftPackage;
      defaultText = lib.literalMD "the `materialcraft` package of this flake";
      description = "The MaterialCraft package to install.";
    };

    setAsDefault = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open `.mcraft` packages with MaterialCraft by default (the MIME types of
        `packaging/linux/ai.storyteller.materialcraft.desktop`).
      '';
    };

    paletteFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional shared palette file, exported as `CRAFT_PALETTE_FILE`. Inert until theming support
        lands.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable (
      if kind == "nixos" then
        {
          environment.systemPackages = [ cfg.package ];
          environment.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          xdg.mime.defaultApplications = mkIf cfg.setAsDefault associations;
        }
      else
        {
          home.packages = [ cfg.package ];
          home.sessionVariables = mkIf (cfg.paletteFile != null) {
            CRAFT_PALETTE_FILE = toString cfg.paletteFile;
          };
          xdg.mimeApps = mkIf cfg.setAsDefault {
            enable = true;
            defaultApplications = associations;
            # Associated even when another application stays the default.
            associations.added = associations;
          };
        }
    ))
  ];
}
