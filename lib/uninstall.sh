#!/usr/bin/env bash
# Removal, split along the same root/user line as the install.
#
# User data is kept by default and only removed on an explicit --purge-data:
# ~/.local/share/DaVinciResolve holds the Project Library, and deleting that
# by accident loses actual work.

PURGE_DATA=0

uninstall_usage() {
  cat >&2 <<'USAGE'
usage: omarchy-resolve uninstall --phase root|user [--purge-data]
  --purge-data   (user phase) also delete ~/.local/share/DaVinciResolve,
                 including the Project Library. Not reversible.
USAGE
}

do_uninstall_root() {
  # As with install, a dry run writes nothing, so it needs no authentication —
  # which is how you see what an uninstall would remove before committing to it.
  if [[ "${DRY_RUN}" != "1" ]]; then
    is_root || err "The root phase must run as root (use sudo, or pkexec from a GUI)"
  fi
  emit_phase uninstall-root "Removing DaVinci Resolve"
  emit_progress 0

  step tree "Removing ${RESOLVE_PREFIX}…"
  run rm -rf "${RESOLVE_PREFIX}"
  step_ok
  emit_progress 40

  step launchers "Removing launchers…"
  run rm -f "${RESOLVE_WRAPPER}"
  # Only remove the shim if it is ours — a hand-written or packaged
  # /usr/bin/davinci-resolve is not this installer's to delete.
  if [[ -f "${RESOLVE_SHIM}" ]] && grep -q "${RESOLVE_WRAPPER}" "${RESOLVE_SHIM}" 2>/dev/null; then
    run rm -f "${RESOLVE_SHIM}"
  fi
  local f
  for f in /usr/share/applications/DaVinciResolve.desktop \
           /usr/share/applications/DaVinciResolveCaptureLogs.desktop \
           /usr/share/applications/DaVinciControlPanelsSetup.desktop \
           /usr/share/applications/blackmagicraw-player.desktop \
           /usr/share/applications/blackmagicraw-speedtest.desktop \
           /usr/share/icons/hicolor/128x128/apps/davinci-resolve.png \
           /usr/share/icons/hicolor/128x128/apps/davinci-resolve-panels-setup.png \
           /usr/share/icons/hicolor/256x256/apps/blackmagicraw-player.png \
           /usr/share/icons/hicolor/256x256/apps/blackmagicraw-speedtest.png; do
    run rm -f "${f}"
  done
  run update-desktop-database >/dev/null 2>&1 || true
  run gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
  step_ok
  emit_progress 70

  step udev "Removing udev rules…"
  local r
  for r in 99-BlackmagicDevices.rules 99-ResolveKeyboardHID.rules 99-DavinciPanel.rules; do
    run rm -f "/usr/lib/udev/rules.d/${r}"
  done
  run udevadm control --reload-rules >/dev/null 2>&1 || true
  step_ok
  emit_progress 85

  step aloop "Removing snd-aloop autoload…"
  run rm -f "${ALOOP_CONF}"
  step_ok
  # /etc/pki/tls is left alone on purpose: it is a symlink to /etc/ssl that
  # other CentOS-flavoured software may also be relying on by now.
  log "Left /etc/pki/tls in place (other software may use it)"
  emit_progress 100
  log "Root phase complete"
  emit_done 0
}

do_uninstall_user() {
  if is_root; then
    err "The user phase must NOT run as root — under sudo/pkexec \$HOME is root's and it would clean /root instead of your home"
  fi
  emit_phase uninstall-user "Cleaning up your session"
  emit_progress 0

  step userdesktop "Removing user desktop entry…"
  run rm -f "${HOME}/.local/share/applications/davinci-resolve-wrapper.desktop"
  run update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true
  step_ok
  emit_progress 20

  step hyprrules "Removing Hyprland rules…"
  local main="${HOME}/.config/hypr/hyprland.lua"
  run rm -f "${HOME}/.config/hypr/davinci-resolve.lua"
  if [[ -f "${main}" ]] && grep -q 'require("hypr.davinci-resolve")' "${main}"; then
    if [[ "${DRY_RUN}" != "1" ]]; then
      cp "${main}" "${main}.bak.$(date +%s)"
      # Drop the require and the comment line we appended above it.
      sed -i '/^-- Open DaVinci Resolve.s main window over the Omarchy bar/d; /require("hypr\.davinci-resolve")/d' "${main}"
    fi
    log "  Removed the require from hyprland.lua (backup .bak.<timestamp> created)"
  fi
  step_ok
  emit_progress 45

  step aloopbridge "Removing PipeWire bridge…"
  run rm -f "${HOME}/.config/pipewire/pipewire.conf.d/50-resolve-aloop-bridge.conf"
  run rm -f "${HOME}/.config/wireplumber/wireplumber.conf.d/51-resolve-aloop-no-default.conf"
  if systemctl --user is-active --quiet pipewire 2>/dev/null; then
    run systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
  fi
  step_ok
  emit_progress 65

  step aacfix "Removing AAC Fix…"
  local aac="${HOME}/.local/share/DaVinciResolve/Fusion/Scripts/Utility/AAC Fix.py"
  local aac_link="${HOME}/.local/bin/resolve-aac-fix"
  run rm -f "${aac}"
  # Only take the CLI link if it is ours — one pointing at a git checkout of
  # resolve-aac-fix belongs to whoever installed that by hand.
  if [[ -L "${aac_link}" && "$(readlink "${aac_link}")" == "${aac}" ]]; then
    run rm -f "${aac_link}"
  fi
  step_ok
  emit_progress 75

  step userdata "Checking user data…"
  local data="${HOME}/.local/share/DaVinciResolve"
  if [[ "${PURGE_DATA}" == "1" ]]; then
    run rm -rf "${data}"
    step_ok "Deleted ${data} (including the Project Library)"
  elif [[ -d "${data}" ]]; then
    step_skip "Kept ${data} — it holds your Project Library. Pass --purge-data to delete it."
  else
    step_skip "Nothing to keep"
  fi
  emit_progress 90

  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
  emit_progress 100
  log "User phase complete"
  emit_done 0
}

do_uninstall() {
  local phase=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase) phase="${2:-}"; shift 2 ;;
      --purge-data) PURGE_DATA=1; shift ;;
      -h|--help) uninstall_usage; exit 0 ;;
      *) uninstall_usage; err "Unknown option: $1" ;;
    esac
  done
  case "${phase}" in
    root) do_uninstall_root ;;
    user) do_uninstall_user ;;
    *) uninstall_usage; err "--phase root|user is required" ;;
  esac
}
