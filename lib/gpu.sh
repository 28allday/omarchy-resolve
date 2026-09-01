#!/usr/bin/env bash
# GPU identity — the one definition, used in four places.
#
# Sourced by lib/common.sh (so check, install and diagnose all agree), and
# written verbatim into the launcher wrapper by root_install_wrapper() so the
# running launcher picks the same card the installer said it would. The
# installer reporting a 9060 XT while the launcher pins the iGPU is precisely
# the failure nobody can diagnose from the outside.
#
# Because it is embedded, this file must stay self-contained: no logging, no
# run(), no engine constants, nothing that assumes the rest of lib/ exists. It
# must also survive `set -euo pipefail`, which the wrapper sets.
#
# Everything here reads the kernel — sysfs, and amdkfd's own topology — rather
# than lspci product strings. A marketing name does not say whether a part is
# on the CPU package, and it does not say what gfx target the compute stack
# will see. Classifying by name is what put an RTX 5060 Ti behind a Raphael
# iGPU on the machine this was written on: "AMD/ATI Raphael" matches none of
# the usual iGPU keywords, so it was called discrete and won the pick.

# ---------------------------------------------------------------- enumeration
# Every GPU as "vendor|bdf|driver|name", sorted by PCI address.
#   vendor  nvidia | amd | intel | other   (from the PCI vendor ID, not a name)
#   bdf     full PCI address with domain, e.g. 0000:01:00.0
#   driver  bound kernel driver: nvidia, amdgpu, xe, i915, or empty
#   name    lspci's product string when lspci is installed, else the PCI ID
#
# Sysfs is the source rather than lspci because it carries the address and the
# bound driver, and exists whether or not pciutils is installed. lspci is used
# only to put a human name on what sysfs already found.
resolve_gpu_entries() {
  local d vid bdf driver name vendor
  local -a entries=()
  for d in /sys/class/drm/card[0-9]*; do
    # Connector subdirectories (card0-DP-2) are not devices.
    [[ "${d}" =~ /card[0-9]+$ ]] || continue
    [[ -e "${d}/device/vendor" ]] || continue
    vid="$(cat "${d}/device/vendor" 2>/dev/null || echo)"
    bdf="$(basename "$(readlink -f "${d}/device")")"
    driver="$(awk -F= '/^DRIVER=/{print $2}' "${d}/device/uevent" 2>/dev/null || echo)"
    case "${vid}" in
      0x10de) vendor=nvidia ;;
      0x1002|0x1022) vendor=amd ;;
      0x8086) vendor=intel ;;
      *)      vendor=other ;;
    esac
    name=""
    if command -v lspci >/dev/null 2>&1; then
      name="$(lspci -mm -s "${bdf}" 2>/dev/null | awk -F'"' '{print $6}')"
    fi
    [[ -n "${name}" ]] || name="${bdf}"
    entries+=("${vendor}|${bdf}|${driver}|${name}")
  done
  ((${#entries[@]})) || return 1
  printf '%s\n' "${entries[@]}" | sort -t'|' -k2,2
}

# ------------------------------------------------------------ AMD gfx targets
# Map an amdkfd topology location_id to a PCI address; the field packs bus,
# device and function exactly as PCI config space does.
resolve_kfd_location_to_pci() {
  printf '%04x:%02x:%02x.%d' 0 $(( ($1 >> 8) & 0xff )) $(( ($1 >> 3) & 0x1f )) $(( $1 & 0x7 ))
}

# gfx target for an AMD GPU, straight from the amdkfd topology the compute
# stack itself reads: "gfx1200", "gfx1036". Empty when the kernel reports none
# (amdgpu not loaded, or a display-only part with no compute node).
#
# gfx_target_version is packed decimal — 100306 → 10.3.6 → gfx1036, 120000 →
# gfx1200. ROCm keys off the same number, so this cannot disagree with what
# Resolve will be handed.
resolve_amd_gfx_target() {
  local want="${1#0000:}" node props loc ver maj min stp
  [[ -d /sys/class/kfd/kfd/topology/nodes ]] || return 1
  for node in /sys/class/kfd/kfd/topology/nodes/*/; do
    props="${node}properties"
    [[ -r "${props}" ]] || continue
    # simd_count 0 marks the CPU node, which has no gfx target.
    [[ "$(awk '/^simd_count /{print $2}' "${props}")" == "0" ]] && continue
    loc="$(awk '/^location_id /{print $2}' "${props}")"
    [[ -n "${loc}" ]] || continue
    [[ "$(resolve_kfd_location_to_pci "${loc}")" == "0000:${want}" ]] || continue
    ver="$(awk '/^gfx_target_version /{print $2}' "${props}")"
    [[ -n "${ver}" && "${ver}" != "0" ]] || return 1
    maj=$(( ver / 10000 )); min=$(( (ver / 100) % 100 )); stp=$(( ver % 100 ))
    printf 'gfx%d%x%x\n' "${maj}" "${min}" "${stp}"
    return 0
  done
  return 1
}

# HSA_OVERRIDE_GFX_VERSION for a gfx target. Keyed on the target rather than a
# product name, so a card this file has never heard of still lands correctly as
# long as the kernel reports its target.
#
# The natively-supported targets get a value too, not an empty string: on
# RDNA4 + ROCm 7.1.1, Resolve's clCreateContext was found to need
# HSA_OVERRIDE_GFX_VERSION set explicitly even though gfx1200 is supported out
# of the box. Setting it to its own value is a no-op for ROCm and a fix for
# Resolve.
resolve_hsa_override() {
  case "$1" in
    gfx1201) echo "12.0.1" ;;
    gfx1200) echo "12.0.0" ;;
    gfx1101) echo "11.0.1" ;;
    gfx1100) echo "11.0.0" ;;
    gfx1030) echo "10.3.0" ;;
    # RDNA3 small dies spoof as gfx1100.
    gfx1102|gfx1103) echo "11.0.0" ;;
    # RDNA2 small dies, and the RDNA2-era APUs, spoof as gfx1030.
    gfx1031|gfx1032|gfx1033|gfx1034|gfx1035|gfx1036) echo "10.3.0" ;;
    # RDNA1 (gfx101x) has no working spoof — ROCm dropped it and there is no
    # nearby supported target. Say nothing rather than invent one; the OpenCL
    # check is what reports the card as unusable.
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------- discrete or not
# Echoes "discrete" or "integrated". Layered on purpose: every test above the
# last is a fact the kernel reports, and the name guess is only reached when
# every structural signal is unavailable.
resolve_gpu_is_discrete() {
  local vendor="$1" bdf="$2" name="${3:-}"
  local dev="/sys/bus/pci/devices/${bdf}"

  case "${vendor}" in
    nvidia)
      # Every NVIDIA part this installer can meet is discrete.
      echo discrete; return 0 ;;
    intel)
      # Intel integrated graphics is part of the SoC and always sits on PCI
      # bus 00 (conventionally 0000:00:02.0); anything on a real bus came out
      # of a slot. True for Intel specifically — NOT a general rule, as AMD's
      # Raphael iGPU sits at 05:00.0.
      [[ "${bdf}" =~ ^0000:00: ]] && { echo integrated; return 0; }
      echo discrete; return 0 ;;
  esac

  # 1. amdgpu publishes a VRAM vendor (gddr6, hbm2e, …) only for parts with
  #    their own memory. An APU carving out of system RAM has no such file.
  if [[ -r "${dev}/mem_info_vram_vendor" ]]; then echo discrete; return 0; fi
  # 2. Discrete boards expose a hwmon power cap; integrated graphics are
  #    governed by the CPU package and do not.
  if compgen -G "${dev}/hwmon/hwmon*/power1_cap" >/dev/null 2>&1; then
    echo discrete; return 0
  fi
  # 3. Known APU gfx targets, read from the kernel rather than guessed:
  #    gfx90c Cezanne, gfx1035 Rembrandt, gfx1036 Raphael/Mendocino,
  #    gfx1103 Phoenix/Hawk Point, gfx115x Strix.
  local gfx; gfx="$(resolve_amd_gfx_target "${bdf}" 2>/dev/null || true)"
  case "${gfx}" in
    gfx90c|gfx1035|gfx1036|gfx1103|gfx115*) echo integrated; return 0 ;;
    gfx*)                                   echo discrete;   return 0 ;;
  esac
  # 4. amdgpu loaded but nothing above resolved: a small VRAM total is an APU
  #    carve-out. 4 GiB sits below any modern discrete board.
  if [[ -r "${dev}/mem_info_vram_total" ]]; then
    local vram; vram="$(cat "${dev}/mem_info_vram_total" 2>/dev/null || echo 0)"
    if [[ "${vram}" =~ ^[0-9]+$ ]] && (( vram > 0 && vram < 4294967296 )); then
      echo integrated; return 0
    fi
    echo discrete; return 0
  fi
  # 5. Last resort: the marketing name.
  if printf '%s' "${name}" | grep -qiE "Radeon.*(Graphics|Vega|Renoir|Cezanne|Barcelo|Rembrandt|Phoenix|Hawk|Strix|Raphael|Mendocino)|Ryzen.*Radeon|Integrated"; then
    echo integrated
  else
    echo discrete
  fi
}

# ------------------------------------------------------------------ the pick
# Which GPU should Resolve compute on? Echoes "vendor bdf gfx", where gfx is
# the AMD gfx target when there is one and empty otherwise.
#
# Order is what Resolve can actually use, best first: CUDA on an NVIDIA board,
# then ROCm on a discrete Radeon, then a discrete Arc, and only then the
# integrated parts — which are a fallback, not a target.
#
# RESOLVE_GPU_BDF overrides the choice entirely; it is how you settle an
# argument with the picker without editing anything it generated.
resolve_gpu_pick() {
  local -a entries=()
  local e vendor bdf driver name kind gfx
  mapfile -t entries < <(resolve_gpu_entries) || return 1
  ((${#entries[@]})) || return 1

  if [[ -n "${RESOLVE_GPU_BDF:-}" ]]; then
    for e in "${entries[@]}"; do
      IFS='|' read -r vendor bdf driver name <<< "${e}"
      if [[ "${bdf}" == "${RESOLVE_GPU_BDF}" ]]; then
        gfx=""
        [[ "${vendor}" == "amd" ]] && gfx="$(resolve_amd_gfx_target "${bdf}" 2>/dev/null || true)"
        echo "${vendor} ${bdf} ${gfx}"; return 0
      fi
    done
    # An override naming a card that is not here is a mistake worth honouring
    # loudly rather than silently ignoring: pin it and let the OpenCL check
    # report what happened.
    echo "other ${RESOLVE_GPU_BDF} "; return 0
  fi

  # Preference table, most capable first. A discrete card of a later vendor
  # still beats an integrated one of an earlier vendor, which is why this is a
  # flat table rather than a vendor loop with a kind loop inside it.
  local want_vendor want_kind
  local -a prefs=(nvidia:discrete amd:discrete intel:discrete amd:integrated intel:integrated)
  local pref
  for pref in "${prefs[@]}"; do
    want_vendor="${pref%%:*}"; want_kind="${pref##*:}"
    for e in "${entries[@]}"; do
      IFS='|' read -r vendor bdf driver name <<< "${e}"
      [[ "${vendor}" == "${want_vendor}" ]] || continue
      kind="$(resolve_gpu_is_discrete "${vendor}" "${bdf}" "${name}")"
      [[ "${kind}" == "${want_kind}" ]] || continue
      gfx=""
      [[ "${vendor}" == "amd" ]] && gfx="$(resolve_amd_gfx_target "${bdf}" 2>/dev/null || true)"
      echo "${vendor} ${bdf} ${gfx}"; return 0
    done
  done

  # Something is present but matched no vendor we know how to drive.
  IFS='|' read -r vendor bdf driver name <<< "${entries[0]}"
  echo "${vendor} ${bdf} "
}

# The DRM render node belonging to a PCI address — /dev/dri/renderD128 and
# friends. Which number a card gets depends on probe order, so on a machine
# with two GPUs the conventional renderD128 is a coin toss; asking sysfs for
# the node under this specific device is the only way to be sure a VA-API call
# lands on the card that was picked.
resolve_render_node() {
  local d
  for d in /sys/bus/pci/devices/"$1"/drm/renderD*; do
    [[ -e "${d}" ]] || continue
    printf '/dev/dri/%s' "$(basename "${d}")"
    return 0
  done
  return 1
}

# DRI_PRIME / MESA_VK_DEVICE_SELECT want the PCI address in tag form:
# 0000:05:00.0 → pci-0000_05_00_0.
resolve_pci_tag() { printf 'pci-%s' "${1//[:.]/_}"; }
