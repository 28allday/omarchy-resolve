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
# Every display-class PCI device, one per line as "vendor|name". lspci sees the
# hardware whether or not a driver is loaded, which is what makes "card present
# but driver missing" tellable from "no such card" — nvidia-smi cannot, since
# it is absent in both cases. Hybrid machines really do have two: this is
# written on a Ryzen laptop that reports an RTX 5060 Ti and a Raphael iGPU.
detect_gpus() {
  command -v lspci >/dev/null 2>&1 || return 0
  lspci -mm 2>/dev/null | awk -F'"' '
    $2 ~ /^(VGA compatible controller|3D controller|Display controller)$/ {
      vendor = $4; name = $6; v = "other"
      if (vendor ~ /NVIDIA/)                              v = "nvidia"
      else if (vendor ~ /Advanced Micro Devices|AMD|ATI/) v = "amd"
      else if (vendor ~ /Intel/)                          v = "intel"
      print v "|" name
    }'
}

# Comma-separated names of every GPU whose vendor matches $1, or all of them
# when $1 is empty. Empty output means none matched.
gpu_names() {
  local want="${1:-}" line vendor name out=""
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
  RESOLVE_WRAPPER="/usr/local/bin/resolve-nvidia-open"
  RESOLVE_SHIM="/usr/bin/davinci-resolve"
  RESOLVE_STAMP="/opt/resolve/.omarchy-resolve.json"
  ALOOP_CONF="/etc/modules-load.d/snd-aloop.conf"
  ENGINE_VERSION="0.2.0"
}
