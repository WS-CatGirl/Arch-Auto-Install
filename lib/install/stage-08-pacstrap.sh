#!/usr/bin/env bash
#
# lib/install/stage-08-pacstrap.sh - stage 8: pacstrap and the stage 2 hand-over.
#
# Implements Plan-Main.md section 8 (source lines 407-428):
#   1. /mnt and /mnt/efi must really be mountpoints
#   2. pacstrap -K into the new root with the package list from the plan plus
#      the microcode package matching $CPU (both when it is Unknown)
#      2-1. never --noconfirm - pacstrap has no such option and would try to
#           install a package with that very name
#      2-2. wrapped in script -qec so pacman keeps its real progress bar; the
#           log copy has the carriage returns turned into newlines
#      2-3. intel-ucode / amd-ucode / both
#      2-4. git is listed explicitly - it is NOT part of base-devel
#   3. genfstab -U -> /mnt/etc/fstab with the /windows-efi line filtered out,
#      then verified: non-empty, has the / entry, no /windows-efi left
#   4. the whole repository (minus .git) copied to /mnt/var/lib/arch-auto-install
#   5. bin/arch-config installed to /mnt/usr/local/bin/arch-config
#   6. getty@tty1 auto-login drop-in for root
#   7. /mnt/root/.bash_profile stage 2 hook: stage2.done gate plus a flock
#      kernel lock - never a "touch .running" style file, because stage 13
#      reboots and kills the process before any "rm -f" could run
#   8. /mnt/var/lib/arch-auto-install/state directory
#
# Coding contract (Plan-Main.md appendix J): values come back through global
# variables (_PAC8_*), no function writes diagnostics to stdout, every case has
# a *) arm, every /dev/tty write goes through a helper with a stderr fallback.
# Runtime text is pure ASCII (appendix C: the TTY has no CJK fonts).
#
# errexit / nounset / pipefail are already enabled by Arch-Auto-Install.sh;
# this module is sourced, never executed.

# shellcheck disable=SC2153  # ROOT / ESP / CPU are exported by earlier stages

# Mount root of the new system; stage 7 already defines it, this keeps the
# module usable on its own (for the tests in Config/Main/TestEnv).
AIT_MNT_ROOT="${AIT_MNT_ROOT:-/mnt}"
AIT_MNT_EFI="${AIT_MNT_EFI:-${AIT_MNT_ROOT}/efi}"

# Where the repository and the stage 2 state live inside the new system.
AIT_STAGE8_DEST="${AIT_MNT_ROOT}/var/lib/arch-auto-install"
AIT_STAGE8_STATE="${AIT_STAGE8_DEST}/state"

# Package list from Plan-Main.md line 412, in that exact order.  git is here on
# purpose: it is not pulled in by base-devel, and stage 15 needs it.
AIT_STAGE8_PACKAGES=(
    base
    base-devel
    git
    linux-zen
    linux-lts
    linux-zen-headers
    linux-lts-headers
    linux-firmware
    btrfs-progs
    neovim
    sudo
    networkmanager
    grub
    efibootmgr
    os-prober
    zram-generator
)

# ---------------------------------------------------------------------------
# result variables - see appendix J-1, never return values through stdout
# ---------------------------------------------------------------------------
_PAC8_PACKAGES=()     # final pacstrap package list (_pac8_collect_packages)
_PAC8_COMMAND=()      # final pacstrap argv, mount root included (_pac8_build_command)
_PAC8_MICROCODE=''    # microcode packages that were appended, for logging
_PAC8_LINE=''         # the argv above as a single shell command line
_PAC8_STATUS=0        # exit status of the pacstrap run
_PAC8_HOOK_STATE=''   # installed / skipped, set by _pac8_install_arch_config
_PAC8_LOOP_WARNED=0   # 1 once the AIT_ALLOW_LOOP warning has been printed

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
# _pac8_require_var <name> <value>
# die when a variable earlier stages must export is empty or unset.
_pac8_require_var() {
    local name="$1"
    local value="$2"

    if [[ -z $value ]]; then
        die "${name} is not set. Run the earlier stages first (stage 4 partitions the disk)."
    fi
}

# _pac8_loop_guard <device>
# Same policy as stages 4, 5, 6 and 7: a loop device is an image file, so it is
# refused unless AIT_ALLOW_LOOP=1 was set for testing.
_pac8_loop_guard() {
    local dev="$1"

    case $dev in
        /dev/loop*) ;;
        *) return 0 ;;
    esac

    if [[ ${AIT_ALLOW_LOOP:-} == '1' ]]; then
        if [[ ${_PAC8_LOOP_WARNED} -eq 0 ]]; then
            log_warn 'AIT_ALLOW_LOOP is set - loop devices are allowed for TESTING ONLY, never use this on a real install.'
            _PAC8_LOOP_WARNED=1
        fi
        return 0
    fi

    log_danger "REFUSED: ${dev} is a loop device (an image file, not a physical disk)."
    die 'loop devices are not supported in stage 8. Run stage 4 again and pick a real partition.'
}

# _pac8_check_mounts - /mnt and /mnt/efi must be real mountpoints (plan item 1)
_pac8_check_mounts() {
    local missing=()

    if ! mountpoint -q -- "$AIT_MNT_ROOT"; then
        missing+=("$AIT_MNT_ROOT")
    fi
    if ! mountpoint -q -- "$AIT_MNT_EFI"; then
        missing+=("$AIT_MNT_EFI")
    fi

    if (( ${#missing[@]} > 0 )); then
        die "Not a mountpoint: ${missing[*]}. Run stage 7 again: pacstrap would otherwise write into the live ISO."
    fi
    log_ok "Mountpoints verified: ${AIT_MNT_ROOT} and ${AIT_MNT_EFI} are mounted."
}

# ---------------------------------------------------------------------------
# package list
# ---------------------------------------------------------------------------
# _pac8_collect_packages - plan base list plus the microcode package for $CPU
# $CPU comes from stage 0 and is one of Intel / AMD / Unknown (anything else is
# treated like Unknown: install both microcode packages, one of them is right).
_pac8_collect_packages() {
    local cpu="${CPU:-Unknown}"
    local microcodes=()

    case $cpu in
        Intel)
            microcodes=(intel-ucode)
            ;;
        AMD)
            microcodes=(amd-ucode)
            ;;
        Unknown)
            microcodes=(intel-ucode amd-ucode)
            ;;
        *)
            log_warn "Unexpected CPU value '${cpu}'; installing both microcode packages."
            microcodes=(intel-ucode amd-ucode)
            ;;
    esac

    _PAC8_PACKAGES=("${AIT_STAGE8_PACKAGES[@]}" "${microcodes[@]}")
    _PAC8_MICROCODE="${microcodes[*]}"
}

# _pac8_build_command - argv for pacstrap, mount root and packages included
# The array form keeps the exact order and lets the tests assert every element.
# --noconfirm is never part of it: pacstrap does not know that option and would
# hand it to pacman as a package name (plan item 2-1).
_pac8_build_command() {
    _PAC8_COMMAND=(pacstrap -K "$AIT_MNT_ROOT" "${_PAC8_PACKAGES[@]}")
}

# _pac8_quote_command - the argv above as one shell command line in _PAC8_LINE
_pac8_quote_command() {
    local part=''

    _PAC8_LINE=''
    for part in "${_PAC8_COMMAND[@]}"; do
        printf -v part '%q' "$part"
        _PAC8_LINE+="${part} "
    done
    _PAC8_LINE="${_PAC8_LINE% }"
}

# ---------------------------------------------------------------------------
# pacstrap
# ---------------------------------------------------------------------------
# _pac8_run_pacstrap - plan item 2, wrapped in script -qec (plan item 2-2)
# script gives pacman a pseudo terminal, so the download progress bar keeps
# working; the copy that reaches the log goes through tr to turn the \r-only
# redraws into readable lines.  errexit is suspended around the pipeline: with
# pipefail on, a failing pacstrap would otherwise kill the script before the
# exit status is captured.
_pac8_run_pacstrap() {
    local status=0

    log_info 'Installing the base system (this downloads a few hundred megabytes, please wait)...'
    log_info "Packages: ${_PAC8_PACKAGES[*]}"
    log_info "Microcode for CPU=${CPU:-Unknown}: ${_PAC8_MICROCODE}"

    _pac8_quote_command
    log_info "Running: ${_PAC8_LINE}"

    set +o errexit
    # tee keeps writing its copy to stdout, so the redirected write to fd 2 is
    # what makes the whole pipeline stderr-only (appendix J-2 / J-3: nothing but
    # the return value may reach stdout).
    if [[ -n ${AIT_LOG_FILE:-} ]]; then
        script -qec "$_PAC8_LINE" /dev/null 2>&1 | tr '\r' '\n' | tee -a "$AIT_LOG_FILE" >&2
    else
        script -qec "$_PAC8_LINE" /dev/null 2>&1 | tr '\r' '\n' >&2
    fi
    status=${PIPESTATUS[0]}
    set -o errexit

    _PAC8_STATUS=$status
    if [[ $status -ne 0 ]]; then
        die "pacstrap failed with exit code ${status}. Fix the problem above and run the installer again."
    fi
    log_ok 'pacstrap finished.'
}

# _pac8_verify_system - the new root really contains an installed system
_pac8_verify_system() {
    local f=''
    local missing=()

    for f in usr/bin/pacman etc/pacman.conf usr/bin/bash; do
        if [[ ! -e "${AIT_MNT_ROOT}/${f}" ]]; then
            missing+=("$f")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        die "The new system looks incomplete: ${missing[*]} missing below ${AIT_MNT_ROOT}."
    fi
    log_ok "Installed system verified below ${AIT_MNT_ROOT}."
}

# ---------------------------------------------------------------------------
# fstab
# ---------------------------------------------------------------------------
# _pac8_write_fstab - plan item 3
# genfstab prints the mountpoints relative to the target, so the Windows ESP
# shows up as "/windows-efi".  Dropping that line has no effect on GRUB
# detection: os-prober reads /proc/mounts, not fstab (plan item 3-1).
_pac8_write_fstab() {
    local fstab="${AIT_MNT_ROOT}/etc/fstab"
    local tmp=''
    local root_entry=''

    mkdir -p "${AIT_MNT_ROOT}/etc" || die "Cannot create ${AIT_MNT_ROOT}/etc."

    tmp=$(mktemp) || die 'mktemp failed; cannot stage genfstab output.'
    if ! genfstab -U "$AIT_MNT_ROOT" >"$tmp"; then
        rm -f "$tmp"
        die "genfstab -U ${AIT_MNT_ROOT} failed."
    fi

    awk '$2 != "/windows-efi"' "$tmp" >"$fstab" || {
        rm -f "$tmp"
        die "Cannot write ${fstab}."
    }
    rm -f "$tmp"

    # verification, plan item 3-2
    if [[ ! -s $fstab ]]; then
        die "${fstab} is empty; the system would not boot."
    fi
    root_entry=$(awk '$2 == "/" { print $1; exit }' "$fstab")
    if [[ -z $root_entry ]]; then
        die "${fstab} has no entry for the root filesystem (/)."
    fi
    if grep -qF '/windows-efi' "$fstab"; then
        die "${fstab} still contains a /windows-efi entry."
    fi

    log_ok "fstab written: root=${root_entry}, /windows-efi filtered out."
}

# ---------------------------------------------------------------------------
# repository bundle
# ---------------------------------------------------------------------------
# _pac8_bundle_repository - plan item 4: whole repository, .git excluded
# tar streams the tree so there is no intermediate archive to clean up.  The
# file list of the runner is checked afterwards: a partial copy would only
# surface after the reboot, when the stage 2 hook is missing its entry script.
_pac8_bundle_repository() {
    local src="${AIT_ROOT:-}"
    local f=''
    local missing=()

    _pac8_require_var 'AIT_ROOT' "$src"
    if [[ ! -d $src ]]; then
        die "Repository directory ${src} does not exist."
    fi

    mkdir -p "$AIT_STAGE8_DEST" || die "Cannot create ${AIT_STAGE8_DEST}."
    tar -C "$src" --exclude='./.git' -cf - . | tar -C "$AIT_STAGE8_DEST" -xf - \
        || die "Cannot copy the repository from ${src} to ${AIT_STAGE8_DEST}."

    for f in Arch-Auto-Install.sh lib/common.sh lib/install/main.sh \
             lib/install/stage-08-pacstrap.sh dependence/pacman.conf; do
        if [[ ! -e "${AIT_STAGE8_DEST}/${f}" ]]; then
            missing+=("$f")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Repository bundle is incomplete, missing: ${missing[*]}."
    fi
    if [[ -e "${AIT_STAGE8_DEST}/.git" ]]; then
        die "${AIT_STAGE8_DEST}/.git was copied although it must be excluded."
    fi

    log_ok "Repository copied to ${AIT_STAGE8_DEST} (.git excluded)."
}

# ---------------------------------------------------------------------------
# arch-config
# ---------------------------------------------------------------------------
# _pac8_install_arch_config - plan item 5
# bin/arch-config is still planned (Plan-Main.md line 10), so an absent file is
# reported and skipped instead of aborting a finished pacstrap run.  State is
# stored in _PAC8_HOOK_STATE for the closing summary.
_pac8_install_arch_config() {
    local src="${AIT_ROOT:-}/bin/arch-config"
    local dst="${AIT_MNT_ROOT}/usr/local/bin/arch-config"

    if [[ ! -f $src ]]; then
        _PAC8_HOOK_STATE='skipped'
        log_warn "bin/arch-config is not in the repository yet (Plan-Main.md line 10); ${dst} is left out."
        return 0
    fi

    mkdir -p "${AIT_MNT_ROOT}/usr/local/bin" || die "Cannot create ${AIT_MNT_ROOT}/usr/local/bin."
    install -m 755 "$src" "$dst" || die "Cannot install ${src} to ${dst}."
    _PAC8_HOOK_STATE='installed'
    log_ok "arch-config installed: ${dst}."
}

# ---------------------------------------------------------------------------
# stage 2 hand-over
# ---------------------------------------------------------------------------
# _pac8_write_autologin - plan item 6: root logs in on tty1 automatically
_pac8_write_autologin() {
    local dir="${AIT_MNT_ROOT}/etc/systemd/system/getty@tty1.service.d"
    local file="${dir}/autologin.conf"

    mkdir -p "$dir" || die "Cannot create ${dir}."
    cat >"$file" <<'EOF' || die "Cannot write ${file}."
[Service]
# Arch-Auto-Install: log root in on tty1 so that the stage 2 hook can run.
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I $TERM
EOF
    log_ok "Auto-login drop-in written: ${file}."
}

# _pac8_write_bash_profile - plan item 7
# The gate is state/stage2.done; the concurrency guard is a flock kernel lock on
# state/.lock.  A "touch .running" file would be wrong (plan item 7-3): stage 13
# reboots the machine, the shell dies, and the stale file would make every later
# boot skip stage 2 for good.  The kernel drops a flock when the holder dies.
_pac8_write_bash_profile() {
    local file="${AIT_MNT_ROOT}/root/.bash_profile"

    mkdir -p "${AIT_MNT_ROOT}/root" || die "Cannot create ${AIT_MNT_ROOT}/root."
    cat >"$file" <<'EOF' || die "Cannot write ${file}."
# Arch-Auto-Install - stage 2 entry hook.
# Generated by stage 8 (lib/install/stage-08-pacstrap.sh) and rewritten by every
# install.  Remove the getty drop-in as well if you delete it by hand.

if [ -f /var/lib/arch-auto-install/state/stage2.done ]; then
    : # stage 2 already finished, this is a normal login
else
    # flock: the lock lives in the kernel, so a killed or rebooting shell
    # releases it automatically - no stale lock file can ever block a re-run.
    exec 9>/var/lib/arch-auto-install/state/.lock
    if flock -n 9; then
        if [ -f /var/lib/arch-auto-install/lib/config/main.sh ]; then
            bash /var/lib/arch-auto-install/lib/config/main.sh
        else
            echo 'arch-auto-install: lib/config/main.sh is missing, stage 2 cannot start.' >&2
        fi
    else
        echo 'arch-auto-install: stage 2 is already running in another session.' >&2
    fi
fi
EOF

    # The hook is what starts stage 2; check that it really contains both guards.
    if ! grep -q 'stage2.done' "$file"; then
        die "${file} does not check state/stage2.done."
    fi
    if ! grep -q 'flock -n 9' "$file"; then
        die "${file} does not use the flock kernel lock."
    fi
    if grep -q '\.running' "$file"; then
        die "${file} still uses a .running lock file; stage 13's reboot would leave it behind."
    fi
    log_ok "Stage 2 hook written: ${file}."
}

# _pac8_make_state_dir - plan item 8
_pac8_make_state_dir() {
    mkdir -p "$AIT_STAGE8_STATE" || die "Cannot create ${AIT_STAGE8_STATE}."
    log_ok "Stage 2 state directory ready: ${AIT_STAGE8_STATE}."
}

# ---------------------------------------------------------------------------
# stage entry point
# ---------------------------------------------------------------------------
# stage_08_pacstrap - Plan-Main.md stage 8 entry point (no arguments).
stage_08_pacstrap() {
    printf '\n' >&2
    log_info 'Stage 8: pacstrap and stage 2 hand-over'

    _pac8_require_var 'ROOT' "${ROOT:-}"
    _pac8_require_var 'ESP' "${ESP:-}"
    # The loop guard runs first so an image file is reported as such instead of
    # as a mount problem.
    _pac8_loop_guard "$ROOT"
    _pac8_loop_guard "$ESP"

    _pac8_check_mounts
    _pac8_collect_packages
    _pac8_build_command
    _pac8_run_pacstrap
    _pac8_verify_system
    _pac8_write_fstab
    _pac8_bundle_repository
    _pac8_install_arch_config
    _pac8_write_autologin
    _pac8_write_bash_profile
    _pac8_make_state_dir

    log_ok "Stage 8 finished: base system installed, fstab written, repository copied to ${AIT_STAGE8_DEST}."
    log_info 'Reboot into the new system: stage 2 starts by itself on tty1.'
}
