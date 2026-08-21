#!/usr/bin/env bash
# Preflight: everything the panel needs to decide what it can offer, and
# everything a terminal run needs to decide whether it can proceed.
#
# Runs entirely unprivileged and read-only. Nothing here may need root — the
# panel calls it on every open, and prompting for a password to draw a status
# card would be obnoxious.

# Parse "DaVinci_Resolve_Studio_21.0b2_Linux.zip" into edition + version.
zip_edition() { [[ "$(basename "$1")" == *_Studio_* ]] && echo "Studio" || echo "Free"; }
zip_version() {
  local base; base="$(basename "$1")"
  base="${base#DaVinci_Resolve_}"; base="${base#Studio_}"
  base="${base%_Linux.zip}"
  printf '%s' "${base}"
}

# Newest ZIP by mtime, matching what the original installer picked.
newest_zip() {
  local dir="$1" zips=()
  shopt -s nullglob
  zips=("${dir}"/DaVinci_Resolve*_Linux.zip)
  shopt -u nullglob
  [[ ${#zips[@]} -eq 0 ]] && return 0
  ls -1t "${zips[@]}" 2>/dev/null | head -n1
}

# Major version from the shipped docs — the only version string a stock
# install carries. Exact version comes from our own stamp file when present.
installed_docs_version() {
  local welcome="${RESOLVE_PREFIX}/docs/Welcome.txt"
  [[ -r "${welcome}" ]] || return 0
  grep -oE 'DaVinci Resolve [0-9]+(\.[0-9]+)*' "${welcome}" 2>/dev/null | head -n1 | sed 's/DaVinci Resolve //' || true
}

stamp_field() {
  [[ -r "${RESOLVE_STAMP}" ]] || return 0
  grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "${RESOLVE_STAMP}" 2>/dev/null |
    head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true
}

missing_packages() {
  local missing=() pkg
  for pkg in unzip patchelf libarchive xdg-user-dirs desktop-file-utils file \
             gtk-update-icon-cache libxcrypt-compat ffmpeg4.4 glu fuse2 rsync; do
    pacman -Qq "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  printf '%s\n' "${missing[@]:-}"
}

do_check() {
  local home user
  home="$(real_home)"; user="$(real_user)"
  local zip_dir="${home}/Downloads"

  local zip; zip="$(newest_zip "${zip_dir}" || true)"
  local zip_ver="" zip_ed=""
  if [[ -n "${zip}" ]]; then zip_ver="$(zip_version "${zip}")"; zip_ed="$(zip_edition "${zip}")"; fi

  local free_gb=0
  if [[ -d "${zip_dir}" ]]; then
    free_gb=$(( $(df --output=avail -k "${zip_dir}" | tail -n1) / 1024 / 1024 ))
  fi

  local installed=0; [[ -x "${RESOLVE_PREFIX}/bin/resolve" ]] && installed=1
  local stamp_ver stamp_zip stamp_date stamp_edition
  stamp_ver="$(stamp_field version)"; stamp_zip="$(stamp_field zip)"
  stamp_date="$(stamp_field installed)"; stamp_edition="$(stamp_field edition)"

  local docs_ver; docs_ver="$(installed_docs_version)"
  local running=0; pgrep -x resolve >/dev/null 2>&1 && running=1

  # An update is only claimed when both versions are known and differ —
  # never on a bare "you have a ZIP and an install", which would nag forever.
  local update=0
  [[ -n "${zip_ver}" && -n "${stamp_ver}" && "${zip_ver}" != "${stamp_ver}" ]] && update=1

  local gpu="unknown" driver=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    [[ -n "${driver}" ]] && gpu="nvidia"
  fi
  if [[ "${gpu}" == "unknown" ]] && command -v lspci >/dev/null 2>&1; then
    if lspci 2>/dev/null | grep -iE 'VGA|3D controller' >/dev/null; then
      lspci 2>/dev/null | grep -i nvidia >/dev/null && gpu="nvidia"
      [[ "${gpu}" == "unknown" ]] && lspci 2>/dev/null | grep -iE 'amd/ati|advanced micro' >/dev/null && gpu="amd"
      [[ "${gpu}" == "unknown" ]] && lspci 2>/dev/null | grep -i 'intel' >/dev/null && gpu="intel"
    fi
  fi

  local missing; missing="$(missing_packages | grep -v '^$' || true)"
  local missing_json="[]" first=1
  if [[ -n "${missing}" ]]; then
    missing_json="["
    while IFS= read -r pkg; do
      [[ -z "${pkg}" ]] && continue
      [[ ${first} -eq 1 ]] || missing_json+=","
      missing_json+="\"$(json_escape "${pkg}")\""; first=0
    done <<< "${missing}"
    missing_json+="]"
  fi

  # Every ZIP present, newest first, so the panel can offer a chooser rather
  # than silently deciding for the user the way the shell script had to.
  local zips_json="[]"
  shopt -s nullglob
  local all=("${zip_dir}"/DaVinci_Resolve*_Linux.zip)
  shopt -u nullglob
  if [[ ${#all[@]} -gt 0 ]]; then
    zips_json="["; first=1
    while IFS= read -r z; do
      [[ -z "${z}" ]] && continue
      [[ ${first} -eq 1 ]] || zips_json+=","
      zips_json+="{$(json_str path "${z}"),$(json_str name "$(basename "${z}")")"
      zips_json+=",$(json_str version "$(zip_version "${z}")")"
      zips_json+=",$(json_str edition "$(zip_edition "${z}")")"
      zips_json+=",$(json_raw sizeMb "$(( $(stat -c%s "${z}" 2>/dev/null || echo 0) / 1048576 ))")}"
      first=0
    done < <(ls -1t "${all[@]}" 2>/dev/null)
    zips_json+="]"
  fi

  printf '{'
  printf '%s,' "$(json_str engineVersion "${ENGINE_VERSION}")"
  printf '%s,' "$(json_str user "${user}")"
  printf '%s,' "$(json_str home "${home}")"
  printf '%s,' "$(json_str zipDir "${zip_dir}")"
  printf '%s,' "$(json_raw zips "${zips_json}")"
  printf '%s,' "$(json_str selectedZip "${zip}")"
  printf '%s,' "$(json_str zipVersion "${zip_ver}")"
  printf '%s,' "$(json_str zipEdition "${zip_ed}")"
  printf '%s,' "$(json_raw freeGb "${free_gb}")"
  printf '%s,' "$(json_raw needGb 10)"
  printf '%s,' "$(json_bool installed "${installed}")"
  printf '%s,' "$(json_bool running "${running}")"
  printf '%s,' "$(json_bool updateAvailable "${update}")"
  printf '%s,' "$(json_str installedVersion "${stamp_ver}")"
  printf '%s,' "$(json_str installedEdition "${stamp_edition}")"
  printf '%s,' "$(json_str installedZip "${stamp_zip}")"
  printf '%s,' "$(json_str installedDate "${stamp_date}")"
  printf '%s,' "$(json_str docsVersion "${docs_ver}")"
  printf '%s,' "$(json_str gpu "${gpu}")"
  printf '%s,' "$(json_str driverVersion "${driver}")"
  printf '%s,' "$(json_bool wrapper "$([[ -x ${RESOLVE_WRAPPER} ]] && echo 1 || echo 0)")"
  printf '%s'  "$(json_raw missingPackages "${missing_json}")"
  printf '}\n'
}
