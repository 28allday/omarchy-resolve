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
    # Adding packages against a freshly synced database while the rest of the
    # system is behind it is a partial upgrade — the thing Arch warns about,
    # because a new package can link against a library the system has not
    # caught up to yet. Say how far behind rather than silently doing it.
    if [[ "${DRY_RUN}" != "1" ]]; then
      local behind
      behind="$(pacman -Qu 2>/dev/null | grep -vc '\[ignored\]' || true)"
      if (( behind > 0 )); then
        warn "  ${behind} installed package(s) are behind the package database. Installing"
        warn "  against it is a partial upgrade; if anything misbehaves afterwards, run"
        warn "  'omarchy update' (or pacman -Syu) and try again."
      fi
    fi
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
  # Whatever the detected card needs to be a compute device. Empty on NVIDIA —
  # CUDA arrives with the driver, which Omarchy owns. See gpu_stack_packages()
  # in lib/check.sh, which must list the same names so the panel's "missing
  # packages" line agrees with what this actually installs.
  local pkg_line
  while IFS= read -r pkg_line; do
    [[ -n "${pkg_line}" ]] && packages+=("${pkg_line}")
  done < <(gpu_stack_packages "${COMPUTE_VENDOR}")
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

# ------------------------------------------------------------- compute stack
# Resolve does every frame of its work on the GPU. On NVIDIA that is CUDA and
# it comes with the driver, so there is nothing to do. On AMD and Intel it is
# OpenCL, supplied by a runtime that is not installed on a stock Arch desktop —
# and without it Resolve does not degrade, it dies on first launch with
#
#   Unsupported GPU Processing Mode
#
# and no hint as to what is missing. That single omission is why this installer
# only ever worked on NVIDIA machines.

# ROCm 7.1.1 from the Arch Linux Archive, pinned in pacman.conf.
#
# ROCm 7.2.0 broke Resolve on every AMD GPU — clCreateContext fails outright or
# hangs on the Color page (ROCm/ROCm#5982). 7.1.1 was the last release that
# worked everywhere, and it is what the sibling AMD installer has been shipping
# against an RX 9060 XT, a 7800 XT and a 760M.
#
# AMD did fix the launch crash in 7.2.1, and Arch has carried 7.2.4 since
# 2026-05-31 — but Arch's own 7.2.2 build was still reported broken after that
# fix, and nobody has retested 7.2.4 on gfx1200. The pin stays the default
# until someone does; NOTES.md carries the reasoning and the reversible
# re-test procedure. Do not wait for a "7.3": AMD's numbering went 7.2.4 →
# 7.14.0, and 7.14 has OpenCL problems of its own.
#
# opencl-amd (AUR) is deliberately not used: it bundles its own ROCm and
# conflicts with rocm-opencl-runtime, so it is one or the other.
root_install_rocm() {
  step rocm "Installing pinned ROCm ${ROCM_PIN_VERSION} for AMD…"

  local state; state="$(rocm_pin_state)"
  if [[ "${state%%|*}" == "ok" ]] && pacman -Q spirv-llvm-translator 2>/dev/null | grep -q "${SPIRV_PIN_VERSION}"; then
    step_skip "ROCm ${ROCM_PIN_VERSION} already installed at the pinned versions"
    root_pin_rocm
    return 0
  fi

  local ala="https://archive.archlinux.org/packages"
  local urls=(
    "${ala}/r/rocm-core/rocm-core-${ROCM_PIN_VERSION}-1-x86_64.pkg.tar.zst"
    "${ala}/r/rocm-device-libs/rocm-device-libs-2:${ROCM_PIN_VERSION}-1-x86_64.pkg.tar.zst"
    "${ala}/r/rocm-llvm/rocm-llvm-2:${ROCM_PIN_VERSION}-1-x86_64.pkg.tar.zst"
    "${ala}/r/rocm-opencl-runtime/rocm-opencl-runtime-${ROCM_PIN_VERSION}-1-x86_64.pkg.tar.zst"
    "${ala}/c/comgr/comgr-2:${ROCM_PIN_VERSION}-1-x86_64.pkg.tar.zst"
    "${ala}/s/spirv-llvm-translator/spirv-llvm-translator-${SPIRV_PIN_VERSION}-1-x86_64.pkg.tar.zst"
  )

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   would remove opencl-amd if present (it conflicts with rocm-opencl-runtime)"
    echo "   would download ${#urls[@]} packages from the Arch Linux Archive:"
    local u; for u in "${urls[@]}"; do echo "     $(basename "${u}")"; done
    echo "   would install them with pacman -U, then pin them in ${PACMAN_CONF}"
    step_skip "dry run"
    emit_progress 8
    return 0
  fi

  # opencl-amd carries its own ROCm and conflicts with rocm-opencl-runtime, so
  # pacman -U would refuse the whole transaction while it is installed.
  local conflict
  for conflict in opencl-amd opencl-amd-debug; do
    if pacman -Q "${conflict}" >/dev/null 2>&1; then
      log "  Removing ${conflict} (conflicts with rocm-opencl-runtime)"
      pacman -Rns --noconfirm "${conflict}" >/dev/null 2>&1 || \
        step_warn "Could not remove ${conflict} — the ROCm install may fail"
    fi
  done

  local tmp; tmp="$(mktemp -d -t omarchy-resolve-rocm-XXXXXX)"
  local files=() url fname
  for url in "${urls[@]}"; do
    fname="$(basename "${url}")"
    log "  ${fname}"
    if curl -fsSL --output "${tmp}/${fname}" "${url}"; then
      files+=("${tmp}/${fname}")
    else
      rm -rf "${tmp}"
      step_fail "Could not download ${fname} from the Arch Linux Archive — check the network, then re-run"
    fi
  done

  # Runtime dependencies of the ROCm packages, normally already present.
  pacman -S --needed --noconfirm numactl gflags >/dev/null 2>&1 || true

  if ! pacman -U --noconfirm "${files[@]}" >/dev/null 2>&1; then
    rm -rf "${tmp}"
    step_fail "pacman refused the pinned ROCm packages — stopping before the launcher is written against a broken stack"
  fi
  rm -rf "${tmp}"

  root_pin_rocm
  step_ok "ROCm ${ROCM_PIN_VERSION} installed"
  emit_progress 8
}

# Hold the stack there. Without this the next routine `pacman -Syu` pulls ROCm
# forward and Resolve stops launching, with nothing to connect the two events.
# The marker comment is what lets uninstall tell our line from one the user
# wrote, and remove only ours.
root_pin_rocm() {
  if grep -qE '^IgnorePkg.*rocm-core' "${PACMAN_CONF}" 2>/dev/null; then
    log "  ROCm is already pinned in ${PACMAN_CONF}"
    return 0
  fi
  local pins="${ROCM_PIN_PACKAGES[*]} spirv-llvm-translator"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   would add to ${PACMAN_CONF} [options]: IgnorePkg = ${pins}"
    return 0
  fi
  # pacman merges repeated IgnorePkg directives, so appending a line of our own
  # is safe even when the user already has one.
  sed -i "/^\[options\]/a ${ROCM_PIN_MARKER}\nIgnorePkg = ${pins}" "${PACMAN_CONF}"
  log "  Pinned ROCm in ${PACMAN_CONF} — 'pacman -Syu' will now leave it alone"
}

# Intel's runtime comes from the repos, so there is no archive dance — but it
# is worth confirming it actually landed. A missing NEO is the difference
# between Resolve running and Resolve refusing to start, and pacman failing on
# one package out of six is easy to miss in a scrolling log.
root_verify_intel_stack() {
  step intelstack "Checking the Intel compute runtime…"
  if [[ "${DRY_RUN}" == "1" ]]; then step_skip "dry run"; return 0; fi
  local pkg missing=()
  for pkg in intel-compute-runtime level-zero-loader ocl-icd; do
    pacman -Qq "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    step_fail "Missing Intel compute packages: ${missing[*]} — Resolve would start and immediately fail with Unsupported GPU Processing Mode"
  fi
  step_ok "Intel NEO OpenCL present"
}

root_install_gpu_stack() {
  case "${COMPUTE_VENDOR}" in
    amd)    root_install_rocm ;;
    intel)  root_verify_intel_stack ;;
    nvidia)
      step cuda "Checking the NVIDIA compute stack…"
      if command -v nvidia-smi >/dev/null 2>&1; then
        step_ok "CUDA available through the installed NVIDIA driver"
      else
        step_warn "No nvidia-smi — install the NVIDIA driver, or Resolve will have nothing to compute on"
      fi ;;
    *)
      step gpustack "Checking the GPU compute stack…"
      step_warn "No supported GPU detected — Resolve needs an NVIDIA, AMD or Intel card" ;;
  esac
}

# Resolve's Blackmagic RAW decoders ship an OpenCL variant that fights the ROCm
# context Resolve itself is holding: BRAW clips stall or the Color page hangs.
# davincibox has moved these aside on AMD for years and it remains the standard
# fix. Renamed rather than deleted, so it is one mv to put back, and only done
# on AMD — on NVIDIA the same decoders are fine and faster than the CPU path.
root_disable_braw_opencl() {
  [[ "${COMPUTE_VENDOR}" == "amd" ]] || return 0
  step braw "Moving the BlackmagicRAW OpenCL decoders aside (AMD)…"
  local d moved=0
  for d in "${RESOLVE_PREFIX}/BlackmagicRAWPlayer/BlackmagicRawAPI/libDecoderOpenCL.so" \
           "${RESOLVE_PREFIX}/BlackmagicRAWSpeedTest/BlackmagicRawAPI/libDecoderOpenCL.so" \
           "${RESOLVE_PREFIX}/libs/BlackmagicRawAPI/libDecoderOpenCL.so"; do
    if [[ -f "${d}" && ! -f "${d}.bak" ]]; then
      run mv "${d}" "${d}.bak"
      moved=$((moved + 1))
    fi
  done
  if (( moved > 0 )); then step_ok "Disabled ${moved} decoder(s) — restore with mv <file>.bak <file>"
  else step_skip "Nothing to disable"; fi
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
LICENSE_KEEP=""
root_cleanup() {
  # An interrupted reinstall must not lose the Studio activation that was set
  # aside in root_install_tree(): put it back wherever the run stopped.
  if [[ -n "${LICENSE_KEEP:-}" && -d "${LICENSE_KEEP}/.license" ]]; then
    if [[ ! -d "${RESOLVE_PREFIX}/.license" ]]; then
      mkdir -p "${RESOLVE_PREFIX}" 2>/dev/null || true
      mv "${LICENSE_KEEP}/.license" "${RESOLVE_PREFIX}/.license" 2>/dev/null \
        && log "Restored ${RESOLVE_PREFIX}/.license (Studio activation)"
    fi
    if [[ -d "${LICENSE_KEEP}/.license" ]]; then
      warn "Studio activation left at ${LICENSE_KEEP}/.license — move it back to ${RESOLVE_PREFIX}/.license"
    else
      rmdir "${LICENSE_KEEP}" 2>/dev/null || true
    fi
  fi
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    log "Cleaning up temporary directory…"
    rm -rf "${WORKDIR}" 2>/dev/null || true
  fi
}

# SIGTERM arrives when the panel's Cancel button is used on the root phase (it
# has to ask pkexec to deliver it, since a user session cannot signal a root
# process). Bash defers the trap until the current foreground command returns,
# so a copy or a patchelf finishes rather than being cut mid-write; then the
# EXIT trap above restores the licence and removes the scratch directory.
root_interrupted() {
  warn "Stopped by request — cleaning up. The install is incomplete; run it again to finish."
  emit_done 143
  exit 143
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
  # DaVinci Resolve Studio keeps its activation in .license inside the prefix,
  # so wiping the tree for a reinstall or update would take the activation
  # with it and every update through the panel would end in the licence
  # dialog. Set it aside first and put it back over the fresh copy. The
  # holding directory sits beside the prefix so the move is a rename, and the
  # EXIT trap returns it if the run stops in between.
  if [[ -d "${RESOLVE_PREFIX}/.license" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "   would keep ${RESOLVE_PREFIX}/.license (Studio activation) across the reinstall"
    else
      LICENSE_KEEP="$(mktemp -d "$(dirname "${RESOLVE_PREFIX}")/.omarchy-resolve-license-XXXXXX")"
      mv "${RESOLVE_PREFIX}/.license" "${LICENSE_KEEP}/.license" \
        || step_fail "Could not set aside ${RESOLVE_PREFIX}/.license before the reinstall"
      log "  Keeping the existing .license (Studio activation) across the reinstall"
    fi
  fi
  run rm -rf "${RESOLVE_PREFIX}"
  run mkdir -p "${RESOLVE_PREFIX}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${APPDIR}/" "${RESOLVE_PREFIX}/" || step_fail "Copy to ${RESOLVE_PREFIX} failed"
    else
      cp -a "${APPDIR}/." "${RESOLVE_PREFIX}/" || step_fail "Copy to ${RESOLVE_PREFIX} failed"
    fi
  fi
  if [[ -n "${LICENSE_KEEP}" && -d "${LICENSE_KEEP}/.license" ]]; then
    rm -rf "${RESOLVE_PREFIX}/.license"
    mv "${LICENSE_KEEP}/.license" "${RESOLVE_PREFIX}/.license" \
      || step_fail "Could not restore the Studio activation from ${LICENSE_KEEP}/.license"
    rmdir "${LICENSE_KEEP}" 2>/dev/null || true
    LICENSE_KEEP=""
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

  # Resolve makes its own support directories under ~/.local/share/DaVinciResolve
  # — except the few it insists on putting inside the install prefix, which the
  # copy above leaves root-owned and unwritable. It mkdirs each 0777 at startup.
  # "Apple Immersive" is the fatal one:
  #
  #   Failed to create application support directories
  #
  # and exits before any window exists, so from the app menu it reads as
  # Resolve simply not launching. Same permissions as .license, same reasons.
  #
  # "Extras" (the download manager's package store, which reports "DDM init
  # failed") and "Fairlight" are not fatal but log errors on every launch.
  #
  # To find these on a new Resolve, launch it and read its own log — Resolve
  # names them itself, and its stderr is folded into the same file:
  #   grep "mkdir failed for directory" \
  #     ~/.local/share/DaVinciResolve/logs/ResolveDebug.txt
  local support_dir
  for support_dir in "Apple Immersive" "Extras" "Fairlight" "logs"; do
    run mkdir -p "${RESOLVE_PREFIX}/${support_dir}"
    run chmod 7777 "${RESOLVE_PREFIX}/${support_dir}"
  done
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
    if [[ -f "${src}" ]]; then
      run install -D -m 0644 "${src}" "${dest}"
      # Blackmagic ships these with the literal placeholder
      # RESOLVE_INSTALL_LOCATION in Path=, Icon= and Exec=; their own .run
      # installer substitutes it. We install from the extracted AppImage, so
      # nothing does — and a Path= that does not resolve is fatal, not
      # cosmetic. The launcher refuses to spawn at all:
      #
      #   gtk-launch: error launching application: Failed to change to
      #   directory "RESOLVE_INSTALL_LOCATION/" (No such file or directory)
      #
      # That leaves the RAW Player, RAW Speed Test and Control Panels Setup
      # entries dead, and .drp/.braw file associations broken — Resolve itself
      # only escapes because the user entry we write shadows it in the menu.
      run sed -i "s|RESOLVE_INSTALL_LOCATION|${RESOLVE_PREFIX}|g" "${dest}"
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
# leaves behind. It also carries the GPU environment, which is the part that
# differs per vendor and the part that decides whether Resolve computes at all.
#
# The wrapper picks its GPU at RUN time, not install time, using the same
# lib/gpu.sh embedded verbatim below. That is deliberate: a launcher with the
# card baked in goes quietly wrong the moment a GPU is added, removed or
# re-seated, and "the installer said 9060 XT but the launcher pinned the iGPU"
# is a failure nobody can see from the outside.
root_install_wrapper() {
  step wrapper "Installing XWayland wrapper…"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   would write ${RESOLVE_WRAPPER}, embedding the GPU picker"
    echo "   would pin: ${COMPUTE_VENDOR} at ${COMPUTE_BDF:-<none>}${COMPUTE_GFX:+ (${COMPUTE_GFX})}"
    step_skip "dry run"; emit_progress 95; return 0
  fi

  {
    cat <<'HEAD'
#!/usr/bin/env bash
set -euo pipefail
# DaVinci Resolve launcher — written by omarchy-resolve. Rewritten from
# scratch by every install and update, so edits here do not survive one; put
# local changes in an override file instead (see the end of this script).

# Clear stale single-instance Qt lockfiles (only if we have permission)
if [[ -r /tmp ]]; then
  for lockfile in /tmp/qtsingleapp-DaVinci*lockfile; do
    [[ -f "$lockfile" ]] && rm -f "$lockfile" 2>/dev/null || true
  done
fi
# Resolve's log4cxx config writes ./logs/rollinglog.txt — relative to the
# working directory, which is wherever the launcher happened to be:
#   log4cxx: setFile(./logs/rollinglog.txt,true) call failed.
#   log4cxx: IO Exception : status code = 2
# Blackmagic's own .desktop sets Path= to the install prefix for this reason,
# but ships it as the literal placeholder RESOLVE_INSTALL_LOCATION/. Doing it
# here covers every entry point — app menu, omarchy-resolve launch, and the
# system .desktop — rather than only the one we write.
cd /opt/resolve || true
# Force XWayland under Hyprland/Wayland
export QT_QPA_PLATFORM=xcb
export QT_AUTO_SCREEN_SCALE_FACTOR=1
# Omarchy sets QT_STYLE_OVERRIDE=kvantum and QT_QPA_PLATFORMTHEME=gtk3
# globally (Omarchy 4 envs.lua). Resolve's bundled Qt has neither plugin —
# harmless, but unset them so startup stays free of Qt style warnings.
unset QT_STYLE_OVERRIDE QT_QPA_PLATFORMTHEME
# Large projects open a lot of media files at once.
ulimit -n 65535 2>/dev/null || true

# ---------------------------------------------------------------- GPU picker
# Embedded verbatim from lib/gpu.sh so this launcher and the installer can
# never disagree about which card Resolve should use.
HEAD

    # The picker itself, minus its shebang.
    tail -n +2 "${ENGINE_LIB_DIR}/gpu.sh"

    cat <<'TAIL'

# --------------------------------------------------------------- overrides
# Two override files, system then user, read at two points. Here, before the
# pick, so RESOLVE_GPU_BDF and RESOLVE_NO_PIN set in them actually steer it;
# and again at the very end, so any variable they export outright wins over
# what the pick sets. Editing this file instead is pointless: every install
# and update rewrites it from scratch.
#
# Hybrid laptops that display through an iGPU and want the NVIDIA card put:
#   export __NV_PRIME_RENDER_OFFLOAD=1
#   export __GLX_VENDOR_LIBRARY_NAME=nvidia
resolve_read_overrides() {
  local override
  for override in /etc/omarchy-resolve/wrapper.env \
                  "${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/omarchy-resolve/wrapper.env"; do
    if [[ -r "${override}" ]]; then
      # shellcheck disable=SC1090
      source "${override}"
    fi
  done
}
resolve_read_overrides

# ------------------------------------------------------------ GPU environment
# RESOLVE_NO_PIN=1 turns all of this off; RESOLVE_GPU_BDF=0000:XX:YY.Z picks a
# specific card. Both are read by the picker above.
if [[ "${RESOLVE_NO_PIN:-0}" != "1" ]] && read -r RESOLVE_VENDOR RESOLVE_BDF RESOLVE_GFX < <(resolve_gpu_pick); then
  case "${RESOLVE_VENDOR}" in
    nvidia)
      # CUDA finds the card on its own, and forcing PRIME offload on a desktop
      # whose monitor is already on the NVIDIA card makes things worse, not
      # better. Hybrid laptops that display through the iGPU do want it — that
      # is what the override file at the bottom is for.
      : ;;
    amd)
      # Pin OpenGL and Vulkan to this exact card by PCI address.
      #
      # DRI_PRIME=1 is NOT used and must not be: it means "the OTHER card
      # relative to Mesa's default", so on a machine whose monitor is already
      # on the Radeon it flips OpenGL to the iGPU while OpenCL stays on the
      # Radeon. CL/GL interop (clCreateContext with CL_GL_CONTEXT_KHR) then
      # fails and Resolve hangs on the Color page with
      #   OpenCL Context Manager failed to create context
      # switcherooctl is skipped for the same reason — internally it is
      # DRI_PRIME=1 and inherits the bug. The explicit pci- tag always lands
      # on the intended card whatever the enumeration order.
      export DRI_PRIME="$(resolve_pci_tag "${RESOLVE_BDF}")"
      export MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1
      export MESA_VK_DEVICE_SELECT="$(resolve_pci_tag "${RESOLVE_BDF}")"
      export ROCM_PATH=/opt/rocm
      export LD_LIBRARY_PATH="/opt/rocm/lib:/opt/rocm/lib64:${LD_LIBRARY_PATH:-}"
      export OCL_ICD_VENDORS="${OCL_ICD_VENDORS:-/etc/OpenCL/vendors}"
      # ROCm numbers GPUs by amdkfd node order, which is not PCI order and not
      # "the discrete one first". Pin by this card's actual index so a Radeon
      # APU beside a Radeon card cannot end up as the device Resolve computes
      # on. Falls back to 0 — the single-Radeon case — when the topology is
      # not readable.
      export ROCR_VISIBLE_DEVICES="$(resolve_rocr_device_index "${RESOLVE_BDF}" 2>/dev/null || echo 0)"
      # Set even for targets ROCm supports natively: on RDNA4 + ROCm 7.1.1,
      # Resolve's clCreateContext needs it present regardless.
      if [[ -n "${RESOLVE_GFX}" ]]; then
        hsa="$(resolve_hsa_override "${RESOLVE_GFX}")"
        [[ -n "${hsa}" ]] && export HSA_OVERRIDE_GFX_VERSION="${hsa}"
      fi
      ;;
    intel)
      # NEO matches ZE_AFFINITY_MASK against the real device, so the BDF form
      # is used rather than an index — NEO's numeric order is not a function
      # of PCI order, and on hybrid machines it often enumerates the discrete
      # card first anyway.
      export ZE_AFFINITY_MASK="${RESOLVE_BDF}"
      export OCL_ICD_VENDORS="${OCL_ICD_VENDORS:-/etc/OpenCL/vendors}"
      export LIBVA_DRIVER_NAME=iHD
      # OpenCL init workaround for discrete Battlemage Xe2 silicon only. Intel
      # reuses the "Arc B-series" brand for the Xe3-LPG iGPUs in Panther Lake
      # (B360/B370/B380/B390), which neither need nor want this debug key —
      # hence the check that the card is not on the SoC bus.
      if [[ ! "${RESOLVE_BDF}" =~ ^0000:00: ]] &&
         lspci -nn 2>/dev/null | grep -qi 'Battlemage'; then
        export NEOReadDebugKeys=1
        export OverrideGpuAddressSpace=48
      fi
      ;;
  esac
fi

# Second pass: anything the override files export outright beats the pick.
resolve_read_overrides
exec /opt/resolve/bin/resolve "$@"
TAIL
  } > "${RESOLVE_WRAPPER}"
  chmod +x "${RESOLVE_WRAPPER}"

  # An install predating the rename left a wrapper under the old NVIDIA-only
  # name. Two launchers, one of them stale, is worse than none.
  if [[ -e "${RESOLVE_WRAPPER_LEGACY}" ]]; then
    rm -f "${RESOLVE_WRAPPER_LEGACY}"
    log "  Removed the old ${RESOLVE_WRAPPER_LEGACY}"
  fi

  # Write the shim when there is none, and repoint one that is ours — an
  # install predating the rename left it aimed at a wrapper that no longer
  # exists. A shim someone else wrote is left exactly as it is.
  if [[ ! -e "${RESOLVE_SHIM}" ]] ||
     grep -qE "${RESOLVE_WRAPPER}|${RESOLVE_WRAPPER_LEGACY}" "${RESOLVE_SHIM}" 2>/dev/null; then
    printf '#!/usr/bin/env bash\nexec %s "$@"\n' "${RESOLVE_WRAPPER}" > "${RESOLVE_SHIM}"
    chmod +x "${RESOLVE_SHIM}"
  else
    warn "  Left ${RESOLVE_SHIM} alone — it is not ours"
  fi

  # Point the system .desktop files at the wrapper so XWayland applies however
  # Resolve is launched.
  local d
  for d in /usr/share/applications/DaVinciResolve.desktop \
           /usr/share/applications/DaVinciResolveCaptureLogs.desktop; do
    [[ -f "${d}" ]] && sed -i "s|^Exec=.*|Exec=${RESOLVE_WRAPPER} %U|" "${d}"
  done
  update-desktop-database >/dev/null 2>&1 || true
  step_ok "Wrapper installed for ${COMPUTE_VENDOR}${COMPUTE_GFX:+ (${COMPUTE_GFX})}"
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
  # The GPU is recorded because the install is shaped by it — packages,
  # compute stack, BRAW decoders, launcher environment. Diagnose reads it back
  # to spot a machine whose card has changed since, which otherwise presents
  # as Resolve mysteriously refusing to start.
  cat > "${RESOLVE_STAMP}" <<STAMP
{
  "version": "$(json_escape "${version}")",
  "edition": "$(json_escape "${edition}")",
  "zip": "$(json_escape "${base}")",
  "installed": "$(date -Iseconds)",
  "computeVendor": "$(json_escape "${COMPUTE_VENDOR}")",
  "computeBdf": "$(json_escape "${COMPUTE_BDF}")",
  "computeGfx": "$(json_escape "${COMPUTE_GFX}")",
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
  # Omarchy 4 ships a pacman hook that aborts any direct `pacman -Syu` — its
  # updates go through `omarchy update`, which also takes the snapshot and
  # runs the migrations. Refusing up front beats a step that quietly fails
  # ten seconds in and carries on as if the upgrade had happened.
  if [[ "${FULL_UPGRADE}" == "1" ]] && [[ -x /usr/bin/omarchy-update-pacman-guard ]]; then
    err "--full-upgrade is not available on Omarchy: run 'omarchy update' first, then install without it"
  fi
  trap root_interrupted TERM INT

  # Decided once, up front: which card Resolve will compute on drives the
  # package list, the compute stack, the BRAW decoders and the launcher.
  resolve_compute_target || true
  emit_phase root "Installing DaVinci Resolve"
  log "Using installer ZIP: ${INSTALL_ZIP}"
  if [[ -n "${COMPUTE_BDF}" ]]; then
    log "Compute GPU: $(gpu_name_at "${COMPUTE_BDF}") at ${COMPUTE_BDF} (${COMPUTE_VENDOR}${COMPUTE_GFX:+, ${COMPUTE_GFX}})"
    emit_field computeVendor "${COMPUTE_VENDOR}"
    emit_field computeName "$(gpu_name_at "${COMPUTE_BDF}")"
  else
    warn "No GPU detected — Resolve will not run on this machine"
  fi
  emit_progress 0

  root_install_packages
  root_install_gpu_stack
  root_link_certs
  root_extract
  root_fix_libs
  root_install_tree
  root_disable_braw_opencl
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
