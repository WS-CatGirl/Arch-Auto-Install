#!/usr/bin/env bash
#
# lib/chroot/chroot-09b-boot.sh - stage 9B: the boot loader of the target system.
#
# Implements Plan-Main.md section 9, items 7-13 (GRUB install, fallback loader,
# NVRAM repair, /boot/grub link, /etc/default/grub template, grub-mkconfig and
# the dual-boot Windows entry).  The module runs INSIDE the target system, i.e.
# after arch-chroot, so every absolute path below is a path in the new root.
#
# WHY THIS MODULE EXISTS AT ALL (the pitfall it guards against)
#   grub-install writes the NVRAM entry through efibootmgr.  When that write
#   fails - and it fails on plenty of firmware, in VMs, and whenever the EFI
#   variables are read-only - grub-install prints ONE warning line and still
#   exits 0.  The install therefore looks "clean from start to finish" while
#   the machine has no boot entry at all.  Two independent countermeasures:
#     1. the removable-media fallback loader /efi/EFI/BOOT/BOOTX64.EFI, which
#        firmware boots without any NVRAM entry, and
#     2. an explicit efibootmgr check + repair, which only WARNS on failure
#        because the fallback loader already keeps the machine bootable.
#   Failures here are never allowed to masquerade as success.
#
# Coding contract (Plan-Main.md appendix J):
#   J-1  values come back through globals (_BOOT9_*), never through stdout;
#   J-2  no function that carries a value writes diagnostics to stdout;
#   J-3  all logging goes through lib/common.sh (stderr);
#   J-4  die is never called inside $(...);
#   J-5  every case has a *) arm;
#   J-6  no question loops in this module (nothing to ask: values come from the
#        earlier stages), so no retry counter is needed;
#   J-7  every /dev/tty write goes through _boot9_print_tty (stderr fallback).
#
# TargetRoot redirection: every target path is built as ${_BOOT9_ROOT}/...,
# where _BOOT9_ROOT is ${AIT_TARGET_ROOT:-}.  On a real run it is empty and the
# paths are the plain absolute target paths (/efi, /etc, /boot).  Tests point it
# at a throw-away root.  Two additional variables exist for testing only and
# are loudly warned about when used:
#   AIT_BOOT9_SKIP_EFI_MOUNT_CHECK=1  skip `mountpoint -q <root>/efi`
#   AIT_BOOT9_SKIP_UEFI_CHECK=1       skip `[[ -d /sys/firmware/efi ]]`
#   AIT_BOOT9_ESP_SOURCE / AIT_BOOT9_ESP_DISK / AIT_BOOT9_ESP_PART
#                                     overrides for the ESP block-device lookup
#   AIT_BOOT9_WINDOWS_UUID            override for the Windows ESP filesystem UUID
#
# Runtime text is pure ASCII (appendix C: the TTY has no CJK fonts).
# errexit / nounset / pipefail are enabled by Arch-Auto-Install.sh; this module
# is sourced, never executed.

# Stage paths (relative to the target root).
AIT_BOOT9_ESP='/efi'
AIT_BOOT9_GRUB_DIR='/efi/grub'
AIT_BOOT9_DEFAULT_GRUB='/etc/default/grub'
AIT_BOOT9_CUSTOM_ENTRY='/etc/grub.d/40_custom'

# Every key that the shipped dependence/grub template must end up with.
# grep -qxF is used verbatim, so these strings must match the file byte for byte.
AIT_BOOT9_REQUIRED_KEYS=(
    'GRUB_DEFAULT=saved'
    'GRUB_TIMEOUT=60'
    'GRUB_TIMEOUT_STYLE=menu'
    'GRUB_SAVEDEFAULT=true'
    'GRUB_DISABLE_OS_PROBER="false"'
)

# ---------------------------------------------------------------------------
# result variables - appendix J-1, never return values through stdout
# ---------------------------------------------------------------------------
_BOOT9_ROOT=''            # target root prefix (empty on a real run)
_BOOT9_WATCHDOG=''        # iTCO_wdt / sp5100_tco / iTCO_wdt,sp5100_tco
_BOOT9_TEMPLATE=''        # resolved path of dependence/grub
_BOOT9_NVRAM_OUT=''       # raw `efibootmgr` output
_BOOT9_NVRAM_PRESENT=0    # 1 when NVRAM already lists a GRUB entry
_BOOT9_NVRAM_TOOL=1       # 0 when efibootmgr is not installed
_BOOT9_ESP_DEV=''         # block device behind the ESP, e.g. /dev/sda1
_BOOT9_ESP_DISK=''        # whole disk, e.g. /dev/sda
_BOOT9_ESP_PART=''        # partition number, e.g. 1
_BOOT9_DUAL_BOOT=0        # 1 when the machine also boots Windows
_BOOT9_WIN_UUID=''        # filesystem UUID of the Windows ESP
_BOOT9_CUSTOM=''          # resolved /etc/grub.d/40_custom path

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
# _boot9_print_tty <text>
# Prints one block of text on the controlling terminal; without one it falls
# back to stderr and common.sh explains that once (appendix J-7).
_boot9_print_tty() {
    local text="$1"

    if _ait_tty_usable; then
        if { printf '%s\n' "$text" >/dev/tty; } 2>/dev/null; then
            return 0
        fi
    fi
    _ait_tty_notice
    printf '%s\n' "$text" >&2
}

# _boot9_require_cmd <command> <hint>
_boot9_require_cmd() {
    local cmd="$1"
    local hint="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "'${cmd}' is not available inside the target system (${hint})."
    fi
}

# _boot9_init_root - resolves and validates the TargetRoot prefix
_boot9_init_root() {
    _BOOT9_ROOT="${AIT_TARGET_ROOT:-}"

    if [[ -z $_BOOT9_ROOT ]]; then
        return 0
    fi
    if [[ $_BOOT9_ROOT != /* ]]; then
        die "AIT_TARGET_ROOT must be an absolute path, got '${_BOOT9_ROOT}'."
    fi
    while [[ $_BOOT9_ROOT == */ ]]; do
        _BOOT9_ROOT="${_BOOT9_ROOT%/}"
    done
    if [[ -z $_BOOT9_ROOT || $_BOOT9_ROOT == '/' ]]; then
        die 'AIT_TARGET_ROOT must not resolve to /; refusing to treat the live root as the target.'
    fi
    if [[ ! -d $_BOOT9_ROOT ]]; then
        die "AIT_TARGET_ROOT does not exist: ${_BOOT9_ROOT}."
    fi
    log_warn "AIT_TARGET_ROOT=${_BOOT9_ROOT} - every target path is redirected there (TESTING ONLY)."
}

# ---------------------------------------------------------------------------
# item 7 - pre-flight checks
# ---------------------------------------------------------------------------
# _boot9_preflight
# The ESP must really be a mountpoint: writing a boot loader onto the btrfs
# root instead of the FAT ESP produces a system that boots into nothing, and
# the damage is only visible on the next reboot.
_boot9_preflight() {
    local esp="${_BOOT9_ROOT}${AIT_BOOT9_ESP}"

    if [[ ${AIT_BOOT9_SKIP_EFI_MOUNT_CHECK:-} == '1' ]]; then
        log_warn "AIT_BOOT9_SKIP_EFI_MOUNT_CHECK=1 - NOT checking whether ${esp} is a mountpoint (TESTING ONLY)."
    else
        if ! mountpoint -q -- "$esp" 2>/dev/null; then
            die "${esp} is not a mount point; refusing to install GRUB there (the boot loader would be written into the root filesystem)."
        fi
        log_ok "ESP check: ${esp} is a mount point."
    fi

    if [[ ! -d $esp ]]; then
        die "The ESP directory ${esp} does not exist."
    fi

    if [[ ${AIT_BOOT9_SKIP_UEFI_CHECK:-} == '1' ]]; then
        log_warn 'AIT_BOOT9_SKIP_UEFI_CHECK=1 - NOT checking for /sys/firmware/efi (TESTING ONLY).'
    else
        if [[ ! -d /sys/firmware/efi ]]; then
            die 'Not booted in UEFI mode (/sys/firmware/efi is missing); this stage only installs the x86_64-efi target.'
        fi
        log_ok 'UEFI check: /sys/firmware/efi is present.'
    fi
}

# ---------------------------------------------------------------------------
# item 8 - grub-install
# ---------------------------------------------------------------------------
# _boot9_install_grub
_boot9_install_grub() {
    local esp="${_BOOT9_ROOT}${AIT_BOOT9_ESP}"
    local efi_binary="${esp}/EFI/GRUB/grubx64.efi"

    _boot9_require_cmd 'grub-install' 'it is installed by pacstrap in stage 8'
    log_info "Installing GRUB for x86_64-efi on ${esp} ..."
    # --boot-directory points at the ESP as well, so grub.cfg and the modules
    # live next to the EFI binary on the FAT partition instead of on btrfs.
    if ! grub-install \
        --target=x86_64-efi \
        --efi-directory="$esp" \
        --boot-directory="$esp" \
        --bootloader-id=GRUB \
        --recheck; then
        die "grub-install failed; the target system has no boot loader yet."
    fi

    if [[ ! -s $efi_binary ]]; then
        die "${efi_binary} is missing or empty after grub-install."
    fi
    log_ok "GRUB installed: ${efi_binary}."
}

# ---------------------------------------------------------------------------
# item 9 - fallback loader and NVRAM repair
# ---------------------------------------------------------------------------
# _boot9_install_fallback
# The UEFI specification's removable-media path is \EFI\BOOT\BOOTX64.EFI.  It
# is used by firmware whenever NVRAM holds no usable entry, so installing it
# makes the machine bootable even when every NVRAM write fails.
_boot9_install_fallback() {
    local esp="${_BOOT9_ROOT}${AIT_BOOT9_ESP}"
    local src="${esp}/EFI/GRUB/grubx64.efi"
    local dst="${esp}/EFI/BOOT/BOOTX64.EFI"

    if [[ ! -s $src ]]; then
        die "${src} is missing or empty; cannot create the fallback loader."
    fi
    mkdir -p -- "${esp}/EFI/BOOT" || die "Failed to create ${esp}/EFI/BOOT."
    cp -f -- "$src" "$dst" || die "Failed to copy ${src} to ${dst}."
    if [[ ! -s $dst ]]; then
        die "${dst} is missing or empty after the copy."
    fi
    log_ok "Fallback loader installed: ${dst} (works without any NVRAM entry)."
}

# _boot9_nvram_scan - reads the NVRAM entry table into _BOOT9_NVRAM_OUT
_boot9_nvram_scan() {
    _BOOT9_NVRAM_OUT=''
    _BOOT9_NVRAM_PRESENT=0
    _BOOT9_NVRAM_TOOL=1

    if ! command -v efibootmgr >/dev/null 2>&1; then
        _BOOT9_NVRAM_TOOL=0
        return 0
    fi
    # efibootmgr without arguments lists the entries; a failing call is not an
    # error here, the empty result simply means "no entry we can see".
    _BOOT9_NVRAM_OUT=$(efibootmgr 2>/dev/null || true)
    if printf '%s\n' "$_BOOT9_NVRAM_OUT" \
        | grep -Eq '^Boot[0-9A-Fa-f]{4}\*?[[:space:]]+GRUB([[:space:]]|$)'; then
        _BOOT9_NVRAM_PRESENT=1
    fi
    return 0
}

# _boot9_esp_source - resolves the ESP block device, its disk and part number
_boot9_esp_source() {
    local esp="${_BOOT9_ROOT}${AIT_BOOT9_ESP}"
    local pk=''
    local pn=''

    _BOOT9_ESP_DEV=''
    _BOOT9_ESP_DISK=''
    _BOOT9_ESP_PART=''

    if [[ -n ${AIT_BOOT9_ESP_DISK:-} && -n ${AIT_BOOT9_ESP_PART:-} ]]; then
        log_warn "AIT_BOOT9_ESP_DISK/AIT_BOOT9_ESP_PART are set; using them instead of detecting the ESP (TESTING ONLY)."
        _BOOT9_ESP_DEV="${AIT_BOOT9_ESP_SOURCE:-}"
        _BOOT9_ESP_DISK="${AIT_BOOT9_ESP_DISK}"
        _BOOT9_ESP_PART="${AIT_BOOT9_ESP_PART}"
        return 0
    fi

    if [[ -n ${AIT_BOOT9_ESP_SOURCE:-} ]]; then
        _BOOT9_ESP_DEV="${AIT_BOOT9_ESP_SOURCE}"
    else
        _BOOT9_ESP_DEV=$(findmnt -n -o SOURCE --target "$esp" 2>/dev/null | head -n 1 || true)
    fi
    if [[ -z $_BOOT9_ESP_DEV ]]; then
        return 1
    fi

    pk=$(lsblk -n -o PKNAME -- "$_BOOT9_ESP_DEV" 2>/dev/null | head -n 1 || true)
    pn=$(lsblk -n -o PARTN -- "$_BOOT9_ESP_DEV" 2>/dev/null | head -n 1 || true)
    if [[ -z $pk || -z $pn ]]; then
        return 1
    fi
    _BOOT9_ESP_DISK="/dev/${pk}"
    _BOOT9_ESP_PART="$pn"
    return 0
}

# _boot9_nvram_check - repairs a missing GRUB entry, NEVER fatal on failure
_boot9_nvram_check() {
    _boot9_nvram_scan

    if [[ $_BOOT9_NVRAM_PRESENT -eq 1 ]]; then
        log_ok 'NVRAM already lists a GRUB boot entry.'
        return 0
    fi

    if [[ $_BOOT9_NVRAM_TOOL -eq 0 ]]; then
        log_warn 'efibootmgr is not available inside the target system, so the UEFI boot entries cannot be inspected or repaired.'
        log_warn 'The removable-media fallback loader is installed, so the machine can still boot.'
        return 0
    fi

    log_warn 'NVRAM has no GRUB boot entry (grub-install only warned about it and still returned 0).'
    if ! _boot9_esp_source; then
        log_warn 'Could not determine the ESP block device, so the NVRAM entry cannot be created automatically.'
        log_warn 'The removable-media fallback loader is installed, so the machine can still boot.'
        return 0
    fi

    log_info "Creating the NVRAM entry: disk=${_BOOT9_ESP_DISK} part=${_BOOT9_ESP_PART} label=GRUB."
    if efibootmgr --create \
        --disk "$_BOOT9_ESP_DISK" \
        --part "$_BOOT9_ESP_PART" \
        --label GRUB \
        --loader '\EFI\GRUB\grubx64.efi'; then
        log_ok 'NVRAM entry created.'
        return 0
    fi

    # Not fatal: the fallback loader is already on the ESP.
    log_warn 'Failed to create the NVRAM entry; this is NOT fatal because the fallback loader is installed.'
    log_warn 'Full efibootmgr output follows:'
    # Printed line by line through log_info so the block also lands in
    # AIT_LOG_FILE and in any captured stderr; _boot9_print_tty would send it
    # to /dev/tty only and hide it from a redirected run (appendix J-3/J-7).
    local _boot9_efi_line=''
    while IFS= read -r _boot9_efi_line; do
        log_info "  ${_boot9_efi_line}"
    done < <(efibootmgr -v 2>&1 || true)
    return 0
}

# ---------------------------------------------------------------------------
# item 10 - /boot/grub -> /efi/grub
# ---------------------------------------------------------------------------
# _boot9_link_boot_grub
# grub-mkconfig writes /boot/grub/grub.cfg; with /efi being the only boot
# partition, /boot/grub must be a symlink so that the two paths are one file.
_boot9_link_boot_grub() {
    local boot="${_BOOT9_ROOT}/boot"
    local link="${boot}/grub"
    local target="${_BOOT9_ROOT}${AIT_BOOT9_GRUB_DIR}"

    if [[ ! -d $boot ]]; then
        mkdir -p -- "$boot" || die "Failed to create ${boot}."
    fi
    # A real directory here (left over from an earlier attempt) must go, or the
    # symlink would be created INSIDE it and the next grub-mkconfig would write
    # to the wrong place.
    rm -rf -- "$link" || die "Failed to remove the old ${link}."
    ln -sfn -- "$target" "$link" || die "Failed to create the symlink ${link} -> ${target}."

    if [[ ! -L $link ]]; then
        die "${link} is not a symbolic link after the link step."
    fi
    if [[ $(readlink -- "$link") != "$target" ]]; then
        die "${link} points at '$(readlink -- "$link")' instead of '${target}'."
    fi
    if [[ ! -d $link ]]; then
        die "${link} does not resolve to the GRUB directory ${target}."
    fi
    log_ok "Boot directory linked: ${link} -> ${target}."
}

# ---------------------------------------------------------------------------
# item 11 - /etc/default/grub from the shipped template
# ---------------------------------------------------------------------------
# _boot9_watchdog_module - picks the hardware watchdog module for this CPU
# nowatchdog only disables the software watchdog; the chipset watchdog needs
# modprobe.blacklist.  Intel chipsets use iTCO_wdt, AMD ones sp5100_tco -
# blacklisting the wrong one leaves the real watchdog running.
_boot9_watchdog_module() {
    _BOOT9_WATCHDOG=''

    case "${CPU:-Unknown}" in
        Intel | intel | INTEL)
            _BOOT9_WATCHDOG='iTCO_wdt'
            ;;
        AMD | amd | Amd)
            _BOOT9_WATCHDOG='sp5100_tco'
            ;;
        Unknown | unknown | '')
            _BOOT9_WATCHDOG='iTCO_wdt,sp5100_tco'
            ;;
        *)
            log_warn "Unexpected CPU='${CPU:-}'; expected Intel, AMD or Unknown."
            log_warn 'Blacklisting both watchdog modules to be safe.'
            _BOOT9_WATCHDOG='iTCO_wdt,sp5100_tco'
            ;;
    esac

    if [[ -z $_BOOT9_WATCHDOG ]]; then
        die 'Internal error: no watchdog module was selected; nothing was changed.'
    fi
    log_info "Watchdog module for CPU=${CPU:-Unknown}: ${_BOOT9_WATCHDOG}."
}

# _boot9_find_template - locates dependence/grub (repo root first, then $PWD)
_boot9_find_template() {
    local candidates=()
    local candidate=''

    _BOOT9_TEMPLATE=''
    if [[ -n ${AIT_REPO_ROOT:-} ]]; then
        candidates+=("${AIT_REPO_ROOT}/dependence/grub")
    fi
    candidates+=("$PWD/dependence/grub")

    for candidate in "${candidates[@]}"; do
        if [[ -f $candidate && -r $candidate ]]; then
            _BOOT9_TEMPLATE="$candidate"
            return 0
        fi
    done
    return 1
}

# _boot9_verify_default_grub <file>
# Checks the five must-have keys with grep -qxF (whole line, fixed string), so a
# commented-out or re-spelled key cannot slip through.
_boot9_verify_default_grub() {
    local file="$1"
    local key=''

    for key in "${AIT_BOOT9_REQUIRED_KEYS[@]}"; do
        if ! grep -qxF -- "$key" "$file"; then
            die "${file} is missing the line '${key}'."
        fi
    done
    log_ok "Verified ${#AIT_BOOT9_REQUIRED_KEYS[@]} required settings in ${file}."
}

# _boot9_render_default_grub
# The shipped dependence/grub is the target style.  The pacstrap copy is kept
# as /etc/default/grub.arch-default so the Arch default stays recoverable.
_boot9_render_default_grub() {
    local src="$_BOOT9_TEMPLATE"
    local dest="${_BOOT9_ROOT}${AIT_BOOT9_DEFAULT_GRUB}"
    local backup="${dest}.arch-default"
    local tmp=''
    local content=''

    if [[ ! -r $src ]]; then
        die "The GRUB template ${src} is not readable."
    fi
    if [[ ! -d ${_BOOT9_ROOT}/etc/default ]]; then
        die "${_BOOT9_ROOT}/etc/default does not exist; the target system is not populated."
    fi
    if [[ ! -f $dest ]]; then
        die "${dest} does not exist; pacstrap did not install grub in stage 8."
    fi

    if [[ -e $backup ]]; then
        log_info "Keeping the existing backup ${backup}."
    else
        cp -f -- "$dest" "$backup" || die "Failed to back up ${dest} to ${backup}."
        log_ok "Backed up the Arch default: ${backup}."
    fi

    content=$(<"$src")
    # gsub: every occurrence is replaced (bash global substitution).
    content="${content//'{{WATCHDOG_MODULE}}'/$_BOOT9_WATCHDOG}"

    tmp="${dest}.new.$$"
    printf '%s\n' "$content" >"$tmp" || die "Failed to write ${tmp}."
    # A leftover placeholder means the template gained a token this stage does
    # not know - install it and the user silently boots with a broken cmdline.
    if grep -qF -- '{{' "$tmp"; then
        rm -f -- "$tmp"
        die "${src} still contains unresolved placeholders after rendering; ${dest} was left untouched."
    fi
    chmod 0644 -- "$tmp" || true
    mv -f -- "$tmp" "$dest" || die "Failed to install ${dest}."

    _boot9_verify_default_grub "$dest"
    log_ok "${dest} now follows dependence/grub (watchdog: ${_BOOT9_WATCHDOG})."
}

# ---------------------------------------------------------------------------
# item 12 - os-prober and grub.cfg
# ---------------------------------------------------------------------------
# _boot9_os_prober - informational only, never fatal
_boot9_os_prober() {
    local found=''

    if ! command -v os-prober >/dev/null 2>&1; then
        log_warn 'os-prober is not installed; grub-mkconfig will only see the current system.'
        return 0
    fi
    found=$(os-prober 2>/dev/null || true)
    if [[ -z $found ]]; then
        log_info 'os-prober found no other operating systems.'
        return 0
    fi
    log_info 'os-prober found:'
    printf '%s\n' "$found" | while IFS= read -r line; do
        log_info "  ${line}"
    done
}

# _boot9_mkconfig
# GRUB_DISABLE_OS_PROBER="false" in the template is what makes os-prober run.
_boot9_mkconfig() {
    local cfg="${_BOOT9_ROOT}/boot/grub/grub.cfg"
    local real="${_BOOT9_ROOT}${AIT_BOOT9_GRUB_DIR}/grub.cfg"

    _boot9_require_cmd 'grub-mkconfig' 'it is installed by pacstrap in stage 8'
    log_info 'Generating grub.cfg ...'
    if ! grub-mkconfig -o "$cfg"; then
        die 'grub-mkconfig failed; the target system has no grub.cfg yet.'
    fi
    if [[ ! -s $cfg ]]; then
        die "${cfg} is missing or empty after grub-mkconfig."
    fi
    if ! grep -q -- 'menuentry' "$cfg"; then
        die "${cfg} contains no menuentry; the resulting boot menu would be empty."
    fi
    if [[ ! -s $real ]]; then
        die "${real} is missing or empty; /boot/grub does not point at the ESP."
    fi
    log_ok "grub.cfg generated: ${cfg} (via ${real})."
}

# ---------------------------------------------------------------------------
# item 13 - dual boot: the Windows chainloader entry
# ---------------------------------------------------------------------------
# _boot9_dual_boot_detect - sets _BOOT9_DUAL_BOOT from the earlier stages
_boot9_dual_boot_detect() {
    local vars="${_BOOT9_ROOT}/root/.install-vars"
    local line=''

    _BOOT9_DUAL_BOOT=0

    if [[ ${AIT_DUAL_BOOT:-} == '1' || ${AIT_DUAL_BOOT:-} == 'y' \
        || ${AIT_DUAL_BOOT:-} == 'yes' || ${AIT_DUAL_BOOT:-} == 'true' ]]; then
        _BOOT9_DUAL_BOOT=1
        return 0
    fi
    if [[ -n ${AIT_WINDOWS_ESP:-} || -n ${WESP:-} ]]; then
        _BOOT9_DUAL_BOOT=1
        return 0
    fi
    if mountpoint -q -- "${_BOOT9_ROOT}/windows-efi" 2>/dev/null; then
        _BOOT9_DUAL_BOOT=1
        return 0
    fi
    # Stage 8 drops the install variables into the target; read WESP from there
    # instead of sourcing the file (a sourced file could clobber our globals).
    if [[ -r $vars ]]; then
        line=$(grep -m 1 '^WESP=' -- "$vars" || true)
        if [[ -n $line ]]; then
            WESP="${line#WESP=}"
            WESP="${WESP%\"}"
            WESP="${WESP#\"}"
            WESP="${WESP%\'}"
            WESP="${WESP#\'}"
            if [[ -n $WESP ]]; then
                _BOOT9_DUAL_BOOT=1
                return 0
            fi
        fi
    fi
    return 0
}

# _boot9_windows_esp_uuid - resolves the Windows ESP filesystem UUID
_boot9_windows_esp_uuid() {
    local dev=''

    _BOOT9_WIN_UUID=''
    if [[ -n ${AIT_BOOT9_WINDOWS_UUID:-} ]]; then
        log_warn 'AIT_BOOT9_WINDOWS_UUID is set; using it instead of probing the partition (TESTING ONLY).'
        _BOOT9_WIN_UUID="${AIT_BOOT9_WINDOWS_UUID}"
        return 0
    fi
    dev="${AIT_WINDOWS_ESP:-${WESP:-}}"
    if [[ -z $dev || ! -b $dev ]]; then
        return 1
    fi
    _BOOT9_WIN_UUID=$(blkid -s UUID -o value -- "$dev" 2>/dev/null || true)
    if [[ -z $_BOOT9_WIN_UUID ]]; then
        return 1
    fi
    return 0
}

# _boot9_ensure_40custom - makes sure /etc/grub.d/40_custom is executable
# Result goes to _BOOT9_CUSTOM (appendix J-1 / J-2: no stdout, no logging in a
# value channel).
_boot9_ensure_40custom() {
    local custom="${_BOOT9_ROOT}${AIT_BOOT9_CUSTOM_ENTRY}"

    _BOOT9_CUSTOM="$custom"
    if [[ ! -f $custom ]]; then
        mkdir -p -- "$(dirname -- "$custom")" || die "Failed to create $(dirname -- "$custom")."
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' 'exec tail -n +3 $0'
            printf '%s\n' '# Custom entries appended by Arch-Auto-Install stage 9B.'
        } >"$custom" || die "Failed to create ${custom}."
        log_warn "${custom} was missing; created a minimal one."
    fi
    chmod 0755 -- "$custom" || log_warn "Failed to make ${custom} executable."
}

# _boot9_dual_boot_windows - appends the chainloader entry when it is missing
_boot9_dual_boot_windows() {
    local cfg="${_BOOT9_ROOT}/boot/grub/grub.cfg"
    local custom=''
    local uuid=''

    _boot9_dual_boot_detect
    if [[ $_BOOT9_DUAL_BOOT -eq 0 ]]; then
        log_info 'No dual boot: the Windows menu entry check is skipped.'
        return 0
    fi
    if grep -qF -- 'Windows Boot Manager' "$cfg"; then
        log_ok 'grub.cfg already lists Windows Boot Manager.'
        return 0
    fi

    if ! _boot9_windows_esp_uuid; then
        log_warn 'Dual boot is in use but the Windows ESP device/UUID is unknown, so no chainloader entry can be built.'
        log_warn 'Set AIT_WINDOWS_ESP to the Windows FAT32 partition and re-run stage 9B to add it.'
        log_warn 'The Windows entry may still appear later through os-prober on the first boot.'
        return 0
    fi
    uuid="$_BOOT9_WIN_UUID"

    _boot9_ensure_40custom
    custom="$_BOOT9_CUSTOM"
    # The blank line keeps the previous entry's closing brace separated.
    {
        printf '\n'
        printf '%s\n' 'menuentry "Windows Boot Manager" --class windows --class os {'
        printf '%s\n' '    insmod part_gpt'
        printf '%s\n' '    insmod fat'
        printf '%s\n' "    search --no-floppy --fs-uuid --set=root ${uuid}"
        printf '%s\n' '    chainloader /EFI/Microsoft/Boot/bootmgfw.efi'
        printf '%s\n' '}'
    } >>"$custom" || die "Failed to append the Windows entry to ${custom}."
    log_ok "Windows chainloader entry appended to ${custom}."

    # Regenerate so the new entry really lands in grub.cfg.
    _boot9_mkconfig
    if grep -qF -- 'Windows Boot Manager' "$cfg"; then
        log_ok 'Windows Boot Manager is now present in grub.cfg.'
    else
        log_warn 'The Windows entry is still missing from grub.cfg; check the 40_custom syntax on the first boot.'
    fi
}

# ---------------------------------------------------------------------------
# stage entry point
# ---------------------------------------------------------------------------
# chroot_09b_boot - Plan-Main.md stage 9, items 7-13 (no arguments).
chroot_09b_boot() {
    printf '\n' >&2
    log_info 'Stage 9B: GRUB installation, fallback loader and GRUB defaults'

    _boot9_init_root
    _boot9_preflight
    _boot9_install_grub
    _boot9_install_fallback
    _boot9_nvram_check
    _boot9_link_boot_grub
    _boot9_watchdog_module

    if ! _boot9_find_template; then
        die "Cannot find dependence/grub (looked in \${AIT_REPO_ROOT}/dependence/grub and ${PWD}/dependence/grub)."
    fi
    _boot9_render_default_grub

    _boot9_os_prober
    _boot9_mkconfig
    _boot9_dual_boot_windows

    log_ok "Stage 9B finished: GRUB installed on ${_BOOT9_ROOT}${AIT_BOOT9_ESP}, defaults rendered, grub.cfg generated."
}
