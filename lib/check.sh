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

# Compare two Resolve version strings; prints newer | older | same, meaning
# "$1 is <relation> than $2". Versions look like 20.4.1, 21.0, 21.0b2 — a
# trailing b<N> marks a beta, which is OLDER than the same base release, and
# `sort -V` gets that backwards on its own.
version_relation() {
  local a="$1" b="$2"
  [[ "${a}" == "${b}" ]] && { echo same; return; }

  local abase="${a}" apre="" bbase="${b}" bpre=""
  [[ "${a}" =~ ^(.*[0-9])b([0-9]+)$ ]] && { abase="${BASH_REMATCH[1]}"; apre="${BASH_REMATCH[2]}"; }
  [[ "${b}" =~ ^(.*[0-9])b([0-9]+)$ ]] && { bbase="${BASH_REMATCH[1]}"; bpre="${BASH_REMATCH[2]}"; }

  if [[ "${abase}" != "${bbase}" ]]; then
    local first
    first="$(printf '%s\n%s\n' "${abase}" "${bbase}" | sort -V | head -n1)"
    [[ "${first}" == "${abase}" ]] && echo older || echo newer
    return
  fi
  # Same base version: a final release beats a beta of it.
  [[ -z "${apre}" && -n "${bpre}" ]] && { echo newer; return; }
  [[ -n "${apre}" && -z "${bpre}" ]] && { echo older; return; }
  (( apre > bpre )) && echo newer || echo older
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

# Packages the install needs regardless of what card is in the machine. Keep
# in step with root_install_packages() in lib/install-root.sh.
BASE_PACKAGES=(unzip patchelf libarchive xdg-user-dirs desktop-file-utils file
               gtk-update-icon-cache libxcrypt-compat ffmpeg glu fuse2 rsync)

# The compute stack for one vendor. Resolve does all its work on the GPU, so
# on AMD and Intel these are not optional extras — without them Resolve sees no
# OpenCL device and dies on first launch with "Unsupported GPU Processing
# Mode". NVIDIA needs nothing here: CUDA comes with the driver, which Omarchy
# installs itself, and this installer has no business second-guessing it.
# Keep in step with root_install_gpu_stack() in lib/install-root.sh.
gpu_stack_packages() {
  case "$1" in
    amd)   printf '%s\n' ocl-icd clinfo rocminfo rocm-smi-lib ;;
    intel) printf '%s\n' ocl-icd clinfo intel-compute-runtime level-zero-loader \
                          vulkan-intel intel-media-driver ;;
    *)     : ;;
  esac
}

missing_packages() {
  local missing=() pkg
  for pkg in "${BASE_PACKAGES[@]}" $(gpu_stack_packages "${1:-}"); do
    pacman -Qq "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  printf '%s\n' "${missing[@]:-}"
}

# Is the pinned ROCm stack installed at the versions that work with Resolve?
# Echoes ok | drift | absent, and on drift or absent says what it found.
rocm_pin_state() {
  local pkg ver missing=() wrong=()
  for pkg in "${ROCM_PIN_PACKAGES[@]}"; do
    ver="$(pacman -Q "${pkg}" 2>/dev/null | awk '{print $2}')"
    if [[ -z "${ver}" ]]; then missing+=("${pkg}")
    elif [[ "${ver}" != *"${ROCM_PIN_VERSION}"* ]]; then wrong+=("${pkg} ${ver}")
    fi
  done
  if [[ ${#missing[@]} -eq ${#ROCM_PIN_PACKAGES[@]} ]]; then echo "absent|not installed"; return; fi
  if [[ ${#missing[@]} -gt 0 ]]; then echo "drift|missing ${missing[*]}"; return; fi
  if [[ ${#wrong[@]} -gt 0 ]]; then echo "drift|${wrong[*]} (expected ${ROCM_PIN_VERSION})"; return; fi
  echo "ok|${ROCM_PIN_VERSION}"
}

rocm_pin_in_pacman_conf() {
  grep -qE '^IgnorePkg.*rocm-core' "${PACMAN_CONF}" 2>/dev/null
}

# Can Resolve actually compute on this machine? Echoes "state|detail", where
# state is ok | warn | fail. Read-only and unprivileged — the panel calls it on
# every open.
compute_stack_state() {
  local vendor="$1" gfx="$2"
  local platforms=""
  command -v clinfo >/dev/null 2>&1 && platforms="$(clinfo -l 2>/dev/null || true)"

  case "${vendor}" in
    nvidia)
      if command -v nvidia-smi >/dev/null 2>&1 &&
         nvidia-smi --query-gpu=driver_version --format=csv,noheader >/dev/null 2>&1; then
        echo "ok|CUDA via the NVIDIA driver"
      else
        echo "fail|NVIDIA card present but the driver is not installed — Resolve has nothing to compute on"
      fi ;;
    amd)
      local pin; pin="$(rocm_pin_state)"
      local pin_state="${pin%%|*}" pin_detail="${pin#*|}"
      if [[ "${pin_state}" == "absent" ]]; then
        echo "fail|No ROCm OpenCL runtime — Resolve will fail with Unsupported GPU Processing Mode"
      elif [[ "${pin_state}" == "drift" ]]; then
        echo "warn|ROCm present but not the pinned ${ROCM_PIN_VERSION} stack: ${pin_detail}"
      elif [[ -n "${platforms}" ]] && ! printf '%s' "${platforms}" | grep -qiE 'AMD|gfx|Radeon'; then
        echo "warn|ROCm ${ROCM_PIN_VERSION} installed but clinfo sees no AMD platform"
      elif [[ -n "${gfx}" ]] && [[ -z "$(resolve_hsa_override "${gfx}")" ]]; then
        echo "warn|ROCm ${ROCM_PIN_VERSION} installed, but ${gfx} has no supported HSA target — this card is too old for ROCm 7"
      else
        echo "ok|ROCm ${ROCM_PIN_VERSION}${gfx:+ on ${gfx}}"
      fi ;;
    intel)
      if ! pacman -Qq intel-compute-runtime >/dev/null 2>&1; then
        echo "fail|No Intel compute runtime — Resolve will fail with Unsupported GPU Processing Mode"
      elif [[ -n "${platforms}" ]] && ! printf '%s' "${platforms}" | grep -qi 'Intel'; then
        echo "warn|intel-compute-runtime installed but clinfo sees no Intel platform"
      else
        echo "ok|Intel NEO OpenCL (Blackmagic does not officially support Intel — treat as experimental)"
      fi ;;
    none)
      echo "fail|No display adapter detected" ;;
    *)
      echo "fail|Unrecognised GPU vendor — Resolve needs an NVIDIA, AMD or Intel card" ;;
  esac
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

  # How the ZIP that would be installed compares to what is installed now.
  # "unknown" when either version is unavailable — an install predating this
  # tool has no stamp file, and guessing from the docs' major version only
  # ("21") would be worse than admitting we do not know.
  local relation="unknown"
  if [[ -n "${zip_ver}" && -n "${stamp_ver}" ]]; then
    relation="$(version_relation "${zip_ver}" "${stamp_ver}")"
  elif [[ -n "${zip_ver}" && -n "${docs_ver}" ]]; then
    # No stamp, but Resolve's own docs carry the major version. That is enough
    # to spot a whole new major release; within one major it stays unknown
    # rather than guessing.
    local zip_major="${zip_ver%%.*}" docs_major="${docs_ver%%.*}"
    if [[ "${zip_major}" =~ ^[0-9]+$ && "${docs_major}" =~ ^[0-9]+$ ]]; then
      if (( zip_major > docs_major )); then relation="newer"
      elif (( zip_major < docs_major )); then relation="older"
      fi
    fi
  fi
  # Only a genuinely newer build is an update. A ZIP that merely differs — a
  # re-downloaded older build, say — must not be advertised as one.
  local update=0
  [[ "${relation}" == "newer" ]] && update=1

  # `gpus` carries the whole picture — on a hybrid machine that is more than
  # one card, each with the two facts that decide everything downstream: its
  # PCI address, and whether it is discrete. `gpu` remains the single vendor
  # Resolve will compute on, which is now a considered pick rather than "the
  # first card of the most-preferred vendor".
  local driver=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  fi

  resolve_compute_target || true
  local gpu="${COMPUTE_VENDOR:-none}" compute_bdf="${COMPUTE_BDF}" compute_gfx="${COMPUTE_GFX}"
  local compute_name=""
  [[ -n "${compute_bdf}" ]] && compute_name="$(gpu_name_at "${compute_bdf}" || true)"

  local gpus_json="[]" vendor bdf gdriver name kind first=1
  while IFS='|' read -r vendor bdf gdriver name; do
    [[ -n "${vendor}" ]] || continue
    kind="$(resolve_gpu_is_discrete "${vendor}" "${bdf}" "${name}")"
    if [[ ${first} -eq 1 ]]; then gpus_json="["; first=0; else gpus_json+=","; fi
    gpus_json+="{$(json_str vendor "${vendor}"),$(json_str name "${name}")"
    gpus_json+=",$(json_str bdf "${bdf}"),$(json_str driver "${gdriver}")"
    gpus_json+=",$(json_str type "${kind}")"
    gpus_json+=",$(json_str gfx "$([[ ${vendor} == amd ]] && resolve_amd_gfx_target "${bdf}" 2>/dev/null || true)")"
    gpus_json+=",$(json_bool selected "$([[ ${bdf} == "${compute_bdf}" ]] && echo 1 || echo 0)")}"
  done < <(resolve_gpu_entries || true)
  [[ ${first} -eq 1 ]] || gpus_json+="]"

  # What Resolve will compute with, and whether that stack is actually ready.
  # This is the check that decides whether an install can succeed at all: on
  # AMD and Intel a missing runtime means Resolve dies on first launch with
  # "Unsupported GPU Processing Mode" and no other explanation.
  local api=""
  case "${gpu}" in
    nvidia) api="CUDA" ;;
    amd)    api="OpenCL (ROCm)" ;;
    intel)  api="OpenCL (Intel NEO)" ;;
  esac
  local stack; stack="$(compute_stack_state "${gpu}" "${compute_gfx}")"
  local stack_state="${stack%%|*}" stack_detail="${stack#*|}"
  local hsa=""; [[ "${gpu}" == "amd" && -n "${compute_gfx}" ]] && hsa="$(resolve_hsa_override "${compute_gfx}")"
  local rocm_pinned=0; rocm_pin_in_pacman_conf && rocm_pinned=1

  local missing; missing="$(missing_packages "${gpu}" | grep -v '^$' || true)"
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
  printf '%s,' "$(json_str zipRelation "${relation}")"
  printf '%s,' "$(json_str installedVersion "${stamp_ver}")"
  printf '%s,' "$(json_str installedEdition "${stamp_edition}")"
  printf '%s,' "$(json_str installedZip "${stamp_zip}")"
  printf '%s,' "$(json_str installedDate "${stamp_date}")"
  printf '%s,' "$(json_str docsVersion "${docs_ver}")"
  printf '%s,' "$(json_str gpu "${gpu}")"
  printf '%s,' "$(json_str driverVersion "${driver}")"
  printf '%s,' "$(json_raw gpus "${gpus_json}")"
  printf '%s,' "$(json_str computeBdf "${compute_bdf}")"
  printf '%s,' "$(json_str computeName "${compute_name}")"
  printf '%s,' "$(json_str computeGfx "${compute_gfx}")"
  printf '%s,' "$(json_str computeApi "${api}")"
  printf '%s,' "$(json_str stackState "${stack_state}")"
  printf '%s,' "$(json_str stackDetail "${stack_detail}")"
  printf '%s,' "$(json_str hsaOverride "${hsa}")"
  printf '%s,' "$(json_bool rocmPinned "${rocm_pinned}")"
  printf '%s,' "$(json_bool wrapper "$([[ -x ${RESOLVE_WRAPPER} ]] && echo 1 || echo 0)")"
  printf '%s'  "$(json_raw missingPackages "${missing_json}")"
  printf '}\n'
}
