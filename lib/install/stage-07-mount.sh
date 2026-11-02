#!/usr/bin/env bash
#
# lib/install/stage-07-mount.sh - stage 7: second mount and dual boot handling.
#
# Implements Plan-Main.md section 7 (source lines 323-337):
#   * remount the root subvolume with compression, noatime and discard=async
#   * mount @home, @snapshots and @home_snapshots at their final mountpoints
#   * mount the ESP at /mnt/efi
#   * ask whether the machine also boots Windows; when it does, mount the
#     Windows ESP at /mnt/windows-efi - unless it is the very same partition
#     that is already mounted at /mnt/efi, which must never be mounted twice
#     (that would put two identical UUID entries into fstab)
#
# Coding contract (Plan-Main.md appendix J): values come back through global
# variables (_MNT7_*, WESP), no function writes diagnostics to stdout, every
# case has a *) arm, every prompt loop stops after 5 invalid answers and every
# /dev/tty write goes through a helper with a stderr fallback.  Runtime text is
# pure ASCII (appendix C: the TTY has no CJK fonts).
#
# errexit / nounset / pipefail are already enabled by Arch-Auto-Install.sh;
# this module is sourced, never executed.

# shellcheck disable=SC2153  # ROOT / ESP are exported by stage 4 (disk partitioning)

AIT_MNT_ROOT='/mnt'
AIT_MNT_HOME='/mnt/home'
AIT_MNT_SNAPSHOTS='/mnt/.snapshots'
AIT_MNT_HOME_SNAPSHOTS='/mnt/home/.snapshots'
AIT_MNT_EFI='/mnt/efi'
AIT_MNT_WINDOWS_EFI='/mnt/windows-efi'

# Shared btrfs mount options; every subvolume mount appends its own subvol=.
AIT_MNT7_BTRFS_OPTS='rw,compress=zstd,noatime,discard=async'

# Windows EFI partition (empty when there is no dual boot).  Exported at the
# end of the stage so that stage 8 can write the fstab entries.
WESP="${WESP:-}"

# ---------------------------------------------------------------------------
# result variables - see appendix J-1, never return values through stdout
# ---------------------------------------------------------------------------
_MNT7_ANSWER=''   # y / n from _mnt7_ask_yes_no
_MNT7_DEVICE=''   # validated device from _mnt7_ask_windows_esp
_MNT7_REASON=''   # why a device cannot be used, set by _mnt7_require_partition
_MNT7_FSTYPE=''   # blkid TYPE of a device, set by _mnt7_fs_type
_MNT7_DISK=''     # parent disk of a device, set by _mnt7_parent_disk
_MNT7_LOOP_WARNED=0 # 1 once the AIT_ALLOW_LOOP warning has been printed

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
# _mnt7_print_tty <text>
# Prints one block of text on the controlling terminal; without one it falls
# back to stderr and common.sh explains that once (appendix J-7).
_mnt7_print_tty() {
    local text="$1"

    if _ait_tty_usable; then
        if { printf '%s\n' "$text" >/dev/tty; } 2>/dev/null; then
            return 0
        fi
    fi
    _ait_tty_notice
    printf '%s\n' "$text" >&2
}

# ---------------------------------------------------------------------------
# device inspection - results go to _MNT7_* globals, never to stdout
# ---------------------------------------------------------------------------
# _mnt7_lsblk_field <device> <column> -> value on stdout
# The only stdout helper in this module: it returns raw lsblk text and never
# logs, which is exactly what appendix J-2 allows.
_mnt7_lsblk_field() {
    local dev="$1"
    local col="$2"

    lsblk -n -o "$col" "$dev" 2>/dev/null | head -n 1
}

# _mnt7_fs_type <device> - stores the blkid TYPE in _MNT7_FSTYPE (may be empty)
# blkid -p (probe) reads the superblock directly instead of the udev cache, so a
# partition that stage 5 reformatted a moment ago cannot report its old type.
_mnt7_fs_type() {
    local dev="$1"

    _MNT7_FSTYPE=''
    _MNT7_FSTYPE=$(blkid -p -o value -s TYPE -- "$dev" 2>/dev/null || true)
}

# _mnt7_parent_disk <device> - stores the parent disk name in _MNT7_DISK
_mnt7_parent_disk() {
    local dev="$1"
    local parent=''

    parent=$(lsblk -n -o PKNAME "$dev" 2>/dev/null | head -n 1)
    if [[ -z $parent ]]; then
        parent="${dev##*/}"
    fi
    _MNT7_DISK="$parent"
}

# _mnt7_loop_guard <device>
# Same policy as stages 4, 5 and 6: a loop device is an image file, so it is
# refused unless AIT_ALLOW_LOOP=1 was set for testing.  The warned flag is
# module-local on purpose - stage 6 keeps its own, the modules are independent.
_mnt7_loop_guard() {
    local dev="$1"

    case $dev in
        /dev/loop*) ;;
        *) return 0 ;;
    esac

    if [[ ${AIT_ALLOW_LOOP:-} == '1' ]]; then
        if [[ ${_MNT7_LOOP_WARNED} -eq 0 ]]; then
            log_warn 'AIT_ALLOW_LOOP is set - loop devices are allowed for TESTING ONLY, never use this on a real install.'
            _MNT7_LOOP_WARNED=1
        fi
        return 0
    fi

    log_danger "REFUSED: ${dev} is a loop device (an image file, not a physical disk)."
    die 'loop devices are not supported in stage 7. Run stage 4 again and pick a real partition.'
}

# _mnt7_require_partition <device>
# Succeeds only for an existing block device that carries a partition number;
# the reason is stored in _MNT7_REASON.  Call it directly (never in $(...)) so
# that the die arms of its callers really exit - appendix J-1 / J-4.
_mnt7_require_partition() {
    local dev="$1"
    local partn=''

    _MNT7_REASON=''
    if [[ -z $dev ]]; then
        _MNT7_REASON='the device name is empty'
        return 1
    fi
    if [[ ! -e $dev ]]; then
        _MNT7_REASON='the device does not exist'
        return 1
    fi
    if [[ ! -b $dev ]]; then
        _MNT7_REASON='it is not a block device'
        return 1
    fi
    partn=$(_mnt7_lsblk_field "$dev" 'PARTN')
    if [[ -z $partn ]]; then
        _MNT7_REASON='it is a whole disk, not a partition'
        return 1
    fi
    _MNT7_REASON=''
    return 0
}

# _mnt7_require_var <name> <value> - dies when a stage 4 export is missing
_mnt7_require_var() {
    local name="$1"
    local value="$2"

    if [[ -z $value ]]; then
        die "${name} is empty; run stage 4 (disk partitioning) before stage 7."
    fi
}

# _mnt7_check_mnt_clean - refuses to continue when the mount root is in use
_mnt7_check_mnt_clean() {
    local busy=''
    local target=''

    while IFS= read -r target; do
        if [[ $target == "$AIT_MNT_ROOT" || $target == "$AIT_MNT_ROOT"/* ]]; then
            busy="${busy}${busy:+, }${target}"
        fi
    done < <(findmnt -rn -o TARGET 2>/dev/null || true)

    if [[ -n $busy ]]; then
        die "${AIT_MNT_ROOT} already has mounted filesystems (${busy}); unmount them before stage 7."
    fi
}

# ---------------------------------------------------------------------------
# prompts - appendix J-6: at most 5 invalid answers, then die
# ---------------------------------------------------------------------------
# _mnt7_ask_yes_no <prompt> [default n|y] - answer stored in _MNT7_ANSWER
_mnt7_ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer=''
    local tries=0

    _MNT7_ANSWER=''
    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die "Too many invalid answers for '${prompt}'; nothing was mounted."
        fi
        answer=$(read_answer "${prompt} [y/N]: " "$default")
        answer="${answer,,}"
        answer="${answer//[[:space:]]/}"
        case $answer in
            y | yes)
                _MNT7_ANSWER='y'
                return 0
                ;;
            n | no | '')
                _MNT7_ANSWER='n'
                return 0
                ;;
            *)
                log_warn "Please answer y or n, not '${answer}'."
                ;;
        esac
    done
}

# _mnt7_show_partitions - lists the partitions the user can pick from
_mnt7_show_partitions() {
    local root_disk=''
    local menu=''

    _mnt7_parent_disk "$ROOT"
    root_disk="$_MNT7_DISK"

    menu=$(
        lsblk -pf -o NAME,SIZE,FSTYPE,LABEL,PARTTYPE 2>/dev/null | awk -v skip="$root_disk" '
            NR == 1 { print; next }
            $1 == skip { next }
            $1 ~ /^\/dev\/loop/ { next }
            $1 ~ /^\/dev\/sr/ { next }
            { print }'
    )
    _mnt7_print_tty ''
    _mnt7_print_tty "Partitions on this machine (${root_disk} is the installation target and is hidden):"
    _mnt7_print_tty "$menu"
}

# _mnt7_ask_windows_esp - validates the Windows ESP and stores it in _MNT7_DEVICE
_mnt7_ask_windows_esp() {
    local raw=''
    local dev=''
    local fstype=''
    local root_disk=''
    local win_disk=''
    local tries=0

    _mnt7_parent_disk "$ROOT"
    root_disk="$_MNT7_DISK"

    _MNT7_DEVICE=''
    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die 'Too many invalid answers for the Windows EFI partition; nothing was mounted.'
        fi
        raw=$(read_answer 'Windows EFI partition (for example /dev/sda1): ' '')
        raw="${raw//[[:space:]]/}"
        if [[ -z $raw ]]; then
            log_warn 'Empty answer. Type the Windows EFI partition, for example /dev/sda1.'
            continue
        fi
        dev="$raw"
        if [[ $dev != /dev/* ]]; then
            dev="/dev/${dev}"
        fi
        if ! _mnt7_require_partition "$dev"; then
            log_warn "Cannot use ${dev}: ${_MNT7_REASON}. Please try again."
            continue
        fi
        # WESP is not an install target, but it is mounted for the whole
        # install and written into fstab, so it follows the same loop policy.
        _mnt7_loop_guard "$dev"
        _mnt7_fs_type "$dev"
        fstype="$_MNT7_FSTYPE"
        if [[ $fstype != 'vfat' ]]; then
            log_warn "${dev} holds ${fstype:-no recognised filesystem}, not vfat."
            log_warn 'A Windows ESP is always FAT32; an ESP from another OS or an empty partition may still work.'
            _mnt7_ask_yes_no "Use ${dev} as the Windows ESP anyway?" 'n'
            if [[ $_MNT7_ANSWER != 'y' ]]; then
                continue
            fi
        fi
        _mnt7_parent_disk "$dev"
        win_disk="$_MNT7_DISK"
        if [[ -n $win_disk && -n $root_disk && $win_disk != "$root_disk" ]]; then
            log_warn "${dev} is on ${win_disk}, a different disk than the root filesystem (${root_disk})."
            log_warn 'That is normal when Windows sits on another drive, but it is easy to mistype.'
            _mnt7_ask_yes_no "Mount ${dev} as the Windows ESP anyway?" 'n'
            if [[ $_MNT7_ANSWER != 'y' ]]; then
                continue
            fi
        fi
        _MNT7_DEVICE="$dev"
        return 0
    done
}

# ---------------------------------------------------------------------------
# mounting
# ---------------------------------------------------------------------------
# _mnt7_mount_subvol <subvol> <mountpoint>
_mnt7_mount_subvol() {
    local subvol="$1"
    local target="$2"

    mount -m -t btrfs -o "subvol=${subvol},${AIT_MNT7_BTRFS_OPTS}" "$ROOT" "$target" \
        || die "Failed to mount the ${subvol} subvolume of ${ROOT} at ${target}."
}

# _mnt7_mount_all - the five mounts of stage 7, in dependency order
_mnt7_mount_all() {
    # The root subvolume must be first: mount -m creates /mnt/home and friends
    # inside it, so they land on the right subvolume instead of the live ISO.
    mount -t btrfs -o "subvol=/@,${AIT_MNT7_BTRFS_OPTS}" "$ROOT" "$AIT_MNT_ROOT" \
        || die "Failed to mount the root subvolume (@) of ${ROOT} at ${AIT_MNT_ROOT}."
    log_ok "Root subvolume mounted: ${ROOT} (@) -> ${AIT_MNT_ROOT}."

    _mnt7_mount_subvol '/@home' "$AIT_MNT_HOME"
    _mnt7_mount_subvol '/@snapshots' "$AIT_MNT_SNAPSHOTS"
    _mnt7_mount_subvol '/@home_snapshots' "$AIT_MNT_HOME_SNAPSHOTS"
    log_ok 'Home and snapshot subvolumes mounted.'

    mount -m "$ESP" "$AIT_MNT_EFI" \
        || die "Failed to mount the EFI system partition ${ESP} at ${AIT_MNT_EFI}."
    log_ok "EFI system partition mounted: ${ESP} -> ${AIT_MNT_EFI}."
}

# _mnt7_check_subvol <mountpoint> <expected subvol>
_mnt7_check_subvol() {
    local target="$1"
    local want="$2"
    local opts=''
    local got=''

    opts=$(findmnt -rn -o OPTIONS --target "$target" 2>/dev/null || true)
    if [[ -z $opts ]]; then
        die "${target} is not mounted after the mount step."
    fi
    got=$(printf '%s\n' "$opts" | tr ',' '\n' | grep '^subvol=' | head -n 1)
    if [[ $got != "subvol=${want}" ]]; then
        die "${target} uses '${got:-no subvol=}' but 'subvol=${want}' was expected."
    fi
}

# _mnt7_verify_all - re-reads the kernel mount table instead of trusting mount
_mnt7_verify_all() {
    _mnt7_check_subvol "$AIT_MNT_ROOT" '/@'
    _mnt7_check_subvol "$AIT_MNT_HOME" '/@home'
    _mnt7_check_subvol "$AIT_MNT_SNAPSHOTS" '/@snapshots'
    _mnt7_check_subvol "$AIT_MNT_HOME_SNAPSHOTS" '/@home_snapshots'

    if [[ -z $(findmnt -rn -o TARGET --target "$AIT_MNT_EFI" 2>/dev/null) ]]; then
        die "${AIT_MNT_EFI} is not mounted after the mount step."
    fi
    log_ok 'Mount table verified: @, @home, @snapshots, @home_snapshots and the ESP are in place.'
}

# ---------------------------------------------------------------------------
# dual boot
# ---------------------------------------------------------------------------
# _mnt7_handle_dual_boot - asks the question and mounts the Windows ESP
_mnt7_handle_dual_boot() {
    local dev=''

    _mnt7_ask_yes_no 'Do you also boot Windows on this machine (dual boot)?' 'n'
    if [[ $_MNT7_ANSWER != 'y' ]]; then
        WESP=''
        log_info 'No dual boot: the Windows EFI partition is not needed.'
        return 0
    fi

    _mnt7_show_partitions
    _mnt7_ask_windows_esp
    dev="$_MNT7_DEVICE"
    WESP="$dev"

    if [[ $dev == "$ESP" ]]; then
        log_info "${dev} is the very same partition as ${ESP}; it is already mounted at ${AIT_MNT_EFI}."
        log_info 'Not mounting it twice - a second mount would add a duplicate fstab entry with the same UUID.'
        return 0
    fi

    mount -m "$dev" "$AIT_MNT_WINDOWS_EFI" \
        || die "Failed to mount the Windows EFI partition ${dev} at ${AIT_MNT_WINDOWS_EFI}."
    log_ok "Windows EFI partition mounted: ${dev} -> ${AIT_MNT_WINDOWS_EFI}."
}

# ---------------------------------------------------------------------------
# stage entry point
# ---------------------------------------------------------------------------
# stage_07_mount - Plan-Main.md stage 7 entry point (no arguments).
stage_07_mount() {
    printf '\n' >&2
    log_info 'Stage 7: second mount and dual boot handling'

    _mnt7_require_var 'ROOT' "${ROOT:-}"
    _mnt7_require_var 'ESP' "${ESP:-}"
    # The loop guard runs before the partition check so that a loop image is
    # reported as "loop devices are not supported" instead of "not a partition".
    _mnt7_loop_guard "$ROOT"
    _mnt7_loop_guard "$ESP"
    _mnt7_check_mnt_clean

    if ! _mnt7_require_partition "$ROOT"; then
        die "ROOT=${ROOT} is not usable: ${_MNT7_REASON}."
    fi
    if ! _mnt7_require_partition "$ESP"; then
        die "ESP=${ESP} is not usable: ${_MNT7_REASON}."
    fi
    if [[ $ESP == "$ROOT" ]]; then
        die "ESP and ROOT point at the same device (${ESP}); they must differ."
    fi

    _mnt7_mount_all
    _mnt7_verify_all
    _mnt7_handle_dual_boot

    export WESP
    if [[ -n $WESP ]]; then
        log_ok "Stage 7 finished: root subvolumes and ESP mounted, Windows ESP=${WESP}."
    else
        log_ok 'Stage 7 finished: root subvolumes and ESP mounted, no dual boot.'
    fi
}
