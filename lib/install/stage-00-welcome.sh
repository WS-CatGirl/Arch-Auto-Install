#!/usr/bin/env bash
#
# lib/install/stage-00-welcome.sh
# Plan-Main.md "0. Welcome and pre-checks" (lines 139-160): ASCII catgirl
# banner with name/version, wipe warning, Enter gate, privilege escalation
# through sudo, and CPU vendor detection into $CPU.
#
# Plan-Main.md 2-3 / appendix C: the live ISO TTY has no CJK fonts, so every
# runtime message below is pure ASCII (no full-width punctuation either).

stage_00_welcome() {
    local c_reset=''
    local c_bold=''
    local c_cyan=''
    local c_red=''

    # lib/common.sh stores real ESC bytes in AIT_C_* (all empty when stdout is
    # not a TTY).  Running them through printf '%b' is a no-op for real ESC
    # bytes, and it lets the banner below use plain '%s' printing so the cat
    # art can keep its backslashes.
    printf -v c_reset '%b' "${AIT_C_RESET:-}"
    printf -v c_bold  '%b' "${AIT_C_BOLD:-}"
    printf -v c_cyan  '%b' "${AIT_C_CYAN:-}"
    printf -v c_red   '%b' "${AIT_C_RED:-}"

    # -- 1. banner (1-1) -----------------------------------------------------
    # The cat art uses single-quoted strings on purpose: inside double quotes a
    # backslash right before "${c_reset}" would swallow the expansion.
    local -a cat_art=(
        $'         /\\_/\\'
        $'        ( o.o )'
        $'         > ^ <'
        $'        /|   |\\'
        $'       (_|___|_)'
    )
    local art_line=''

    printf '%s\n' ""
    for art_line in "${cat_art[@]}"; do
        printf '%s\n' "${c_cyan}${art_line}${c_reset}"
    done
    printf '%s\n' ""
    printf '%s\n' "${c_bold}${c_cyan}============================================================${c_reset}"
    printf '%s\n' "${c_bold}  ${AIT_NAME}  -  ${AIT_VERSION}${c_reset}"
    printf '%s\n' "  An Arch Linux auto-installer, stage 1 (live ISO)"
    printf '%s\n' "${c_bold}${c_cyan}============================================================${c_reset}"
    printf '%s\n' ""

    # -- 1. greeting + wipe warning (1-2) ------------------------------------
    log_info "Nyaa~ hello! I am the Arch installer catgirl. Purr-fect to meet you."
    log_info "I will walk you through the whole installation, one stage at a time."
    printf '%s\n' ""
    printf '%s\n' "${c_red}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${c_reset}"
    log_danger "!!! DANGER: THIS SCRIPT WILL ERASE YOUR ENTIRE DISK !!!"
    log_danger "Every partition and every file on the target disk will be destroyed."
    log_danger "There is no undo. Please make sure your backup is up to date."
    log_danger "If you did not mean to run this, press Ctrl+C right now!"
    printf '%s\n' "${c_red}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${c_reset}"
    printf '%s\n' ""

    # -- 1. Enter gate (1-3) -------------------------------------------------
    pause "Press Enter to continue (Ctrl+C to abort)... "

    # -- 2. privilege check (2-1 / 2-2) --------------------------------------
    if [[ $EUID -eq 0 ]]; then
        log_ok "Running as root. Good to go."
    else
        log_warn "Not root. I need root privileges to partition and format disks."

        if ! command -v sudo >/dev/null 2>&1; then
            die "ACCESS DENIED - sudo is not installed. Run 'su -' and start me again."
        fi

        # -v refreshes the timestamp without running a command; on success we
        # re-exec ourselves under sudo so the rest of stage 1 sees EUID 0.
        if sudo -v; then
            log_ok "sudo password accepted. Re-launching myself as root..."
            exec sudo -E bash -- "$0" "$@"
        fi

        die "ACCESS DENIED - sudo could not verify your password. Run 'su -' and start me again."
    fi

    # -- 3. CPU architecture and vendor (3-1 / 3-2 / 3-3) --------------------
    local arch=''
    local vendor=''

    arch="$(uname -m)"
    if [[ $arch != "x86_64" ]]; then
        log_error "Unsupported CPU architecture: ${arch}"
        log_error "This project only supports x86_64; the official Arch ISO is x86_64 only."
        log_error "For ARM boards please use Arch Linux ARM: https://archlinuxarm.org/"
        exit 1
    fi
    log_ok "CPU architecture: x86_64"

    # 3-2: prefer lscpu, fall back to /proc/cpuinfo when it is unavailable.
    if command -v lscpu >/dev/null 2>&1; then
        vendor="$(LC_ALL=C lscpu 2>/dev/null \
            | awk -F: '/^[ \t]*Vendor ID[ \t]*:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' \
            || true)"
    fi

    if [[ -z $vendor && -r /proc/cpuinfo ]]; then
        vendor="$(awk -F: '/^[ \t]*vendor_id[ \t]*:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' /proc/cpuinfo \
            || true)"
    fi

    # 3-3: $CPU is consumed by later stages; keep it to Intel / AMD / Unknown.
    case "${vendor,,}" in
        genuineintel|intel) CPU='Intel' ;;
        authenticamd|amd)   CPU='AMD'   ;;
        *)                  CPU='Unknown' ;;
    esac
    export CPU

    case "$CPU" in
        Intel) log_ok   "CPU vendor: Intel (intel-ucode will be installed)" ;;
        AMD)   log_ok   "CPU vendor: AMD (amd-ucode will be installed)" ;;
        *)     log_warn "CPU vendor not recognised; both intel-ucode and amd-ucode will be installed later." ;;
    esac
}
