# Evaluates both module entry points with `enable = true` and checks what they configure.
#
# `lib.evalModules` plus stub declarations of the handful of NixOS/home-manager options the module
# touches: a full NixOS evaluation would need the whole nixpkgs module set, and the stubs keep the
# check to the module's own contract. A wrong option type, a missing option, or a behaviour that
# regresses fails evaluation, so `nix flake check` catches it.
{
  lib,
  pkgs,
  materialcraft,
}:

let
  inherit (lib) mkEnableOption mkOption types;

  palette = ../packaging/linux/ai.storyteller.materialcraft.desktop;

  desktopFile = "ai.storyteller.materialcraft.desktop";

  # Must match `packaging/linux/ai.storyteller.materialcraft.desktop`.
  mimeTypes = [ "application/x-materialcraft" ];

  expected = lib.genAttrs mimeTypes (_: [ desktopFile ]);

  nixosStub = _: {
    options = {
      environment.systemPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      environment.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.mime.defaultApplications = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
      };
    };
  };

  homeStub = _: {
    options = {
      home.packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      home.sessionVariables = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      xdg.mimeApps = mkOption {
        default = { };
        type = types.submodule {
          options = {
            enable = mkEnableOption "mimeApps";
            defaultApplications = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
            associations.added = mkOption {
              type = types.attrsOf (types.listOf types.str);
              default = { };
            };
          };
        };
      };
    };
  };

  evalModule =
    kind: setAsDefault: paletteFile:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        (import ./module.nix { inherit kind; })
        (if kind == "nixos" then nixosStub else homeStub)
        {
          programs.materialcraft = {
            enable = true;
            package = materialcraft;
            inherit setAsDefault paletteFile;
          };
        }
      ];
    };

  nixos = evalModule "nixos" true palette;
  nixosPlain = evalModule "nixos" false null;
  home = evalModule "home-manager" true palette;
  homePlain = evalModule "home-manager" false null;

  binaryStub = pkgs.runCommand "materialcraft-binary-stub" { } "touch $out";

  evalDefault =
    useBinary: binary:
    lib.evalModules {
      specialArgs = {
        inherit pkgs;
        materialcraftSourcePackage = materialcraft;
        materialcraftBinaryPackage = binary;
      };
      modules = [
        (import ./module.nix { kind = "nixos"; })
        nixosStub
        {
          programs.materialcraft = {
            enable = true;
            inherit useBinary;
          };
        }
      ];
    };

  nixosDefault = evalDefault true binaryStub;
  nixosNoBinary = evalDefault true null;
  nixosSourceChosen = evalDefault false binaryStub;

  assertions = [
    {
      what = "useBinary defaults to true";
      ok = nixosDefault.config.programs.materialcraft.useBinary;
    }
    {
      what = "the binary is the default package";
      ok = nixosDefault.config.environment.systemPackages == [ binaryStub ];
    }
    {
      what = "the source build is used without a binary";
      ok = nixosNoBinary.config.environment.systemPackages == [ materialcraft ];
    }
    {
      what = "useBinary = false selects the source build";
      ok = nixosSourceChosen.config.environment.systemPackages == [ materialcraft ];
    }
    {
      what = "nixos installs the package";
      ok = nixos.config.environment.systemPackages == [ materialcraft ];
    }
    {
      what = "nixos mime defaults";
      ok = nixos.config.xdg.mime.defaultApplications == expected;
    }
    {
      what = "nixos palette variable";
      ok = nixos.config.environment.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "nixos leaves palette unset without paletteFile";
      ok = !builtins.hasAttr "CRAFT_PALETTE_FILE" nixosPlain.config.environment.sessionVariables;
    }
    {
      what = "nixos mime defaults without setAsDefault";
      ok = nixosPlain.config.xdg.mime.defaultApplications == { };
    }
    {
      what = "module has no settings option";
      ok = !builtins.hasAttr "settings" nixos.options.programs.materialcraft;
    }
    {
      what = "home-manager installs the package";
      ok = home.config.home.packages == [ materialcraft ];
    }
    {
      what = "home-manager mime defaults";
      ok = home.config.xdg.mimeApps.defaultApplications == expected;
    }
    {
      what = "home-manager mime associations";
      ok = home.config.xdg.mimeApps.associations.added == expected;
    }
    {
      what = "home-manager palette variable";
      ok = home.config.home.sessionVariables.CRAFT_PALETTE_FILE == toString palette;
    }
    {
      what = "home-manager leaves mimeApps alone without setAsDefault";
      ok = homePlain.config.xdg.mimeApps.enable == false;
    }
  ];

  failed = map (a: a.what) (lib.filter (a: !a.ok) assertions);
in
assert lib.assertMsg (failed == [ ]) "materialcraft modules: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "materialcraft-module-check" { } ''
  touch $out
''
