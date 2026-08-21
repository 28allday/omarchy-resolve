#!/usr/bin/env bash
# Read-only health checks, emitted as a flat list the panel renders directly.
#
# Every check returns one of ok / warn / fail / info plus a human detail line,
# so the UI never has to re-derive a verdict. Nothing here needs root and
# nothing here writes.

CHECKS_JSON=""
check_add() { # <id> <label> <state> <detail>
  [[ -n "${CHECKS_JSON}" ]] && CHECKS_JSON+=","
  CHECKS_JSON+="{$(json_str id "$1"),$(json_str label "$2"),$(json_str state "$3"),$(json_str detail "$4")}"
}

DEBUG_LOG_DEFAULT="${HOME}/.local/share/DaVinciResolve/logs/ResolveDebug.txt"
ROLLING_LOG="/opt/resolve/logs/rollinglog.txt"

diag_install() {
  if [[ -x "${RESOLVE_PREFIX}/bin/resolve" ]]; then
    local ver edition when
    ver="$(stamp_field version)"; edition="$(stamp_field edition)"; when="$(stamp_field installed)"
    if [[ -n "${ver}" ]]; then
      check_add install "Resolve installed" ok "${edition:-Resolve} ${ver} — installed ${when%%T*}"
    else
      local docs; docs="$(installed_docs_version)"
      check_add install "Resolve installed" ok "Version ${docs:-unknown} (installed before this tool existed — no stamp file)"
    fi
  else
    check_add install "Resolve installed" fail "Nothing at ${RESOLVE_PREFIX}/bin/resolve"
  fi
}

diag_wrapper() {
  if [[ ! -x "${RESOLVE_WRAPPER}" ]]; then
    check_add wrapper "XWayland wrapper" fail "${RESOLVE_WRAPPER} missing — Resolve has no native Wayland support"
    return
  fi
  local desktop="${HOME}/.local/share/applications/davinci-resolve-wrapper.desktop"
  if [[ -f "${desktop}" ]] && grep -q "^Exec=${RESOLVE_WRAPPER}" "${desktop}"; then
    check_add wrapper "XWayland wrapper" ok "Wrapper installed and the user desktop entry points at it"
  elif [[ -f "${desktop}" ]]; then
    check_add wrapper "XWayland wrapper" warn "User desktop entry exists but its Exec does not use the wrapper"
  else
    check_add wrapper "XWayland wrapper" warn "Wrapper present, but no user desktop entry — a Resolve update can overwrite the system one"
  fi
}

# The rules moved upstream in 2026-07, widened to match Studio. Report which
# copy is actually in force rather than just "a rule exists somewhere".
diag_hypr() {
  local upstream="/usr/share/omarchy/default/hypr/apps/davinci-resolve.lua"
  local module="${HOME}/.config/hypr/davinci-resolve.lua"
  local main="${HOME}/.config/hypr/hyprland.lua"
  local has_upstream=0 has_local=0 required=0

  if [[ -r "${upstream}" ]] && grep -q 'fullscreen = true' "${upstream}" && grep -q 'stay_focused = false' "${upstream}"; then
    has_upstream=1
  fi
  [[ -f "${module}" ]] && has_local=1
  [[ -f "${main}" ]] && grep -q 'require("hypr.davinci-resolve")' "${main}" && required=1

  if [[ ${has_upstream} -eq 1 && ${has_local} -eq 1 ]]; then
    check_add hyprrules "Window rules" warn "Omarchy ships these rules now — your local ${module} is a redundant duplicate and can be removed"
  elif [[ ${has_upstream} -eq 1 ]]; then
    check_add hyprrules "Window rules" ok "Provided by Omarchy (matches Resolve and Resolve Studio)"
  elif [[ ${has_local} -eq 1 && ${required} -eq 1 ]]; then
    check_add hyprrules "Window rules" ok "Local rules installed and required from hyprland.lua"
  elif [[ ${has_local} -eq 1 ]]; then
    check_add hyprrules "Window rules" warn "${module} exists but hyprland.lua never require()s it — the rules are dead"
  else
    check_add hyprrules "Window rules" warn "No bar-overlap or dialog-focus rules found"
  fi

  local opaque=0
  [[ -r "${upstream}" ]] && grep -q 'opacity = "1 1"' "${upstream}" && opaque=1
  [[ ${opaque} -eq 0 && -f "${main}" ]] && grep -q 'resolve-full-opacity' "${main}" && opaque=1
  if [[ ${opaque} -eq 1 ]]; then
    check_add opacity "Full opacity" ok "Resolve is exempt from Omarchy's window translucency"
  else
    check_add opacity "Full opacity" warn "Resolve may be rendered translucent — wrong for colour-critical grading"
  fi
}

diag_audio() {
  local cfg="${HOME}/.local/share/DaVinciResolve/configs/config.dat"
  if [[ -f "${cfg}" ]]; then
    local backend; backend="$(grep -m1 '^Local\.Audio\.Type' "${cfg}" 2>/dev/null | sed 's/.*= //' || true)"
    if [[ "${backend}" == "DeckLink" ]]; then
      check_add audiobackend "Audio backend" fail "Set to DeckLink — Resolve aborts on launch without a Blackmagic card"
    else
      check_add audiobackend "Audio backend" ok "${backend:-unset}"
    fi
  else
    local template="${RESOLVE_PREFIX}/share/default-config.dat" tb=""
    [[ -f "${template}" ]] && tb="$(grep -m1 '^Local\.Audio\.Type' "${template}" 2>/dev/null | sed 's/.*= //' || true)"
    if [[ "${tb}" == "DeckLink" ]]; then
      check_add audiobackend "Audio backend" fail "No user config yet, and the system template still says DeckLink"
    else
      check_add audiobackend "Audio backend" ok "No user config yet; template default is ${tb:-unknown}"
    fi
  fi

  # The render-blocker. Without a card Resolve can fully own, its ALSA
  # enumeration loops and the encoder never spawns.
  local loaded=0 persisted=0 card=0
  lsmod 2>/dev/null | grep -E '^snd_aloop' >/dev/null && loaded=1
  [[ -f "${ALOOP_CONF}" ]] && grep -qx 'snd-aloop' "${ALOOP_CONF}" 2>/dev/null && persisted=1
  aplay -l 2>/dev/null | grep -i 'loopback' >/dev/null && card=1
  if [[ ${loaded} -eq 1 && ${persisted} -eq 1 && ${card} -eq 1 ]]; then
    check_add aloop "snd-aloop" ok "Loaded, visible to ALSA, and set to autoload at boot"
  elif [[ ${loaded} -eq 1 && ${persisted} -eq 0 ]]; then
    check_add aloop "snd-aloop" warn "Loaded now, but ${ALOOP_CONF} is missing so it will not survive a reboot"
  elif [[ ${loaded} -eq 0 ]]; then
    check_add aloop "snd-aloop" fail "Not loaded — renders can hang forever with no error in the log"
  else
    check_add aloop "snd-aloop" warn "Module loaded but no Loopback card is visible to ALSA"
  fi

  local bridge="${HOME}/.config/pipewire/pipewire.conf.d/50-resolve-aloop-bridge.conf"
  local wprule="${HOME}/.config/wireplumber/wireplumber.conf.d/51-resolve-aloop-no-default.conf"
  if [[ -f "${bridge}" && -f "${wprule}" ]]; then
    check_add aloopbridge "Monitor audio bridge" ok "PipeWire loopback bridge and Wireplumber default-sink exclusion both in place"
  elif [[ -f "${bridge}" ]]; then
    check_add aloopbridge "Monitor audio bridge" warn "Bridge present but no Wireplumber rule — aloop can steal the default sink mid-session and silence playback"
  else
    check_add aloopbridge "Monitor audio bridge" warn "No bridge — Resolve renders fine, but monitor audio goes nowhere during playback"
  fi
}

# The single most confusing Studio failure: activation cannot be written, and
# Resolve does not say so. Only meaningful once Resolve is installed.
diag_license() {
  local dir="${RESOLVE_PREFIX}/.license"
  if [[ ! -d "${dir}" ]]; then
    check_add license "Studio licence folder" warn "${dir} is missing — Studio activation will fail. Reinstall, or: sudo mkdir -p ${dir} && sudo chmod 7777 ${dir}"
    return
  fi
  if [[ -w "${dir}" ]]; then
    check_add license "Studio licence folder" ok "Writable — Studio can store its activation (not used by the free edition)"
  else
    check_add license "Studio licence folder" fail "${dir} is not writable by you, so Studio licensing will fail with no clear error. Fix: sudo chmod 7777 ${dir}"
  fi
}

diag_gpu() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    local driver name
    driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
    if [[ -n "${driver}" ]]; then
      check_add gpu "NVIDIA driver" ok "${name} — driver ${driver}"
    else
      check_add gpu "NVIDIA driver" warn "nvidia-smi present but returned nothing"
    fi
  else
    check_add gpu "NVIDIA driver" fail "nvidia-smi not found — this installer targets NVIDIA"
  fi

  if command -v ffmpeg >/dev/null 2>&1; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep h264_nvenc >/dev/null; then
      check_add nvenc "NVENC encoder" ok "h264_nvenc available (run the test to confirm it actually encodes)"
    else
      check_add nvenc "NVENC encoder" warn "ffmpeg has no h264_nvenc encoder"
    fi
  else
    check_add nvenc "NVENC encoder" info "ffmpeg not installed — cannot check"
  fi
}

# Resolve 21 on Linux ships its own ProRes RAW decoder (libs/libProResRAW.so)
# and loads the bundled "Standard" conversion plugin at startup. The ERROR it
# logs about /usr/local/lib/proresraw/plugins is only the *optional*
# third-party plugin directory being absent, which is the normal state.
diag_prores_raw() {
  if [[ -e "${RESOLVE_PREFIX}/libs/libProResRAW.so" ]]; then
    check_add proresraw "ProRes RAW" ok "Decoder present (libProResRAW.so). The startup log line about /usr/local/lib/proresraw/plugins is harmless — that directory is for optional third-party conversion plugins."
  else
    check_add proresraw "ProRes RAW" info "No libProResRAW.so in this build"
  fi
}

# Resolve logs a handful of ERROR lines on every clean startup. Counting those
# as problems trains you to ignore the count, so they are filtered out and only
# the remainder is reported.
BENIGN_LOG_ERRORS='unable to open default plug-in directory /usr/local/lib/proresraw/plugins|Error initializing ArriImageSdk|Failed to connect to panel socket|open /var/tmp/davinci_socket failed|RemoteStream\(\) - Access token is empty'

diag_logs() {
  if [[ ! -f "${DEBUG_LOG_DEFAULT}" ]]; then
    check_add logs "Debug log" info "No log yet at ${DEBUG_LOG_DEFAULT}"
    return
  fi
  local all real when
  all="$(tail -n 500 "${DEBUG_LOG_DEFAULT}" 2>/dev/null | grep -c '| ERROR |' || true)"
  real="$(tail -n 500 "${DEBUG_LOG_DEFAULT}" 2>/dev/null | grep '| ERROR |' |
          grep -vE "${BENIGN_LOG_ERRORS}" | grep -c '' || true)"
  when="$(date -r "${DEBUG_LOG_DEFAULT}" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
  local noise=$(( all - real ))
  if (( real > 0 )); then
    check_add logs "Debug log" warn "${real} error lines worth reading in the last 500 (last written ${when})"
  elif (( noise > 0 )); then
    check_add logs "Debug log" ok "Clean — ${noise} error lines, all known-harmless startup noise (last written ${when})"
  else
    check_add logs "Debug log" ok "No errors in the last 500 lines (last written ${when})"
  fi
}

diag_disk() {
  local free_gb
  free_gb=$(( $(df --output=avail -k /opt | tail -n1) / 1024 / 1024 ))
  if (( free_gb < 5 )); then
    check_add disk "Disk space" warn "${free_gb} GiB free on /opt — a reinstall needs about 10 GiB of scratch space"
  else
    check_add disk "Disk space" ok "${free_gb} GiB free on /opt"
  fi
}

do_diagnose() {
  CHECKS_JSON=""
  diag_install
  diag_wrapper
  diag_hypr
  diag_audio
  diag_license
  diag_gpu
  diag_prores_raw
  diag_logs
  diag_disk

  local running=0; pgrep -x resolve >/dev/null 2>&1 && running=1
  printf '{'
  printf '%s,' "$(json_bool running "${running}")"
  printf '%s,' "$(json_str debugLog "${DEBUG_LOG_DEFAULT}")"
  printf '%s,' "$(json_str rollingLog "${ROLLING_LOG}")"
  printf '%s'  "$(json_raw checks "[${CHECKS_JSON}]")"
  printf '}\n'
}

# --------------------------------------------------------------- codec probe
# What Resolve on Linux will and will not read. The limitation that actually
# bites is audio: the Linux build has no AAC decoder, so an ordinary
# camera/phone .mp4 or .mov imports with picture and silence, and nothing in
# the UI explains why. ProRes RAW, by contrast, IS supported — Resolve ships
# libProResRAW.so and loads its own conversion plugin.
do_probe() {
  local file="$1"
  [[ -f "${file}" ]] && { :; } || {
    printf '{%s,%s}\n' "$(json_str state fail)" "$(json_str detail "No such file: ${file}")"
    return 0
  }
  if ! command -v ffprobe >/dev/null 2>&1; then
    printf '{%s,%s}\n' "$(json_str state info)" "$(json_str detail "ffprobe not installed")"
    return 0
  fi

  local vcodec acodec
  vcodec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of default=noprint_wrappers=1:nokey=1 "${file}" 2>/dev/null | head -n1 || true)"
  acodec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
            -of default=noprint_wrappers=1:nokey=1 "${file}" 2>/dev/null | head -n1 || true)"

  if [[ -z "${vcodec}" && -z "${acodec}" ]]; then
    printf '{%s,%s}\n' "$(json_str state fail)" "$(json_str detail "ffprobe could not read this file")"
    return 0
  fi

  local summary="${vcodec:-no video} / ${acodec:-no audio}"
  local state=ok detail="${summary} — Resolve reads this."

  case "${acodec}" in
    aac|mp3|ac3|eac3|alac)
      state=warn
      detail="${summary} — Resolve on Linux has no ${acodec^^} decoder. The clip imports with picture and no sound. Remux the audio to PCM first:  ffmpeg -i in -c:v copy -c:a pcm_s16le out.mov"
      ;;
  esac

  case "${vcodec}" in
    h264|hevc)
      if [[ "${state}" == "ok" ]]; then
        state=info
        detail="${summary} — ${vcodec} decode on Linux needs Resolve Studio; the free edition cannot read it."
      fi
      ;;
    prores_raw)
      [[ "${state}" == "ok" ]] && detail="${summary} — ProRes RAW is supported (Resolve 20 and later)."
      ;;
  esac

  printf '{%s,%s,%s}\n' "$(json_str state "${state}")" "$(json_str detail "${detail}")" \
    "$(json_str file "$(basename "${file}")")"
}

# Rules out a driver problem before blaming Resolve.
do_nvenc_test() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    printf '{%s,%s}\n' "$(json_str state info)" "$(json_str detail "ffmpeg not installed")"
    return 0
  fi
  local out="${TMPDIR:-/tmp}/omarchy-resolve-nvenc-test.mp4" log
  log="$(ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=2 \
        -c:v h264_nvenc -y "${out}" 2>&1 || true)"
  if [[ -s "${out}" ]]; then
    rm -f "${out}" 2>/dev/null || true
    printf '{%s,%s}\n' "$(json_str state ok)" "$(json_str detail "NVENC encoded a 2-second test clip successfully")"
  else
    printf '{%s,%s}\n' "$(json_str state fail)" "$(json_str detail "${log:-NVENC produced no output}")"
  fi
}

do_logs() {
  local lines="${1:-200}" file="${DEBUG_LOG_DEFAULT}"
  [[ -f "${file}" ]] || { echo "No log at ${file}"; return 0; }
  tail -n "${lines}" "${file}"
}
