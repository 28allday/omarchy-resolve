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
    # An install from before the multi-GPU rewrite left the wrapper under its
    # old NVIDIA-only name. Saying "missing" about a machine that plainly has
    # one is the kind of answer that sends people looking in the wrong place.
    if [[ -x "${RESOLVE_WRAPPER_LEGACY}" ]]; then
      check_add wrapper "XWayland wrapper" warn "Found the older ${RESOLVE_WRAPPER_LEGACY}, which has no GPU handling for AMD or Intel — re-run the install to replace it"
    else
      check_add wrapper "XWayland wrapper" fail "${RESOLVE_WRAPPER} missing — Resolve has no native Wayland support"
    fi
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

# Which card Resolve will compute on, and whether the stack behind it is
# actually there. "nvidia-smi not found" used to be the whole diagnosis, which
# reads identically on a machine with no NVIDIA card and on one whose driver
# simply is not installed — opposite problems, opposite fixes. Worse, on an AMD
# or Intel machine it was the only answer available, and it was always wrong.
diag_gpu() {
  resolve_compute_target || true
  local vendor="${COMPUTE_VENDOR:-none}" bdf="${COMPUTE_BDF}" gfx="${COMPUTE_GFX}"

  if [[ "${vendor}" == "none" ]]; then
    check_add gpu "Compute GPU" fail "No display adapter found in sysfs — Resolve has nothing to run on"
    check_add opencl "GPU compute stack" fail "No GPU, so no compute stack"
    return
  fi

  local name kind others detail
  name="$(gpu_name_at "${bdf}" || echo "${bdf}")"
  kind="$(resolve_gpu_is_discrete "${vendor}" "${bdf}" "${name}")"
  others="$(gpu_names_other_than "${vendor}")"
  detail="${name} at ${bdf} — ${kind}${gfx:+, ${gfx}}"
  [[ -n "${others}" ]] && detail+="; also present: ${others}"

  # An integrated part chosen while a discrete one sits in the machine means
  # the pick went wrong, and pinning to the wrong card is the single most
  # common cause of "OpenCL Context Manager failed to create context".
  if [[ "${kind}" == "integrated" && -n "${others}" ]]; then
    check_add gpu "Compute GPU" warn "${detail}. Resolve would use the integrated GPU — override with RESOLVE_GPU_BDF in ${RESOLVE_ENV_DIR}/wrapper.env if that is wrong"
  else
    check_add gpu "Compute GPU" ok "${detail}"
  fi

  # The stack itself: CUDA on NVIDIA, ROCm on AMD, NEO on Intel. On AMD and
  # Intel a missing runtime is fatal and silent — Resolve exits at startup with
  # "Unsupported GPU Processing Mode" and says nothing about why.
  local stack state
  stack="$(compute_stack_state "${vendor}" "${gfx}")"
  state="${stack%%|*}"
  check_add opencl "GPU compute stack" "${state}" "${stack#*|}"

  # A pin that has been lifted is worth saying out loud: the packages are still
  # right today, and the next routine pacman -Syu takes Resolve out.
  if [[ "${vendor}" == "amd" ]]; then
    if rocm_pin_in_pacman_conf; then
      check_add rocmpin "ROCm version pin" ok "IgnorePkg holds ROCm at ${ROCM_PIN_VERSION} in ${PACMAN_CONF}"
    else
      check_add rocmpin "ROCm version pin" warn "No IgnorePkg pin in ${PACMAN_CONF} — the next 'pacman -Syu' can pull ROCm forward and stop Resolve launching"
    fi
  fi

  # The launcher is where the GPU choice actually takes effect, so check what
  # it will do rather than trusting that the install wrote what we expected.
  # DRI_PRIME=1 is the specific value that must never appear: it means "the
  # other card", which flips OpenGL to the iGPU on exactly the machines this
  # is meant to fix.
  if [[ -r "${RESOLVE_WRAPPER}" ]]; then
    if grep -qE '^\s*export DRI_PRIME=1\s*$' "${RESOLVE_WRAPPER}"; then
      check_add gpupin "Launcher GPU pin" fail "${RESOLVE_WRAPPER} sets DRI_PRIME=1, which selects the OTHER card — reinstall to get the PCI-address form"
    elif grep -q 'resolve_gpu_pick' "${RESOLVE_WRAPPER}"; then
      check_add gpupin "Launcher GPU pin" ok "Launcher picks its GPU at run time with the same rules as this check"
    else
      check_add gpupin "Launcher GPU pin" warn "${RESOLVE_WRAPPER} predates GPU-aware launching — reinstall to refresh it"
    fi
  fi

  # A card swap after install: the packages and launcher were chosen for a
  # vendor that is no longer the one in the machine.
  local stamped; stamped="$(stamp_field computeVendor)"
  if [[ -n "${stamped}" && "${stamped}" != "${vendor}" ]]; then
    check_add gpuchange "GPU changed since install" warn "Installed for ${stamped}, now running ${vendor} — re-run the install so the compute stack and launcher match"
  fi
}

# Hardware encoding, asked per vendor. ffmpeg lists h264_nvenc whenever it was
# built with NVENC support, whether or not there is an NVIDIA card to run it
# on — so the old check cheerfully reported the encoder as available on AMD and
# Intel machines that had no such thing.
diag_encoder() {
  local vendor="${COMPUTE_VENDOR:-none}"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    check_add nvenc "Hardware encoder" info "ffmpeg not installed — cannot check"
    return
  fi
  local encoders; encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
  case "${vendor}" in
    nvidia)
      if printf '%s' "${encoders}" | grep -q h264_nvenc; then
        check_add nvenc "Hardware encoder" ok "NVENC (h264_nvenc) available — run the test to confirm it actually encodes"
      else
        check_add nvenc "Hardware encoder" warn "ffmpeg has no h264_nvenc encoder"
      fi ;;
    amd|intel)
      # VA-API is the shared path on both. Resolve's own renders do not go
      # through ffmpeg, but a working VA-API encoder is good evidence the GPU
      # is usable for media work at all, and it is what the AAC Fix and the
      # convert helper use.
      local node; node="$(resolve_render_node "${COMPUTE_BDF}" 2>/dev/null || true)"
      if printf '%s' "${encoders}" | grep -q h264_vaapi && [[ -n "${node}" ]]; then
        check_add nvenc "Hardware encoder" ok "VA-API (h264_vaapi) on ${node} — run the test to confirm it actually encodes"
      elif printf '%s' "${encoders}" | grep -q h264_vaapi; then
        check_add nvenc "Hardware encoder" warn "ffmpeg has h264_vaapi but the chosen GPU exposes no DRM render node to encode with"
      else
        check_add nvenc "Hardware encoder" warn "ffmpeg has no h264_vaapi encoder — install a VA-API capable ffmpeg for hardware transcode"
      fi ;;
    *)
      check_add nvenc "Hardware encoder" info "No supported GPU — hardware encoding does not apply" ;;
  esac
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

# Resolve on Linux cannot decode AAC at all, in either edition. The install
# puts the AAC Fix script where Resolve lists it; without it phone and camera
# clips import silent with nothing in the UI to say why.
diag_aacfix() {
  local user="${HOME}/.local/share/DaVinciResolve/Fusion/Scripts/Utility/AAC Fix.py"
  local system="${RESOLVE_PREFIX}/Fusion/Scripts/Utility/AAC Fix.py"
  local link="${HOME}/.local/bin/resolve-aac-fix"
  local where=""
  if [[ -f "${user}" ]]; then where="${user}"; elif [[ -f "${system}" ]]; then where="${system}"; fi
  if [[ -z "${where}" ]]; then
    check_add aacfix "AAC Fix" warn "Not installed — AAC clips (most phone/camera MP4s) import silent. Re-run the install's user phase."
  elif ! command -v ffprobe >/dev/null 2>&1; then
    check_add aacfix "AAC Fix" warn "Script installed but ffprobe is missing — install ffmpeg"
  elif [[ -x "${link}" ]]; then
    check_add aacfix "AAC Fix" ok "Workspace › Scripts › Utility › AAC Fix, and resolve-aac-fix on the command line"
  else
    check_add aacfix "AAC Fix" ok "Workspace › Scripts › Utility › AAC Fix (no resolve-aac-fix command on PATH)"
  fi
}

# Resolve logs a handful of ERROR lines on every clean startup. Counting those
# as problems trains you to ignore the count, so they are filtered out and only
# the remainder is reported.
# 'No Main Display GPU found' reads alarming but is an XWayland artifact: Resolve
# cannot match a monitor to a GPU through Xwayland, so it falls back to the only
# GPU it found — and the id it names is that GPU. The same log then shows
# IsMainDisplayGPU=yes, 'Compute API set to automatic, defaulting to CUDA' and
# CUDA initialising on the card, so nothing is actually wrong. Note that on a
# hybrid machine where Resolve sees more than one GPU this line could mean it
# picked the wrong one; the gpu and nvenc checks above report the card in use.
# 'SkipVersion' is simply a key that does not exist until an update is dismissed.
BENIGN_LOG_ERRORS='unable to open default plug-in directory /usr/local/lib/proresraw/plugins|Error initializing ArriImageSdk|Failed to connect to panel socket|open /var/tmp/davinci_socket failed|RemoteStream\(\) - Access token is empty|No Main Display GPU found and no monitors found to match|Failed to parse key \(SkipVersion\) from JsonObject'

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
  diag_encoder
  diag_aacfix
  diag_prores_raw
  diag_logs
  diag_disk

  # Resolve renames its main thread, so the process comm is "GUI Thread", not
  # "resolve" — pgrep -x never matched and this always reported "not running".
  # Match on the executable instead; pgrep -f would false-positive on any
  # command line that merely mentions the path (this script's own, for one).
  local running=0 _p
  for _p in /proc/[0-9]*; do
    if [[ "$(readlink -f "${_p}/exe" 2>/dev/null)" == "${RESOLVE_PREFIX}/bin/resolve" ]]; then
      running=1; break
    fi
  done
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
# Prove the hardware encoder actually encodes, rather than merely being listed.
# Keeps the nvenc-test name the panel calls, but tests whichever encoder this
# machine's GPU actually has: NVENC on NVIDIA, VA-API on AMD and Intel.
do_nvenc_test() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    printf '{%s,%s}\n' "$(json_str state info)" "$(json_str detail "ffmpeg not installed")"
    return 0
  fi
  resolve_compute_target || true
  local -a args=() ; local label="" node=""
  case "${COMPUTE_VENDOR:-none}" in
    nvidia) label="NVENC"; args=(-c:v h264_nvenc) ;;
    amd|intel)
      label="VA-API"
      # The render node of the card that was picked, not whichever one happens
      # to be renderD128 — on a hybrid machine those are routinely different,
      # and testing the wrong card answers a question nobody asked.
      node="$(resolve_render_node "${COMPUTE_BDF}" 2>/dev/null || true)"
      if [[ -z "${node}" ]]; then
        printf '{%s,%s}\n' "$(json_str state fail)" "$(json_str detail "The chosen GPU at ${COMPUTE_BDF} exposes no DRM render node — nothing to encode with")"
        return 0
      fi
      # shellcheck disable=SC2054  # "format=nv12,hwupload" is one ffmpeg filter
      # chain, not two array elements — the comma belongs to ffmpeg's syntax.
      args=(-vaapi_device "${node}" -vf format=nv12,hwupload -c:v h264_vaapi) ;;
    *)
      printf '{%s,%s}\n' "$(json_str state info)" "$(json_str detail "No supported GPU — nothing to test")"
      return 0 ;;
  esac

  # A fresh name every run, and cleaned up whichever way this ends. The old
  # fixed path was left behind on failure, and the next run — failing the same
  # way — found that leftover and called it a pass. A check meant to rule out a
  # driver problem reported all clear precisely when there was one.
  local out log rc=0
  out="$(mktemp -u "${TMPDIR:-/tmp}/omarchy-resolve-encode-XXXXXX.mp4")"
  rm -f "${out}" 2>/dev/null || true
  if log="$(ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=duration=2 \
            "${args[@]}" -y "${out}" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ "${rc}" -eq 0 && -s "${out}" ]]; then
    rm -f "${out}" 2>/dev/null || true
    printf '{%s,%s}\n' "$(json_str state ok)" "$(json_str detail "${label} encoded a 2-second test clip successfully")"
  else
    rm -f "${out}" 2>/dev/null || true
    printf '{%s,%s}\n' "$(json_str state fail)" "$(json_str detail "${log:-${label} produced no output (ffmpeg exit ${rc})}")"
  fi
}

# Everything the GPU logic decided, as JSON. Exists so a GPU question can be
# answered on a machine without opening the panel or reading the install log —
# which is how the three sibling installers' --scan flags were used, and the
# only way to check GPU handling on hardware this repo has never run on.
do_gpu_report() {
  resolve_compute_target || true
  local vendor bdf driver name kind gfx first=1 out="["
  while IFS='|' read -r vendor bdf driver name; do
    [[ -n "${vendor}" ]] || continue
    kind="$(resolve_gpu_is_discrete "${vendor}" "${bdf}" "${name}")"
    gfx=""
    [[ "${vendor}" == "amd" ]] && gfx="$(resolve_amd_gfx_target "${bdf}" 2>/dev/null || true)"
    [[ ${first} -eq 1 ]] || out+=","
    first=0
    out+="{$(json_str vendor "${vendor}"),$(json_str name "${name}"),$(json_str bdf "${bdf}")"
    out+=",$(json_str driver "${driver}"),$(json_str type "${kind}"),$(json_str gfx "${gfx}")"
    out+=",$(json_bool selected "$([[ ${bdf} == "${COMPUTE_BDF}" ]] && echo 1 || echo 0)")}"
  done < <(resolve_gpu_entries || true)
  out+="]"

  local stack; stack="$(compute_stack_state "${COMPUTE_VENDOR}" "${COMPUTE_GFX}")"
  printf '{'
  printf '%s,' "$(json_str computeVendor "${COMPUTE_VENDOR}")"
  printf '%s,' "$(json_str computeBdf "${COMPUTE_BDF}")"
  printf '%s,' "$(json_str computeGfx "${COMPUTE_GFX}")"
  printf '%s,' "$(json_str hsaOverride "$([[ ${COMPUTE_VENDOR} == amd && -n ${COMPUTE_GFX} ]] && resolve_hsa_override "${COMPUTE_GFX}" || true)")"
  printf '%s,' "$(json_str stackState "${stack%%|*}")"
  printf '%s,' "$(json_str stackDetail "${stack#*|}")"
  printf '%s'  "$(json_raw gpus "${out}")"
  printf '}\n'
}

do_logs() {
  local lines="${1:-200}" file="${DEBUG_LOG_DEFAULT}"
  [[ -f "${file}" ]] || { echo "No log at ${file}"; return 0; }
  tail -n "${lines}" "${file}"
}
