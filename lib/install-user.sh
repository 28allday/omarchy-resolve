#!/usr/bin/env bash
# User phase of the install: everything that lives under the user's home.
#
# Deliberately unprivileged. Run this as the user, never through pkexec or
# sudo — under either, $HOME is root's and every file below would be written
# into /root where nothing reads it. The engine refuses to run it as root for
# exactly that reason.

SETUP_ALOOP_USER=1
SETUP_HYPR_RULES=1
FORCE_HYPR_RULES=0
SETUP_AAC_FIX=1

install_user_usage() {
  cat >&2 <<'USAGE'
usage: omarchy-resolve install --phase user [options]
  --no-aloop            skip the PipeWire/Wireplumber loopback bridge
  --no-hypr-rules       do not touch the Hyprland config
  --force-hypr-rules    install the local rules even when Omarchy ships them
  --no-aac-fix          do not install the AAC Fix script and CLI
USAGE
}

# A user-level .desktop entry outranks the system one, so a Resolve update
# overwriting /usr/share cannot take the XWayland wrapper with it.
user_desktop_entry() {
  step userdesktop "Writing user desktop entry…"
  local dir="${HOME}/.local/share/applications"
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }
  mkdir -p "${dir}"
  cat > "${dir}/davinci-resolve-wrapper.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=DaVinci Resolve
Comment=DaVinci Resolve via XWayland wrapper (NVIDIA-Open)
Exec=${RESOLVE_WRAPPER} %U
TryExec=${RESOLVE_WRAPPER}
Terminal=false
Icon=davinci-resolve
Categories=AudioVideo;Video;Audio;Graphics;
StartupWMClass=resolve
X-GNOME-UsesNotifications=true
DESKTOP
  update-desktop-database "${dir}" >/dev/null 2>&1 || true
  step_ok
}

# True when Omarchy's own Resolve rules already cover the bar overlap and the
# dialog focus trap. Upstream took both fixes (basecamp/omarchy, 2026-07-30)
# and widened the titles to match Studio, so on a current Omarchy the local
# copies are strictly redundant — and narrower.
omarchy_ships_resolve_rules() {
  local f="/usr/share/omarchy/default/hypr/apps/davinci-resolve.lua"
  [[ -r "${f}" ]] || return 1
  grep -q 'fullscreen = true' "${f}" && grep -q 'stay_focused = false' "${f}"
}

omarchy_ships_opacity_rule() {
  local f="/usr/share/omarchy/default/hypr/apps/davinci-resolve.lua"
  [[ -r "${f}" ]] || return 1
  grep -q 'opacity = "1 1"' "${f}"
}

# Omarchy 4 applies a global translucency to every window, which is simply
# wrong for colour-critical grading. Upstream now opts Resolve out itself
# (PR #6382); this only still matters on Omarchy 4 builds predating it.
user_opacity_rule() {
  step opacity "Checking Resolve window opacity…"
  local hypr_lua="${HOME}/.config/hypr/hyprland.lua"
  if omarchy_ships_opacity_rule; then
    step_skip "Omarchy already keeps Resolve fully opaque"
    return 0
  fi
  if [[ ! -f "${hypr_lua}" ]] || ! grep -q 'default\.hypr\.omarchy' "${hypr_lua}"; then
    step_skip "No Omarchy 4 Lua config detected (not needed pre-4)"
    return 0
  fi
  if grep -q 'resolve-full-opacity' "${hypr_lua}"; then
    step_skip "Opacity rule already present"
    return 0
  fi
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }
  cat >> "${hypr_lua}" <<'LUA'

-- resolve-full-opacity (added by omarchy-resolve): Omarchy's default window
-- translucency is wrong for colour-critical work; keep DaVinci Resolve fully
-- opaque. Loaded after Omarchy defaults, so this rule wins.
o.window(".*[Rr]esolve.*", { opacity = "1 1" })
LUA
  step_ok "Added full-opacity rule to ${hypr_lua}"
}

# Two Omarchy-specific Resolve problems, both fixed with window rules:
#   1. the bar covers Resolve's menu bar — Resolve's floating XWayland window
#      places itself at 0,0 and ignores the bar's reserved zone. A fullscreen
#      window renders above top-layer surfaces, so fullscreening the main
#      window (and only the main window, matched by its " - <project>" title)
#      puts it over the bar instead of under it.
#   2. dialogs trap the pointer — Omarchy pins focus on every Resolve window so
#      transient popups survive mouse-out, but two pinned windows fight over
#      focus forever. Unpinning the two parents the popups open over leaves at
#      most one pinned window visible.
# Both were accepted upstream, so on a current Omarchy this writes nothing.
user_hypr_rules() {
  step hyprrules "Checking Hyprland window rules…"
  if [[ "${SETUP_HYPR_RULES}" != "1" ]]; then
    step_skip "Skipped (--no-hypr-rules)"; return 0
  fi
  if omarchy_ships_resolve_rules && [[ "${FORCE_HYPR_RULES}" != "1" ]]; then
    step_skip "Omarchy already ships these rules (and matches Studio too)"
    return 0
  fi

  local hypr_main="${HOME}/.config/hypr/hyprland.lua"
  if [[ ! -f "${hypr_main}" ]]; then
    step_warn "No ${hypr_main} — add these to your Hyprland config by hand:"
    warn "  windowrulev2 = fullscreen, class:^(resolve)\$, title:^(DaVinci Resolve - .+)\$"
    warn "  windowrulev2 = stayfocused off, class:^(resolve)\$, title:^(DaVinci Resolve - .+|Project Manager)\$"
    return 0
  fi

  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }
  local module="${HOME}/.config/hypr/davinci-resolve.lua"
  cat > "${module}" <<'LUA'
-- DaVinci Resolve — installed by omarchy-resolve.
-- Delete this file and the require() line in hyprland.lua to revert.

-- Resolve's floating main window ignores the bar's reserved zone, so the bar
-- covers its menu bar; fullscreen renders above top-layer surfaces. Scoped by
-- title so the splash and Project Manager keep their natural size.
o.window({ class = ".*[Rr]esolve.*", title = "^DaVinci Resolve( Studio)? - .+$" }, { fullscreen = true })

-- Resolve's transient popups close on mouse-out unless focus is pinned, but
-- pinning the windows they open *over* makes two stay_focused windows fight
-- and traps the pointer until Resolve is killed. Unpin the parents only.
o.window({ class = ".*[Rr]esolve.*", title = "^(DaVinci Resolve( Studio)? - .+|Project Manager)$" }, { stay_focused = false })
LUA

  # Omarchy's hyprland.lua require()s each user module explicitly — there is no
  # auto-loaded drop-in directory. package.path includes ~/.config/?.lua, so
  # "hypr.davinci-resolve" resolves to the file above.
  if grep -q 'require("hypr.davinci-resolve")' "${hypr_main}"; then
    step_ok "Rules refreshed (require already present)"
  else
    cp "${hypr_main}" "${hypr_main}.bak.$(date +%s)"
    cat >> "${hypr_main}" <<'LUA'

-- Open DaVinci Resolve's main window over the Omarchy bar instead of under it.
require("hypr.davinci-resolve")
LUA
    step_ok "Rules installed (backup .bak.<timestamp> created)"
  fi
}

user_reload_hypr() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  hyprctl version >/dev/null 2>&1 || return 0
  step hyprreload "Reloading Hyprland…"
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }
  hyprctl reload >/dev/null 2>&1 || true
  local errors; errors="$(hyprctl configerrors 2>/dev/null || true)"
  if [[ -n "${errors}" && "${errors}" != "no errors" ]]; then
    step_warn "Hyprland reported config errors after reload"
    warn "${errors}"
  else
    step_ok "Reloaded (no config errors)"
  fi
}

user_fix_audio_config() {
  step useraudio "Checking Resolve audio backend…"
  local cfg="${HOME}/.local/share/DaVinciResolve/configs/config.dat"
  if [[ ! -f "${cfg}" ]]; then
    step_skip "No user config yet (the ALSA default applies on first launch)"
    return 0
  fi
  if ! grep -q '^Local\.Audio\.Type = DeckLink$' "${cfg}"; then
    step_skip "Already set to something other than DeckLink"
    return 0
  fi
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }
  cp "${cfg}" "${cfg}.bak.$(date +%s)"
  sed -i 's|^Local\.Audio\.Type = DeckLink$|Local.Audio.Type = ALSA|' "${cfg}"
  step_ok "Switched DeckLink → ALSA (backup .bak.<timestamp> created)"
}

# snd-aloop is a black hole until something captures its other side, so the
# loopback needs bridging to the real default sink or monitoring is silent.
user_aloop_bridge() {
  if [[ "${SETUP_ALOOP_USER}" != "1" ]]; then
    step aloopbridge "PipeWire loopback bridge"; step_skip "Skipped (--no-aloop)"; return 0
  fi
  step aloopbridge "Configuring PipeWire loopback bridge…"
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }

  local bridge_dir="${HOME}/.config/pipewire/pipewire.conf.d"
  local bridge="${bridge_dir}/50-resolve-aloop-bridge.conf"
  mkdir -p "${bridge_dir}"
  if [[ ! -f "${bridge}" ]]; then
    cat > "${bridge}" <<'CONF'
# DaVinci Resolve aloop monitor bridge — managed by omarchy-resolve.
# Bridges snd-aloop's capture side to the system default sink so Resolve's
# monitor audio is audible while editing. Without this, Resolve renders fine
# but you hear nothing during playback. Remove this file + restart PipeWire
# to disable.
context.modules = [
  { name = libpipewire-module-loopback
    args = {
      node.description = "DaVinci Resolve aloop monitor bridge"
      capture.props = {
        node.name = "resolve-aloop-capture"
        target.object = "alsa_input.platform-snd_aloop.0.analog-stereo"
        node.passive = true
      }
      playback.props = {
        node.name = "resolve-aloop-playback"
        media.class = "Stream/Output/Audio"
      }
    }
  }
]
CONF
    log "  Wrote ${bridge}"
  else
    log "  ${bridge} already in place"
  fi

  # Wireplumber promotes whichever sink is RUNNING, and aloop is RUNNING
  # exactly while Resolve plays audio. Left alone it becomes the default sink
  # mid-session and the bridge feeds itself instead of reaching hardware.
  local wp_dir="${HOME}/.config/wireplumber/wireplumber.conf.d"
  local wp_rule="${wp_dir}/51-resolve-aloop-no-default.conf"
  mkdir -p "${wp_dir}"
  if [[ ! -f "${wp_rule}" ]]; then
    cat > "${wp_rule}" <<'CONF'
# DaVinci Resolve aloop — keep snd-aloop out of the default-sink rotation.
# Managed by omarchy-resolve. Without this, wireplumber promotes aloop to
# default whenever Resolve makes it RUNNING, and the bridge loops audio back
# into aloop instead of reaching real hardware. SPA-JSON rule format requires
# wireplumber 0.5+ (Omarchy ships 0.5.x). Setting both node.dont-fallback and
# node.disable-fallback covers minor key renames across the 0.5.x series.
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "alsa_output.platform-snd_aloop.0.analog-stereo" }
      { node.name = "alsa_input.platform-snd_aloop.0.analog-stereo" }
    ]
    actions = {
      update-props = {
        priority.session      = 0
        priority.driver       = 0
        node.dont-fallback    = true
        node.disable-fallback = true
      }
    }
  }
]
CONF
    log "  Wrote ${wp_rule}"
  else
    log "  ${wp_rule} already in place"
  fi

  # Wireplumber first, so its monitor reapplies the alsa rule when pipewire
  # republishes the aloop nodes.
  if systemctl --user is-active --quiet pipewire 2>/dev/null; then
    systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
    log "  Reloaded user wireplumber + PipeWire services"
  fi
  step_ok
}

# Resolve on Linux — free and Studio — has no AAC decoder, so phone and camera
# clips import silent. AAC Fix (lib/resolve_aac_fix.py) rewraps them to PCM
# from inside Resolve (Workspace › Scripts › Utility › AAC Fix) or from the
# terminal (resolve-aac-fix). One copy goes into Resolve's user Scripts folder
# and the CLI is a symlink to that copy, so it survives this plugin being
# removed or updated. Last in the user phase: it needs the DaVinciResolve tree
# and everything else is more important if the run stops early.
user_aac_fix() {
  step aacfix "Installing AAC Fix (Resolve script + CLI)…"
  if [[ "${SETUP_AAC_FIX}" != "1" ]]; then
    step_skip "Skipped (--no-aac-fix)"; return 0
  fi
  local src="${LIB_DIR}/resolve_aac_fix.py"
  if [[ ! -f "${src}" ]]; then
    step_warn "Bundled script missing at ${src} — nothing installed"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    step_warn "python3 not found — AAC Fix needs it (sudo pacman -S python), skipped"
    return 0
  fi
  local dir="${HOME}/.local/share/DaVinciResolve/Fusion/Scripts/Utility"
  local dest="${dir}/AAC Fix.py"
  local bindir="${HOME}/.local/bin"
  local link="${bindir}/resolve-aac-fix"
  local verb="Installed"
  [[ -f "${dest}" ]] && verb="Updated"

  run mkdir -p "${dir}" "${bindir}"
  run install -m 755 "${src}" "${dest}"
  run ln -sfn "${dest}" "${link}"
  [[ "${DRY_RUN}" == "1" ]] && { step_skip "dry run"; return 0; }

  if ! command -v ffprobe >/dev/null 2>&1; then
    step_warn "${verb}, but ffprobe is missing — install ffmpeg before using AAC Fix"
    return 0
  fi
  case ":${PATH}:" in
    *":${bindir}:"*) ;;
    *) log "  ${bindir} is not on your PATH — the resolve-aac-fix command needs it" ;;
  esac
  step_ok "${verb} — in Resolve: Workspace › Scripts › Utility › AAC Fix (restart Resolve first)"
}

do_install_user() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-aloop) SETUP_ALOOP_USER=0; shift ;;
      --no-hypr-rules) SETUP_HYPR_RULES=0; shift ;;
      --force-hypr-rules) FORCE_HYPR_RULES=1; shift ;;
      --no-aac-fix) SETUP_AAC_FIX=0; shift ;;
      -h|--help) install_user_usage; exit 0 ;;
      *) install_user_usage; err "Unknown option: $1" ;;
    esac
  done

  if is_root; then
    err "The user phase must NOT run as root — under sudo/pkexec \$HOME is root's and every file would land in /root"
  fi

  emit_phase user "Configuring your session"
  emit_progress 0
  user_desktop_entry
  emit_progress 20
  user_opacity_rule
  emit_progress 35
  user_hypr_rules
  emit_progress 55
  user_reload_hypr
  emit_progress 65
  user_fix_audio_config
  emit_progress 75
  user_aloop_bridge
  emit_progress 90
  user_aac_fix
  emit_progress 100
  log "User phase complete"
  emit_done 0
}
