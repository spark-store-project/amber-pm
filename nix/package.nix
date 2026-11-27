args@{
  lib,
  stdenvNoCC,
  makeWrapper,
  aria2,
  bash,
  bubblewrap,
  bzip2,
  coreutils,
  curl,
  desktop-file-utils,
  dpkg,
  fakeroot,
  file,
  findutils,
  fuse-overlayfs,
  fuse3,
  gawk,
  getent,
  glib,
  gnugrep,
  gnupg,
  gnused,
  gnutar,
  gzip,
  libnotify,
  polkit,
  procps,
  shared-mime-info,
  sudo,
  systemd,
  util-linux,
  which,
  xdg-user-dirs,
  xdg-utils,
  xz,
  zenity,
  zstd,
  version ? "2.0.1",
  sourceRoot ? ../.,
  ...
}:

let
  # Keep src out of functionArgs: some nixpkgs releases expose an unrelated
  # pkgs.src alias that callPackage would otherwise inject automatically.
  src =
    args.src or (lib.cleanSourceWith {
      src = sourceRoot;
      filter =
        path: type:
        !(lib.elem (baseNameOf path) [
          ".git"
          "result"
        ]);
    });
  runtimePath = lib.makeBinPath [
    aria2
    bash
    bubblewrap
    bzip2
    coreutils
    curl
    desktop-file-utils
    dpkg
    fakeroot
    file
    findutils
    fuse-overlayfs
    fuse3
    gawk
    getent
    glib
    glib.dev
    gnugrep
    gnupg
    gnused
    gnutar
    gzip
    libnotify
    polkit
    procps
    shared-mime-info
    sudo
    systemd
    util-linux
    which
    xdg-user-dirs
    xdg-utils
    xz
    zenity
    zstd
  ];
in
stdenvNoCC.mkDerivation {
  pname = "amber-pm";
  inherit version src;
  patches = [
    ./runtime.patch
    ./state.patch
    ./host.patch
  ];
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  # Only host executables receive Nix interpreters. Scripts shipped for the
  # Debian base (including generated maintainer scripts) keep their shebangs.
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/usr" "$out/share/amber-pm"
    cp -a src/usr/. "$out/usr/"
    cp -a src/var/lib/apm/apm "$out/share/amber-pm/apm"
    body="$out/share/amber-pm/apm"
    install -m 0755 ${./spark-uri-compat.sh} "$out/usr/bin/amber-pm-debug"
    substituteInPlace "$out/usr/bin/amber-pm-debug" \
      --replace-fail '@APM_LIB_DIR@' "$out/usr/libexec/apm"

    substituteInPlace "$out/usr/libexec/apm/apm-main" \
      --replace-fail '@VERSION@' '${version}' \
      --replace-fail '/var/lib/apm/apm/files/ace-run' "$body/files/ace-run"
    substituteInPlace "$out/usr/bin/amber-pm-app-uninstaller" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$body/files/amber-ce-tools/bin-override/host-spawn" \
      --replace-fail '@systemd@' '${systemd}' \
      --replace-fail '@coreutils@' '${coreutils}' \
      --replace-fail '@bash@' '${bash}'
    substituteInPlace "$body/files/bin/ace-gxde-fixer" \
      --replace-fail 'pkexec "$0"' "pkexec \"$body/files/bin/ace-gxde-fixer\""

    # These are the only writable paths below the historical APM body. Keep
    # the paths used by Spark/old desktop files, but place their data in state.
    ln -s /var/lib/apm/apm-compat/ace-env "$body/files/ace-env"

    # NixOS has no writable /usr/share or /etc/xdg. Both existing trigger names
    # use the same idempotent integration implementation.
    cp ${./desktop-integration.sh} "$out/usr/bin/amber-pm-desktop-fix"
    substituteInPlace "$out/usr/bin/amber-pm-desktop-fix" \
      --replace-fail '@APM_LIB_DIR@' "$out/usr/libexec/apm"
    rm "$out/usr/bin/amber-pm-dstore-patch"
    ln -s amber-pm-desktop-fix "$out/usr/bin/amber-pm-dstore-patch"
    chmod +x "$out/usr/bin/amber-pm-desktop-fix"

    # Use Store targets for installed commands, retaining the historical
    # /var/lib/apm/apm paths for old callers.
    rm -f "$out/usr/bin/apm" "$out/usr/bin/amber-pm-configure-nvidia"
    ln -s "$body/files/bin/amber-ce-configure-nvidia" "$out/usr/bin/amber-pm-configure-nvidia"
    patchShebangs "$out/usr/bin" "$out/usr/libexec" \
      "$body/files/ace-run" "$body/files/ace-run-pkg" \
      "$body/files/bin/amber-ce-configure-nvidia" "$body/files/bin/ace-gxde-fixer" \
      "$body/files/feedback.sh" "$body/files/amber-ce-tools/bin-override"

    # Legacy direct invocations and sudo -E from the conversion tools cannot
    # depend on the interactive PATH. Prefer NixOS's privileged wrappers to
    # the non-setuid Store binaries.
    for prog in "$body/files/ace-run" "$body/files/ace-run-pkg" \
      "$body/files/bin/amber-ce-configure-nvidia" "$body/files/bin/ace-gxde-fixer"; do
      wrapProgram "$prog" --prefix PATH : "/run/wrappers/bin:$out/bin:${runtimePath}"
    done
    for prog in "$out"/usr/bin/*; do
      makeWrapper "$prog" "$out/bin/$(basename "$prog")" \
        --prefix PATH : "/run/wrappers/bin:$out/bin:${runtimePath}"
    done
    makeWrapper "$out/usr/libexec/apm/apm-main" "$out/bin/apm" \
      --prefix PATH : "/run/wrappers/bin:$out/bin:${runtimePath}"

    # Register through normal NixOS package mechanisms. Keep libexec and the
    # keyring together for apm_repo_keyring's existing relative fallback.
    cp -a "$out/usr/share"/. "$out/share/"
    substituteInPlace "$out/share/polkit-1/actions/store.spark-app.apm-uninstaller.policy" \
      --replace-fail '/usr/bin/amber-pm-app-uninstaller' "$out/usr/bin/amber-pm-app-uninstaller"
    # pkexec invokes the annotated script with a minimal PATH.
    wrapProgram "$out/usr/bin/amber-pm-app-uninstaller" \
      --prefix PATH : "/run/wrappers/bin:$out/bin:${runtimePath}"
    runHook postInstall
  '';

  meta = {
    description = "Package manager for applications in bubblewrap and FUSE overlay containers";
    homepage = "https://gitee.com/amber-ce/amber-pm/";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "apm";
  };
}
