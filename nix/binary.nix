# The pre-built release tarball recorded in `binary-url.json`, patched to run on NixOS.
#
# The tarball is an FHS tree (`bin/`, `share/`) built on Ubuntu 22.04 upstream. `autoPatchelfHook`
# rewrites the ELF interpreter and RUNPATH, and `runtimeDependencies` covers the libraries the
# apps load with `dlopen` after startup, which autoPatchelf cannot see.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  alsa-lib,
  dbus,
  libGL,
  vulkan-loader,
  wayland,
  libxkbcommon,
  libx11,
  libxcb,
  libxcursor,
  libxi,
  libxrandr,
  name,
  info,
}:

let
  system = stdenv.hostPlatform.system;
  appEnv = lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name);
in
assert lib.assertMsg (
  info.system == system
) "${name}: binary-url.json records a ${info.system} binary, not ${system}";
stdenv.mkDerivation {
  pname = name;
  inherit (info) version;

  src = fetchurl {
    inherit (info) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    alsa-lib
  ];
  runtimeDependencies = [
    dbus.lib
    libGL
    vulkan-loader
    wayland
    libxkbcommon
    libx11
    libxcb
    libxcursor
    libxi
    libxrandr
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r bin share $out/
    runHook postInstall
  '';

  # Some apps pre-check their graphics libraries with `ldconfig -p`, which cannot see the RUNPATH,
  # and refuse to start; the libraries load fine.
  postFixup = ''
    wrapProgram $out/bin/${name} --set-default ${appEnv}_SKIP_LIB_CHECK 1
  '';

  meta = {
    description = "${info.repo} pre-built Linux binary (${info.tag})";
    homepage = "https://github.com/${info.repo}";
    license = with lib.licenses; [
      mit
      asl20
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = name;
    platforms = [ system ];
  };
}
