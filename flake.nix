{
  description = "MaterialCraft — node-based procedural material designer, in pure Rust";

  inputs = {
    # MaterialCraft needs edition 2024 and rustc ≥ 1.95, so the flake tracks unstable. Consumers on a
    # release channel can retarget it: `inputs.materialcraft.inputs.nixpkgs.follows = "nixpkgs";`
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Splits the dependency build from the app build, so a source change does not recompile the
    # whole dependency graph.
    crane = {
      url = "github:ipetkov/crane";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The AppStream metadata carries a release date. The flake source's own commit date is
      # reproducible, unlike "now"; a tarball or dirty tree without one falls back to the epoch.
      buildDate =
        let
          d = self.lastModifiedDate or "";
        in
        if builtins.stringLength d >= 8 then
          "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
        else
          "1970-01-01";

      packageArgs = {
        inherit buildDate;
      };

      # Written by `.github/workflows/binary.yml`; absent until the first binary release.
      binaryInfo =
        if builtins.pathExists ./binary-url.json then
          builtins.fromJSON (builtins.readFile ./binary-url.json)
        else
          null;

      forAllSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (
        pkgs: system:
        let
          source = pkgs.callPackage ./nix/package.nix (packageArgs // { craneLib = crane.mkLib pkgs; });
          binary = pkgs.callPackage ./nix/binary.nix {
            name = "materialcraft";
            info = binaryInfo;
          };
          binaryAvailable = binaryInfo != null && binaryInfo.system == system;
        in
        {
          materialcraft-source = source;
          materialcraft = if binaryAvailable then binary else source;
          default = if binaryAvailable then binary else source;
        }
        // lib.optionalAttrs binaryAvailable {
          materialcraft-binary = binary;
        }
      );

      # `nixpkgs.overlays = [ inputs.materialcraft.overlays.default ]` → `pkgs.materialcraft` everywhere.
      overlays.default = final: _prev: {
        materialcraft = final.callPackage ./nix/package.nix (
          packageArgs // { craneLib = crane.mkLib final; }
        );
      };

      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = lib.getExe self.packages.${system}.materialcraft;
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system:
        let
          materialcraft = self.packages.${system}.materialcraft-source;
        in
        {
          default = pkgs.mkShell {
            # The package's own native inputs, so `cargo run` in the shell needs no extra setup.
            inputsFrom = [ materialcraft ];
            packages = with pkgs; [
              cargo
              rustc
              clippy
              rustfmt
              rust-analyzer
            ];
            # `cargo run` dlopens the Vulkan loader, libwayland and libxkbcommon like the packaged binary.
            LD_LIBRARY_PATH = lib.makeLibraryPath materialcraft.passthru.runtimeLibs;
            RUST_BACKTRACE = "1";
          };
        }
      );

      checks = forAllSystems (
        pkgs: system:
        let
          materialcraft = self.packages.${system}.materialcraft-source;
        in
        {
          materialcraft = materialcraft;

          # Both module entry points evaluate with `enable = true` (no full NixOS evaluation).
          modules = pkgs.callPackage ./nix/module-check.nix { inherit materialcraft; };

          # `nix fmt` formats the flake; this keeps it formatted.
          formatting =
            pkgs.runCommand "materialcraft-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; }
              ''
                nixfmt --check ${./flake.nix} ${./nix}
                touch $out
              '';
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);

      # Both modules take the package from this flake unless `programs.materialcraft.package` is set,
      # so `nixosModules.default`/`homeManagerModules.default` work without the overlay.
      nixosModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          imports = [ (import ./nix/module.nix { kind = "nixos"; }) ];
          _module.args = {
            materialcraftSourcePackage = self.packages.${system}.materialcraft-source;
            materialcraftBinaryPackage = self.packages.${system}.materialcraft-binary or null;
          };
        };

      homeManagerModules.default =
        { pkgs, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          imports = [ (import ./nix/module.nix { kind = "home-manager"; }) ];
          _module.args = {
            materialcraftSourcePackage = self.packages.${system}.materialcraft-source;
            materialcraftBinaryPackage = self.packages.${system}.materialcraft-binary or null;
          };
        };
    };
}
