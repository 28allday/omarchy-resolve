#!/usr/bin/env bash
# Root phase of the install: everything that touches system paths.
#
# Invoked either as `sudo omarchy-resolve install --phase root` from a
# terminal, or as `pkexec omarchy-resolve install --phase root` from the shell
# plugin — one authentication for the whole run, which is the entire reason
# the phases are split. Nothing here may write to the user's home: under
# pkexec HOME is root's, so a stray ~/... write lands in /root and silently
# achieves nothing. User-home work lives in install-user.sh.

INSTALL_ZIP=""
FULL_UPGRADE=0
SETUP_ALOOP=1

install_root_usage() {
  cat >&2 <<'USAGE'
usage: omarchy-resolve install --phase root --zip <path> [options]
  --zip <path>       DaVinci Resolve Linux ZIP to install (required)
  --full-upgrade     run a full pacman -Syu first (default: -Sy only)
  --no-aloop         skip the snd-aloop kernel module setup
USAGE
}

# ---------------------------------------------------------------- dependencies
# Installed one at a time on purpose: pacman aborts the ENTIRE transaction if
# any single target is missing from the repos, which would silently leave every
# other dependency uninstalled. That is exactly what happened when Arch dropped
# gtk2 — one dead target took the whole install down with it.
root_install_packages() {
  step deps "Installing dependencies…"
  if [[ "${FULL_UPGRADE}" == "1" ]]; then
    log "  Full system upgrade requested"
    run pacman -Syu --noconfirm || step_warn "System upgrade reported errors"
  else
    run pacman -Sy --noconfirm >/dev/null 2>&1 || step_warn "Package database sync failed"
  fi

  # `ffmpeg` is ours, not Resolve's: diagnose uses it for the NVENC encoder and
  # render tests, and the codec probe reads streams with it. Resolve itself
  # needs no system ffmpeg — it bundles its own (libavcodec.so.60,
  # libavformat.so.60, libavutil.so.58, libswscale.so.7 in /opt/resolve/libs)
  # and the RPATH patch below points it at them. The `ffmpeg4.4` that used to
  # sit here was inherited folklore: it supplies the .58/.56 sonames, which
  # nothing under /opt/resolve references, linked or dlopened.
  local packages=(unzip patchelf libarchive xdg-user-dirs desktop-file-utils file
                  gtk-update-icon-cache rsync libxcrypt-compat ffmpeg glu fuse2)
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   would install (one at a time): ${packages[*]}"
    step_skip "dry run"
    emit_progress 10
    return 0
  fi
  local failed=() pkg
  for pkg in "${packages[@]}"; do
    pacman -S --needed --noconfirm "${pkg}" >/dev/null 2>&1 || failed+=("${pkg}")
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    step_warn "Could not install: ${failed[*]} (may affect functionality)"
  else
    step_ok "Dependencies installed"
  fi
  emit_progress 10
}

# Resolve's extras downloader looks for TLS certificates at the Red Hat path
# rather than the Arch one.
root_link_certs() {
  step certs "Linking CentOS certificate path…"
  if [[ -e /etc/pki/tls ]]; then
    step_skip "/etc/pki/tls already present"
  else
    run mkdir -p /etc/pki
    run ln -sf /etc/ssl /etc/pki/tls
    step_ok
  fi
  emit_progress 12
}

# ------------------------------------------------------------------ extraction
# ZIP → .run → squashfs-root. Needs ~10 GB of scratch space, cleaned up by the
# EXIT trap whether we succeed, fail, or get interrupted.
WORKDIR=""
APPDIR=""
root_cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    log "Cleaning up temporary directory…"
    rm -rf "${WORKDIR}" 2>/dev/null || true
  fi
}

root_extract() {
  local zip_dir; zip_dir="$(dirname "${INSTALL_ZIP}")"
  local need_gb=10 free_gb
  free_gb=$(( $(df --output=avail -k "${zip_dir}" | tail -n1) / 1024 / 1024 ))
  (( free_gb >= need_gb )) || step_fail "Not enough free space in ${zip_dir}: ${free_gb} GiB < ${need_gb} GiB"

  step unzip "Unpacking ZIP…"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   would unpack ${INSTALL_ZIP} into a temp dir under ${zip_dir}"
    echo "   would extract its .run payload, then delete the temp dir"
    step_skip "dry run"
    emit_progress 25
    emit_step appimage skip "Extracting AppImage payload (dry run)"
    emit_progress 40
    return 0
  fi
  WORKDIR="$(mktemp -d -p "${zip_dir}" .resolve-extract-XXXXXXXX)"
  trap root_cleanup EXIT
  run unzip -q "${INSTALL_ZIP}" -d "${WORKDIR}" || step_fail "Failed to unpack ${INSTALL_ZIP}"
  step_ok
  emit_progress 25

  step appimage "Extracting AppImage payload…"
  local run_file
  run_file="$(find "${WORKDIR}" -maxdepth 2 -type f -name 'DaVinci_Resolve_*_Linux.run' | head -n1 || true)"
  [[ -n "${run_file}" ]] || step_fail "Could not find the .run installer in the ZIP"
  run chmod +x "${run_file}"
  local ex_dir; ex_dir="$(dirname "${run_file}")"
  if [[ "${DRY_RUN}" != "1" ]]; then
    ( cd "${ex_dir}" && "./$(basename "${run_file}")" --appimage-extract >/dev/null ) \
      || step_fail "Failed to extract AppImage payload"
  fi
  APPDIR="${ex_dir}/squashfs-root"
  if [[ "${DRY_RUN}" != "1" ]]; then
    [[ -d "${APPDIR}" ]] || step_fail "Extraction failed (no squashfs-root)"
    chmod -R u+rwX,go+rX,go-w "${APPDIR}" || step_warn "Could not normalize all permissions"
    [[ -s "${APPDIR}/bin/resolve" ]] || step_fail "resolve binary missing or zero-size"
  fi
  step_ok
  emit_progress 40
}

# --------------------------------------------------- ABI-safe library handling
# REPLACE with system versions — stable C ABI, and the bundled copies are too
# old for current Arch:
#   libglib-2.0 / libgio-2.0 / libgmodule-2.0
# KEEP the bundled versions — Resolve was compiled against a specific C++ ABI
# and swapping these crashes it immediately:
#   libc++ / libc++abi
root_fix_libs() {
  step libs "Swapping bundled glib for system glib…"
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; emit_progress 45; return 0; }

  pushd "${APPDIR}" >/dev/null || step_fail "Could not enter ${APPDIR}"
  local syslib target
  declare -A glib_libs=(
    ["/usr/lib/libglib-2.0.so.0"]="libs/libglib-2.0.so.0"
    ["/usr/lib/libgio-2.0.so.0"]="libs/libgio-2.0.so.0"
    ["/usr/lib/libgmodule-2.0.so.0"]="libs/libgmodule-2.0.so.0"
  )
  for syslib in "${!glib_libs[@]}"; do
    target="${glib_libs[$syslib]}"
    if [[ -e "${syslib}" ]]; then
      rm -f "${target}" || true
      ln -sf "${syslib}" "${target}" || step_warn "Failed to symlink ${syslib}"
    else
      step_warn "System library ${syslib} not found, keeping bundled version"
    fi
  done

  # Control-surface libraries (Editor Keyboard, Mini/Micro Panel) ship in a
  # tarball that nothing unpacks for us.
  #
  # That tarball carries its own copy of the C++ runtime — lib/libc++.so.1 and
  # lib/libc++abi.so.1, built for the panel framework and older than Resolve's.
  # Moving the tarball in wholesale replaces Resolve's libc++ symlinks with it,
  # and Resolve then dies the moment it is exec'd:
  #
  #   /opt/resolve/bin/resolve: symbol lookup error: /opt/resolve/bin/resolve:
  #   undefined symbol: _ZNSt3__117bad_function_callD1Ev
  #
  # Launched from the app menu that is invisible: no window, no message. So the
  # tarball may only ADD names to libs/ — anything already there is Resolve's
  # own and wins. Skipped files stay in share/panels/lib, which is outside
  # every RPATH we set below and so is never loaded from.
  if [[ -d "share/panels" ]]; then
    pushd "share/panels" >/dev/null || step_fail "Could not enter share/panels"
    tar -zxf dvpanel-framework-linux-x86_64.tgz 2>/dev/null || true
    mkdir -p "${APPDIR}/libs"
    local panel_lib panel_name
    while IFS= read -r -d '' panel_lib; do
      panel_name="$(basename "${panel_lib}")"
      if [[ -e "${APPDIR}/libs/${panel_name}" || -L "${APPDIR}/libs/${panel_name}" ]]; then
        log "  Keeping Resolve's own ${panel_name} over the panel framework's"
        continue
      fi
      mv -f "${panel_lib}" "${APPDIR}/libs" 2>/dev/null || true
    done < <(
      find . -maxdepth 1 -type f -name '*.so' -print0 2>/dev/null || true
      [[ -d lib ]] && { find lib -type f -name '*.so*' -print0 2>/dev/null || true; }
      true
    )
    popd >/dev/null || true
  fi

  # AppImage launcher leftovers we have no use for, installing to /opt.
  rm -f AppRun 2>/dev/null || true
  rm -rf installer 2>/dev/null || true
  mkdir -p bin
  ln -sf "../BlackmagicRAWPlayer/BlackmagicRawAPI" "bin/" 2>/dev/null || true
  popd >/dev/null || true
  step_ok
  emit_progress 45
}

root_install_tree() {
  step copy "Installing to ${RESOLVE_PREFIX}…"
  run rm -rf "${RESOLVE_PREFIX}"
  run mkdir -p "${RESOLVE_PREFIX}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${APPDIR}/" "${RESOLVE_PREFIX}/" || step_fail "Copy to ${RESOLVE_PREFIX} failed"
    else
      cp -a "${APPDIR}/." "${RESOLVE_PREFIX}/" || step_fail "Copy to ${RESOLVE_PREFIX} failed"
    fi
  fi
  # DaVinci Resolve Studio writes its activation into this directory as the
  # user running Resolve — but the install creates it as root, so left alone it
  # is not writable and licensing fails with nothing useful said about why.
  # This is the fix that circulates as `sudo chmod 7777 /opt/resolve/.license`:
  # what matters is the write bit for the user, the sticky bit stops one user
  # removing another's licence, and setuid is simply ignored on directories.
  # Harmless on the free edition, which never writes here.
  #
  # Announced through run() rather than hidden inside the copy above, so a dry
  # run shows it: this is the single most important thing the step does, and a
  # preview that omits it is a preview of the wrong install.
  run mkdir -p "${RESOLVE_PREFIX}/.license"
  run chmod 7777 "${RESOLVE_PREFIX}/.license"
  step_ok
  emit_progress 60
}

# ----------------------------------------------------------------- RPATH patch
# Resolve's binaries carry RPATHs pointing at the original AppImage paths,
# which no longer exist. Every ELF gets repointed at /opt/resolve — including
# the ~200 MB libQt5WebEngineCore.so, which cannot be skipped for size because
# it links to other Resolve libs.
RPATH_DIRS=( "libs" "libs/plugins/sqldrivers" "libs/plugins/xcbglintegrations" "libs/plugins/imageformats"
             "libs/plugins/platforms" "libs/Fusion" "plugins" "bin"
             "BlackmagicRAWSpeedTest/BlackmagicRawAPI" "BlackmagicRAWSpeedTest/plugins/platforms"
             "BlackmagicRAWSpeedTest/plugins/imageformats" "BlackmagicRAWSpeedTest/plugins/mediaservice"
             "BlackmagicRAWSpeedTest/plugins/audio" "BlackmagicRAWSpeedTest/plugins/xcbglintegrations"
             "BlackmagicRAWSpeedTest/plugins/bearer"
             "BlackmagicRAWPlayer/BlackmagicRawAPI" "BlackmagicRAWPlayer/plugins/mediaservice"
             "BlackmagicRAWPlayer/plugins/imageformats" "BlackmagicRAWPlayer/plugins/audio"
             "BlackmagicRAWPlayer/plugins/platforms" "BlackmagicRAWPlayer/plugins/xcbglintegrations"
             "BlackmagicRAWPlayer/plugins/bearer"
             "Onboarding/plugins/xcbglintegrations" "Onboarding/plugins/qtwebengine"
             "Onboarding/plugins/platforms" "Onboarding/plugins/imageformats"
             "DaVinci Control Panels Setup/plugins/platforms"
             "DaVinci Control Panels Setup/plugins/imageformats"
             "DaVinci Control Panels Setup/plugins/bearer"
             "DaVinci Control Panels Setup/AdminUtility/PlugIns/DaVinciKeyboards"
             "DaVinci Control Panels Setup/AdminUtility/PlugIns/DaVinciPanels" )

root_patch_rpath() {
  step rpath "Patching RPATHs (this is the slow part)…"
  if ! command -v patchelf >/dev/null 2>&1; then
    step_warn "patchelf not found, skipping RPATH patching"
    emit_progress 85
    return 0
  fi
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; emit_progress 85; return 0; }

  local rpath_abs="" p
  for p in "${RPATH_DIRS[@]}"; do rpath_abs+="${RESOLVE_PREFIX}/${p}:"; done
  rpath_abs+="\$ORIGIN"

  local total seen=0 patched=0 fail_count=0 skipped=0 pct=60
  total="$(find "${RESOLVE_PREFIX}" -type f | wc -l)"
  (( total > 0 )) || total=1

  local f info current size
  while IFS= read -r -d '' f; do
    seen=$((seen + 1))
    # Progress in 25 points spread across the whole tree walk, refreshed every
    # 200 files — often enough to look alive, rarely enough to stay cheap.
    if (( seen % 200 == 0 )); then
      local next=$(( 60 + (seen * 25 / total) ))
      if (( next > pct )); then pct=${next}; emit_progress "${pct}"; fi
    fi
    info="$(file -b "$f" 2>/dev/null)"
    if [[ "${info}" =~ ELF.*executable ]] || [[ "${info}" =~ ELF.*shared\ object ]]; then
      current="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
      if [[ "${current}" == "${rpath_abs}" ]]; then
        skipped=$((skipped + 1)); continue
      fi
      if patchelf --set-rpath "${rpath_abs}" "$f" 2>/dev/null; then
        patched=$((patched + 1))
      else
        fail_count=$((fail_count + 1))
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if (( size > 33554432 )); then warn "  Failed to patch large file: ${f##${RESOLVE_PREFIX}/}"; fi
      fi
    fi
  done < <(find "${RESOLVE_PREFIX}" -type f -print0)

  step_ok "Patched ${patched} files (${fail_count} failures, ${skipped} already correct)"
  log "  Patched RPATH: ${patched} files (${fail_count} failures, ${skipped} already correct)"
  emit_progress 85
}

# Arch moved to libcrypt.so.2; Resolve still links the old .so.1 that
# libxcrypt-compat provides.
root_fix_libcrypt() {
  step libcrypt "Ensuring legacy libcrypt.so.1…"
  run pacman -S --needed --noconfirm libxcrypt-compat >/dev/null 2>&1 || true
  run ldconfig || true
  if [[ -e /usr/lib/libcrypt.so.1 ]]; then
    run ln -sf /usr/lib/libcrypt.so.1 "${RESOLVE_PREFIX}/libs/libcrypt.so.1"
    step_ok
  else
    step_warn "libcrypt.so.1 not available"
  fi
  emit_progress 87
}

root_desktop_integration() {
  step desktop "Installing desktop entries, icons and udev rules…"
  local src dest
  declare -A desktop_files=(
    ["${RESOLVE_PREFIX}/share/DaVinciResolve.desktop"]="/usr/share/applications/DaVinciResolve.desktop"
    ["${RESOLVE_PREFIX}/share/DaVinciControlPanelsSetup.desktop"]="/usr/share/applications/DaVinciControlPanelsSetup.desktop"
    ["${RESOLVE_PREFIX}/share/blackmagicraw-player.desktop"]="/usr/share/applications/blackmagicraw-player.desktop"
    ["${RESOLVE_PREFIX}/share/blackmagicraw-speedtest.desktop"]="/usr/share/applications/blackmagicraw-speedtest.desktop"
  )
  for src in "${!desktop_files[@]}"; do
    dest="${desktop_files[$src]}"
    if [[ -f "${src}" ]]; then run install -D -m 0644 "${src}" "${dest}"
    else warn "  Desktop file not found: ${src}"; fi
  done

  declare -A icon_files=(
    ["${RESOLVE_PREFIX}/graphics/DV_Resolve.png"]="/usr/share/icons/hicolor/128x128/apps/davinci-resolve.png"
    ["${RESOLVE_PREFIX}/graphics/DV_Panels.png"]="/usr/share/icons/hicolor/128x128/apps/davinci-resolve-panels-setup.png"
    ["${RESOLVE_PREFIX}/graphics/blackmagicraw-player_256x256_apps.png"]="/usr/share/icons/hicolor/256x256/apps/blackmagicraw-player.png"
    ["${RESOLVE_PREFIX}/graphics/blackmagicraw-speedtest_256x256_apps.png"]="/usr/share/icons/hicolor/256x256/apps/blackmagicraw-speedtest.png"
  )
  for src in "${!icon_files[@]}"; do
    dest="${icon_files[$src]}"
    if [[ -f "${src}" ]]; then run install -D -m 0644 "${src}" "${dest}"
    else warn "  Icon file not found: ${src}"; fi
  done

  run update-desktop-database >/dev/null 2>&1 || true
  run gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true

  # Without these, Blackmagic hardware is root-only.
  local r
  for r in 99-BlackmagicDevices.rules 99-ResolveKeyboardHID.rules 99-DavinciPanel.rules; do
    if [[ -f "${RESOLVE_PREFIX}/share/etc/udev/rules.d/${r}" ]]; then
      run install -D -m 0644 "${RESOLVE_PREFIX}/share/etc/udev/rules.d/${r}" "/usr/lib/udev/rules.d/${r}"
    fi
  done
  run udevadm control --reload-rules >/dev/null 2>&1 || true
  run udevadm trigger >/dev/null 2>&1 || true
  step_ok
  emit_progress 92
}

# ------------------------------------------------------------------- launchers
# Resolve has no native Wayland support, so everything goes through a wrapper
# that forces XWayland and clears the Qt single-instance lockfiles a crash
# leaves behind.
root_install_wrapper() {
  step wrapper "Installing XWayland wrapper…"
  if [[ "${DRY_RUN}" == "1" ]]; then
    step_skip "dry run"; emit_progress 95; return 0
  fi
  cat > "${RESOLVE_WRAPPER}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
# Clear stale single-instance Qt lockfiles (only if we have permission)
if [[ -r /tmp ]]; then
  for lockfile in /tmp/qtsingleapp-DaVinci*lockfile; do
    [[ -f "$lockfile" ]] && rm -f "$lockfile" 2>/dev/null || true
  done
fi
# Force XWayland under Hyprland/Wayland
export QT_QPA_PLATFORM=xcb
export QT_AUTO_SCREEN_SCALE_FACTOR=1
# Omarchy sets QT_STYLE_OVERRIDE=kvantum and QT_QPA_PLATFORMTHEME=gtk3
# globally (Omarchy 4 envs.lua). Resolve's bundled Qt has neither plugin —
# harmless, but unset them so startup stays free of Qt style warnings.
unset QT_STYLE_OVERRIDE QT_QPA_PLATFORMTHEME
# For hybrid laptops, optionally force dGPU:
# export __NV_PRIME_RENDER_OFFLOAD=1
# export __GLX_VENDOR_LIBRARY_NAME=nvidia
exec /opt/resolve/bin/resolve "$@"
WRAPPER
  chmod +x "${RESOLVE_WRAPPER}"

  if [[ ! -e "${RESOLVE_SHIM}" ]]; then
    printf '#!/usr/bin/env bash\nexec %s "$@"\n' "${RESOLVE_WRAPPER}" > "${RESOLVE_SHIM}"
    chmod +x "${RESOLVE_SHIM}"
  fi

  # Point the system .desktop files at the wrapper so XWayland applies however
  # Resolve is launched.
  local d
  for d in /usr/share/applications/DaVinciResolve.desktop \
           /usr/share/applications/DaVinciResolveCaptureLogs.desktop; do
    [[ -f "${d}" ]] && sed -i "s|^Exec=.*|Exec=${RESOLVE_WRAPPER} %U|" "${d}"
  done
  update-desktop-database >/dev/null 2>&1 || true
  step_ok
  emit_progress 95
}

# Resolve defaults to a DeckLink audio backend, which aborts on first launch on
# any machine without a Blackmagic card. Patch the system template; the user's
# own config is handled in the user phase.
root_fix_audio_default() {
  step audio "Setting audio backend default to ALSA…"
  local template="${RESOLVE_PREFIX}/share/default-config.dat"
  if [[ -f "${template}" ]] && grep -q '^Local\.Audio\.Type = DeckLink$' "${template}"; then
    run sed -i 's|^Local\.Audio\.Type = DeckLink$|Local.Audio.Type = ALSA|' "${template}"
    step_ok "Patched ${template}"
  else
    step_skip "Template already correct or absent"
  fi
  emit_progress 96
}

# The render-blocker fix. Resolve opens raw ALSA hardware directly and
# enumerates every card looking for one it can own; when PipeWire holds them
# all, that enumeration loops forever and the render queue never starts the
# encoder. snd-aloop gives it a virtual card PipeWire does not claim.
root_setup_aloop() {
  if [[ "${SETUP_ALOOP}" != "1" ]]; then
    step aloop "snd-aloop setup"; step_skip "Skipped (--no-aloop)"; emit_progress 98; return 0
  fi
  step aloop "Setting up snd-aloop virtual audio card…"
  if ! lsmod | grep -E '^snd_aloop' >/dev/null; then
    if run modprobe snd-aloop 2>/dev/null; then
      log "  snd-aloop loaded for the current session"
    else
      step_warn "modprobe snd-aloop failed — kernel may lack the module (verify: modinfo snd-aloop)"
    fi
  else
    log "  snd-aloop already loaded"
  fi
  if [[ ! -f "${ALOOP_CONF}" ]] || ! grep -qx 'snd-aloop' "${ALOOP_CONF}" 2>/dev/null; then
    if [[ "${DRY_RUN}" == "1" ]]; then echo "   would write ${ALOOP_CONF}"
    else echo 'snd-aloop' > "${ALOOP_CONF}"; fi
    log "  Wrote ${ALOOP_CONF} (autoloads at boot)"
  fi
  step_ok
  emit_progress 98
}

# Records what was installed so the panel can show a real version, and so
# "an update is available" means something more than "a ZIP exists".
root_write_stamp() {
  step stamp "Recording install metadata…"
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; emit_progress 100; return 0; }
  local base version edition
  base="$(basename "${INSTALL_ZIP}")"
  version="${base#DaVinci_Resolve_}"; version="${version#Studio_}"; version="${version%_Linux.zip}"
  edition="Free"; [[ "${base}" == *_Studio_* ]] && edition="Studio"
  cat > "${RESOLVE_STAMP}" <<STAMP
{
  "version": "$(json_escape "${version}")",
  "edition": "$(json_escape "${edition}")",
  "zip": "$(json_escape "${base}")",
  "installed": "$(date -Iseconds)",
  "engineVersion": "$(json_escape "${ENGINE_VERSION}")"
}
STAMP
  emit_field installedVersion "${version}"
  emit_field installedEdition "${edition}"
  step_ok
  emit_progress 100
}

do_install_root() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --zip) INSTALL_ZIP="${2:-}"; shift 2 ;;
      --full-upgrade) FULL_UPGRADE=1; shift ;;
      --no-aloop) SETUP_ALOOP=0; shift ;;
      -h|--help) install_root_usage; exit 0 ;;
      *) install_root_usage; err "Unknown option: $1" ;;
    esac
  done

  # A dry run writes nothing, so it is allowed unprivileged — that is how you
  # preview what the install would do without authenticating for it.
  if [[ "${DRY_RUN}" != "1" ]]; then
    is_root || err "The root phase must run as root (use sudo, or pkexec from a GUI)"
  fi
  [[ -n "${INSTALL_ZIP}" ]] || { install_root_usage; err "--zip is required"; }
  [[ -f "${INSTALL_ZIP}" ]] || err "No such ZIP: ${INSTALL_ZIP}"

  emit_phase root "Installing DaVinci Resolve"
  log "Using installer ZIP: ${INSTALL_ZIP}"
  emit_progress 0

  root_install_packages
  root_link_certs
  root_extract
  root_fix_libs
  root_install_tree
  root_patch_rpath
  root_fix_libcrypt
  root_desktop_integration
  root_install_wrapper
  root_fix_audio_default
  root_setup_aloop
  root_write_stamp

  log "Root phase complete"
  emit_done 0
}
