#!/usr/bin/env bash
#
# lib/install/stage-01-detect-os.sh
# Plan-Main.md "1. Detect the operating system" (lines 161-169): only run
# inside the Arch live ISO, warn (but do not abort) on virtual machines,
# require /run/archiso and require UEFI boot.
#
# Plan-Main.md appendix C: every runtime message is pure ASCII, because the
# live ISO TTY has no CJK fonts.

stage_01_detect_os() {
    local os_id=''
    local virt=''

    # -- 1. /etc/os-release must say ID=arch --------------------------------
    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release - this does not look like Linux at all."
    fi

    # Parse instead of sourcing: os-release is plain data, do not run it.
    os_id="$(awk -F= '/^ID=/ { gsub(/"/, "", $2); print $2; exit }' /etc/os-release || true)"

    if [[ $os_id != "arch" ]]; then
        log_error "Unsupported operating system: ID=${os_id:-unknown}"
        log_error "This installer must run inside an Arch Linux live ISO."
        log_error "Windows, WSL, macOS and other Linux distributions are not supported."
        exit 1
    fi
    log_ok "Operating system: Arch Linux"

    # -- 2. virtual machine: loud warning, no abort -------------------------
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt --vm 2>/dev/null || true)"
        if [[ -n $virt && $virt != "none" ]]; then
            log_danger "Virtual machine detected: ${virt}"
            log_danger "Continuing anyway, but disk and EFI access may behave unexpectedly."
            log_danger "Double-check that you picked the virtual disk, not a host disk!"
        else
            log_ok "Bare metal confirmed (no virtual machine detected)."
        fi
    else
        log_warn "systemd-detect-virt is missing; assuming bare metal."
    fi

    # -- 3. /run/archiso proves we are in the Arch live environment ---------
    if [[ ! -d /run/archiso ]]; then
        die "Not running inside an Arch Linux live environment (/run/archiso is missing)."
    fi
    log_ok "Arch live environment confirmed (/run/archiso)."

    # -- 4. UEFI only: BIOS / Legacy is not supported -----------------------
    if [[ ! -d /sys/firmware/efi ]]; then
        log_error "Not booted in UEFI mode (/sys/firmware/efi is missing)."
        log_error "BIOS / Legacy boot is NOT supported by this installer."
        log_error "Reboot the ISO with UEFI enabled and run me again."
        exit 1
    fi
    log_ok "UEFI boot confirmed (/sys/firmware/efi)."
}
