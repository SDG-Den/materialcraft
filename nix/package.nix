# MaterialCraft — the desktop app (`materialcraft`) and the headless CLI (`materialcraft-cli`), built
# from this repository:
#
#   nix build          # → ./result/bin/materialcraft, ./result/bin/materialcraft-cli
#
# Kept in step with the release workflow (.github/workflows/release.yml) and packaging/:
#   * `Cargo.lock` drives the dependencies (`cargoLock`), so there is no vendorHash to bump. The
#     git sources (SDG-Den/craft-libs, the egui and winit forks) are fetched at the revision the
#     lock file pins;
#   * `vendor/egui-phosphor` is a path patch: it stays in the source and needs no hash;
#   * the desktop file, hicolor icons, MIME XML and AppStream metadata are the same files the
#     .deb/.rpm ship (packaging/linux/), so `apt` and NixOS users see one identical MaterialCraft;
#   * `doCheck` is off: the test suite needs a GPU for the render comparisons and corpora that are
#     not in the tree (`cargo xtask ci` is the gate). `pkgs.materialcraft.overrideAttrs { doCheck = true; }`
#     runs it.
#
# MaterialCraft embeds no fonts of its own; egui's default fonts are compiled in through the egui
# crates. There is deliberately no `craft-fonts` input.
#
# Everything in the product is pure Rust, so this needs no build system beyond cargo plus the
# libraries winit/wgpu/rfd `dlopen` at run time (see `runtimeLibs`).
#
# Desktop sessions: the window opens natively on Wayland (GNOME/Mutter, Hyprland and other
# wlroots-style compositors) and falls back to X11/XWayland. File dialogs go through
# xdg-desktop-portal, so the session needs a portal backend: GNOME ships one
# (`xdg-desktop-portal-gnome`); on Hyprland enable
#   xdg.portal = { enable = true; extraPortals = [ pkgs.xdg-desktop-portal-gtk ]; };
# next to `programs.hyprland.enable = true;`.
{
  lib,
  stdenv,
  craneLib,
  pkg-config,
  makeWrapper,
  # Windowing/GPU libraries: needed at build time by the crates that link them, at run time by the
  # ones that open them with dlopen() (see `runtimeLibs`), and by the dev shell (flake.nix).
  wayland,
  wayland-scanner,
  libxkbcommon,
  libx11,
  libxcb,
  libxcursor,
  libxi,
  libxrandr,
  vulkan-loader,
  libglvnd,
  # rfd reaches the xdg-desktop-portal file chooser through a portal client and winit may open the
  # session bus; the library is loaded at run time.
  dbus,
  # Validates the desktop file and the AppStream metadata we install (as CI does).
  desktop-file-utils,
  appstream,
  # Adds the driver search path (/run/opengl-driver/lib) to the binaries' RPATH so wgpu finds the
  # installed Vulkan driver on NixOS. Optional: harmless on nixpkgs without it.
  autoAddDriverRunpath ? null,
  # Release date for the AppStream metadata (YYYY-MM-DD); the flake derives it from its own commit.
  buildDate ? "1970-01-01",
}:

let
  root = ../.;

  # The version lives in exactly one place: `[workspace.package] version` in the root Cargo.toml.
  version = (builtins.fromTOML (builtins.readFile (root + "/Cargo.toml"))).workspace.package.version;

  isLinux = stdenv.hostPlatform.isLinux;

  # AppStream id: also the desktop file name, and the icon name in share/icons/hicolor.
  appId = "ai.storyteller.materialcraft";

  # Libraries the binaries open at run time with dlopen(): nothing links them, so no RPATH points at
  # them. winit loads libwayland-client, libxkbcommon(-x11) and the X11 libraries; wgpu loads the
  # Vulkan loader or libEGL (libglvnd). NixOS patches the loader to find the drivers in
  # /run/opengl-driver. The wrapper below points LD_LIBRARY_PATH here.
  runtimeLibs = lib.optionals isLinux [
    libxkbcommon
    wayland
    libx11
    libxcb
    libxcursor
    libxi
    libxrandr
    vulkan-loader
    libglvnd
    dbus
  ];

  # The two native binaries. The wasm app (apps/materialcraft-web) is built by `cargo xtask wasm`,
  # not here.
  binaries = [
    "materialcraft"
    "materialcraft-cli"
  ];

in
let
  commonArgs = {
    pname = "materialcraft";
    inherit version;

    src = lib.cleanSourceWith {
      src = lib.cleanSource root;
      # The Nix files are not part of the build: editing them must not rebuild any Rust. `vendor/` is
      # kept: `egui-phosphor` is patched as a path dependency.
      filter =
        path: _type:
        !(builtins.elem (baseNameOf path) [
          "flake.nix"
          "flake.lock"
          "nix"
        ]);
    };

    # The git dependencies are pinned by revision in Cargo.lock.
    cargoLock = root + "/Cargo.lock";

    strictDeps = true;

    nativeBuildInputs = [
      pkg-config
    ]
    ++ lib.optionals isLinux [
      makeWrapper
      wayland-scanner
      desktop-file-utils
      appstream
    ]
    ++ lib.optionals (isLinux && autoAddDriverRunpath != null) [ autoAddDriverRunpath ];

    buildInputs = lib.optionals isLinux [
      wayland
      libxkbcommon
      libx11
      libxcb
      libxcursor
      libxi
      libxrandr
    ];
  };

  # Both binaries, as the .deb/.rpm install them (`packaging/linux/package.sh`).
  binaryArgs = "-p materialcraft -p materialcraft-cli";

  cargoArtifacts = craneLib.buildDepsOnly (
    commonArgs
    // {
      doCheck = false;
      cargoBuildExtraArgs = binaryArgs;
    }
  );
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts binaryArgs;

    cargoBuildExtraArgs = binaryArgs;

    # Tests need a GPU for the render comparisons and corpora that are not in the tree; the sandbox
    # has neither. `cargo xtask ci` is the gate; override to run them anyway.
    doCheck = false;

    postInstall = ''
      # Desktop integration: byte-for-byte the files the .deb/.rpm/.AppImage install.
      install -Dm644 packaging/linux/${appId}.desktop $out/share/applications/${appId}.desktop
      install -Dm644 packaging/linux/${appId}.mime.xml $out/share/mime/packages/${appId}.xml
      install -d $out/share/icons
      cp -r assets/app-icon/hicolor $out/share/icons/
      install -d $out/share/metainfo
      substitute packaging/linux/${appId}.metainfo.xml.in \
        $out/share/metainfo/${appId}.metainfo.xml \
        --subst-var-by VERSION ${version} \
        --subst-var-by DATE ${buildDate}

      # Licences for everything embedded in the binaries and for the bundled icon.
      doc=$out/share/doc/materialcraft
      for f in README.md LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md; do
        if [ -f "$f" ]; then install -Dm644 "$f" "$doc/$(basename "$f")"; fi
      done
      if [ -f assets/app-icon/LICENSE.txt ]; then
        install -Dm644 assets/app-icon/LICENSE.txt "$doc/app-icon-LICENSE.txt"
      fi
    ''
    + lib.optionalString isLinux ''
      desktop-file-validate $out/share/applications/${appId}.desktop
      XDG_CACHE_HOME=$TMPDIR/.cache appstreamcli validate --no-net \
        $out/share/metainfo/${appId}.metainfo.xml

      # makeWrapper keeps the binaries working when the libs above are only dlopen'd.
      for bin in ${lib.concatStringsSep " " (map (b: "$out/bin/" + b) binaries)}; do
        wrapProgram "$bin" --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}"
      done
    '';

    passthru = {
      # Shared with the dev shell so `cargo run` inside `nix develop` finds the same dlopen'd libs.
      inherit runtimeLibs;
    };

    meta = {
      description = "Node-based procedural material designer";
      longDescription = ''
        MaterialCraft is an open-source, native node-based material designer: build tileable PBR
        materials from noises, patterns and filters in a node graph, preview them live in 2D and 3D,
        and export the texture maps for any engine. It ships with materialcraft-cli, a headless
        command runner and MCP server for AI agents.
      '';
      homepage = "https://getartcraft.com/apps/materialcraft";
      license = with lib.licenses; [
        mit
        asl20
      ];
      sourceProvenance = with lib.sourceTypes; [ fromSource ];
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
      # `nix run` and the desktop entry both start the GUI.
      mainProgram = "materialcraft";
    };
  }
)
