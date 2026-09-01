#!/usr/bin/env bash
# Shared helpers for the omarchy-resolve engine.
#
# Sourced by every lib/*.sh and by bin/omarchy-resolve. Nothing here executes
# work of its own — it provides logging, the machine-readable progress
# protocol the QML panel parses, JSON emission, and the privilege/identity
# resolution that lets the same code run three ways:
#
#   * from a terminal as a normal user, escalating with sudo
#   * as root under pkexec, launched by the shell plugin (no TTY, no sudo)
#   * as root under sudo, launched by the back-compat wrapper script
#
# The last two matter because pkexec resets the environment: HOME becomes
# root's, so anything writing to the user's home has to be told who the user
# actually is (PKEXEC_UID) or, better, be kept out of the root phase entirely.

# ---------------------------------------------------------------- output mode
# MACHINE=1 additionally emits @@-prefixed protocol lines on stdout for the
# panel to parse. Human lines are printed either way so a terminal run reads
# exactly like the original installer did.
MACHINE="${MACHINE:-0}"
DRY_RUN="${DRY_RUN:-0}"

log()  { echo -e "▶ $*"; }
warn() { echo -e "⚠️  $*" >&2; }
err()  { echo -e "❌ $*" >&2; emit_done 1; exit 1; }

# ------------------------------------------------------------ progress events
# Line protocol, one event per line, pipe-delimited so QML can split cheaply.
# Labels are free text and must not contain a newline; pipes are stripped.
#   @@PHASE|<id>|<label>
#   @@STEP|<id>|<state>|<label>     state = start|ok|warn|fail|skip
#   @@PROGRESS|<0-100>
#   @@FIELD|<key>|<value>           one-off facts (installed version, paths)
#   @@DONE|<exit code>
_ev() { [[ "${MACHINE}" == "1" ]] || return 0; echo "@@$1"; }
_clean() { printf '%s' "${1//|/ }" | tr -d '\n\r'; }

emit_phase()    { _ev "PHASE|$(_clean "$1")|$(_clean "$2")"; }
emit_step()     { _ev "STEP|$(_clean "$1")|$(_clean "$2")|$(_clean "$3")"; }
emit_progress() { _ev "PROGRESS|$1"; }
emit_field()    { _ev "FIELD|$(_clean "$1")|$(_clean "$2")"; }
emit_done()     { _ev "DONE|$1"; }

# step <id> <label> — announce a step and remember it so step_ok/warn/fail
# don't have to repeat themselves.
CURRENT_STEP=""
CURRENT_STEP_LABEL=""
step() {
  CURRENT_STEP="$1"; CURRENT_STEP_LABEL="$2"
  emit_step "$1" start "$2"
  log "$2"
}
step_ok()   { emit_step "${CURRENT_STEP}" ok   "${1:-${CURRENT_STEP_LABEL}}"; }
step_skip() { emit_step "${CURRENT_STEP}" skip "${1:-${CURRENT_STEP_LABEL}}"; [[ -n "${1:-}" ]] && log "  $1"; return 0; }
step_warn() { emit_step "${CURRENT_STEP}" warn "${1:-${CURRENT_STEP_LABEL}}"; warn "  ${1:-${CURRENT_STEP_LABEL}}"; }
step_fail() { emit_step "${CURRENT_STEP}" fail "${1:-${CURRENT_STEP_LABEL}}"; err "${1:-${CURRENT_STEP_LABEL}}"; }

# ------------------------------------------------------------------ dry run
# Wrap a state-changing command so --dry-run can print it instead of running
# it. Read-only probes are never wrapped; only writes go through run().
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "   would run: $*"
    return 0
  fi
  "$@"
}

# --------------------------------------------------------------------- GPUs
# Identity, classification and the pick live in lib/gpu.sh — one definition,
# shared with the launcher wrapper, which embeds that file verbatim. Sourced
# here so check, install and diagnose all answer "which card?" identically.
# ENGINE_LIB_DIR is how install-root.sh finds gpu.sh again when it embeds it
# into the wrapper; resolved here because BASH_SOURCE only names this file
# while this file is being sourced.
ENGINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gpu.sh
source "${ENGINE_LIB_DIR}/gpu.sh"

# Every GPU as "vendor|name", the shape the helpers below want. Reads sysfs
# through resolve_gpu_entries(), so "card present but driver missing" stays
# tellable from "no such card" — nvidia-smi cannot tell those apart, since it
# is absent in both cases. Hybrid machines really do have two: this is written
# on a desktop that reports an RTX 5060 Ti and a Raphael iGPU.
detect_gpus() {
  local vendor bdf driver name
  while IFS='|' read -r vendor bdf driver name; do
    [[ -n "${vendor}" ]] || continue
    printf '%s|%s\n' "${vendor}" "${name}"
  done < <(resolve_gpu_entries || true)
}

# Comma-separated names of every GPU whose vendor matches $1, or all of them
# when $1 is empty. Empty output means none matched.
gpu_names() {
  local want="${1:-}" vendor name out=""
  while IFS='|' read -r vendor name; do
    [[ -n "${vendor}" ]] || continue
    [[ -z "${want}" || "${vendor}" == "${want}" ]] || continue
    out+="${out:+, }${name}"
  done < <(detect_gpus)
  printf '%s' "${out}"
}

# Names of every GPU whose vendor is NOT $1.
gpu_names_other_than() {
  local skip="${1:-}" vendor name out=""
  while IFS='|' read -r vendor name; do
    [[ -n "${vendor}" ]] || continue
    [[ "${vendor}" != "${skip}" ]] || continue
    out+="${out:+, }${name}"
  done < <(detect_gpus)
  printf '%s' "${out}"
}

has_gpu_vendor() {
  local want="$1" vendor name
  while IFS='|' read -r vendor name; do
    [[ "${vendor}" == "${want}" ]] && return 0
  done < <(detect_gpus)
  return 1
}

# The card Resolve will compute on, as three globals the callers all want
# together. Cheap enough to call more than once, but every caller here needs
# all three, so they are set in one go.
#   COMPUTE_VENDOR  nvidia | amd | intel | other | none
#   COMPUTE_BDF     PCI address of that card, empty when there is none
#   COMPUTE_GFX     AMD gfx target when applicable, else empty
# shellcheck disable=SC2034  # read by the sibling lib/*.sh, not by this file
COMPUTE_VENDOR="" COMPUTE_BDF="" COMPUTE_GFX=""
resolve_compute_target() {
  local pick
  pick="$(resolve_gpu_pick 2>/dev/null || true)"
  if [[ -z "${pick}" ]]; then
    COMPUTE_VENDOR="none"; COMPUTE_BDF=""; COMPUTE_GFX=""
    return 1
  fi
  # shellcheck disable=SC2034  # all three are read by the sibling lib/*.sh
  read -r COMPUTE_VENDOR COMPUTE_BDF COMPUTE_GFX <<< "${pick}"
  COMPUTE_GFX="${COMPUTE_GFX:-}"
  return 0
}

# Human name of the card at a PCI address.
gpu_name_at() {
  local want="$1" vendor bdf driver name
  while IFS='|' read -r vendor bdf driver name; do
    [[ "${bdf}" == "${want}" ]] || continue
    printf '%s' "${name}"; return 0
  done < <(resolve_gpu_entries || true)
  return 1
}

# ------------------------------------------------------------------ privilege
is_root() { [[ "${EUID}" -eq 0 ]]; }

# Escalation for the terminal path. Under pkexec/sudo we are already root and
# must NOT call sudo again — a sudo call with no TTY and no cached credential
# hangs forever waiting on a password nobody can type.
as_root() {
  if is_root; then run "$@"; else run sudo "$@"; fi
}

# Who invoked us, seen through whatever escalated. pkexec exports PKEXEC_UID;
# sudo exports SUDO_UID. Falls back to the current user when neither is set.
real_uid() {
  if [[ -n "${PKEXEC_UID:-}" ]]; then echo "${PKEXEC_UID}"
  elif [[ -n "${SUDO_UID:-}" ]]; then echo "${SUDO_UID}"
  else id -u; fi
}
real_user() { getent passwd "$(real_uid)" | cut -d: -f1; }
real_home() { getent passwd "$(real_uid)" | cut -d: -f6; }

# ---------------------------------------------------------------------- JSON
# Minimal emitters — enough for the flat objects the panel consumes, without
# taking a dependency on jq being installed.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
json_str()  { printf '"%s":"%s"' "$(json_escape "$1")" "$(json_escape "$2")"; }
json_raw()  { printf '"%s":%s' "$(json_escape "$1")" "$2"; }
json_bool() { local v=false; [[ "$2" == "1" || "$2" == "true" ]] && v=true; printf '"%s":%s' "$(json_escape "$1")" "$v"; }

# ------------------------------------------------------------------ constants
# Consumed by the sibling lib/*.sh files, not by this one, so shellcheck
# cannot see the uses from here.
# shellcheck disable=SC2034
{
  RESOLVE_PREFIX="/opt/resolve"
  RESOLVE_WRAPPER="/usr/local/bin/resolve-omarchy"
  # The wrapper used to be named for the only GPU this installer handled. It
  # now handles three, so the name moved — but an install made before that is
  # still out there with the old one, and uninstall has to be able to find it.
  RESOLVE_WRAPPER_LEGACY="/usr/local/bin/resolve-nvidia-open"
  RESOLVE_SHIM="/usr/bin/davinci-resolve"
  RESOLVE_STAMP="/opt/resolve/.omarchy-resolve.json"
  RESOLVE_ENV_DIR="/etc/omarchy-resolve"
  ALOOP_CONF="/etc/modules-load.d/snd-aloop.conf"

  # The AMD compute stack, pinned. ROCm 7.2.0 broke Resolve on every AMD GPU
  # (clCreateContext fails outright, or hangs on the Color page); 7.1.1 is the
  # last release confirmed working everywhere, and all six packages are still
  # live on the Arch Linux Archive. See the ROCm section of NOTES.md for why
  # the pin is still the default even though AMD fixed the crash in 7.2.1.
  ROCM_PIN_VERSION="7.1.1"
  ROCM_PIN_PACKAGES=(rocm-core rocm-device-libs rocm-llvm rocm-opencl-runtime comgr)
  SPIRV_PIN_VERSION="21.1.3"
  PACMAN_CONF="/etc/pacman.conf"
  # Marker written above the IgnorePkg line we add, so uninstall can tell our
  # pin from one the user put there themselves and only remove ours.
  ROCM_PIN_MARKER="# omarchy-resolve: ROCm pinned for DaVinci Resolve"

  ENGINE_VERSION="0.3.0"
}
