#!/usr/bin/env bash
#
# lib/install/stage-06-mount.sh - stage 6: first mount and subvolume creation.
#
# Mirrors Config/Main/Plan-Main.md section "6." (source lines 311-321):
#
#   1. mount -t btrfs "$ROOT" /mnt
#   2. btrfs subvolume create /mnt/@ /mnt/@home /mnt/@snapshots
#      /mnt/@home_snapshots
#   3. umount -R /mnt
#
# The plan says nothing about the unhappy paths, so this module adds them:
#   * /mnt must not already host somebody else's mount - the module never
#     unmounts a filesystem it did not mount itself;
#   * an existing subvolume is reported and kept, not treated as a failure,
#     so a re-run after a crash in stage 7 is safe (only a real `btrfs` error
#     such as ENOSPC or a read-only filesystem is fatal);
#   * the umount is verified against /proc/mounts and retried a few times
#     before giving up, so stage 7 never starts on a half-unmounted tree.
#
# Coding contract: Plan-Main.md appendix J (returns via globals, no stdout
# diagnostics, every case has a fallback, /dev/tty only through a fallback
# helper, private helpers prefixed _mnt_).
#
# Every runtime message is pure ASCII (Plan-Main.md appendix C).
# The function is called by lib/install/main.sh; it takes no arguments and
# reads $ROOT set by stage 4.

AIT_MNT_TARGET='/mnt'
AIT_MNT_SUBVOLUMES=( '@' '@home' '@snapshots' '@home_snapshots' )

_MNT_CREATED=0
_MNT_EXISTING=0
_MNT_LOOP_WARNED=0

# _mnt_is_mounted
# Success when $AIT_MNT_TARGET (or anything below it) is a mount point.
_mnt_is_mounted() {
    awk -v target="$AIT_MNT_TARGET" '
        $2 == target || index($2, target "/") == 1 { found = 1 }
        END { exit(found ? 0 : 1) }
    ' /proc/mounts
}

# _mnt_print_mounts
# Reports what is currently mounted under $AIT_MNT_TARGET, for the error path.
_mnt_print_mounts() {
    local entry=''

    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        log_warn "  still mounted: ${entry}"
    done < <(awk -v target="$AIT_MNT_TARGET" '
        $2 == target || index($2, target "/") == 1 { print $1 " on " $2 }
    ' /proc/mounts)
}

# _mnt_loop_guard <device>
# Same policy as stages 4 and 5: a loop device is an image file, so it is
# refused unless AIT_ALLOW_LOOP=1 was set for testing.
_mnt_loop_guard() {
    local dev="$1"

    case $dev in
        /dev/loop*) ;;
        *) return 0 ;;
    esac

    if [[ ${AIT_ALLOW_LOOP:-} == '1' ]]; then
        if [[ ${_MNT_LOOP_WARNED} -eq 0 ]]; then
            log_warn 'AIT_ALLOW_LOOP is set - loop devices are allowed for TESTING ONLY, never use this on a real install.'
            _MNT_LOOP_WARNED=1
        fi
        return 0
    fi

    log_danger "REFUSED: ${dev} is a loop device (an image file, not a physical disk)."
    die 'loop devices are not supported as install targets. Run stage 4 again and pick a real partition.'
}

# _mnt_probe_fstype <device>
# Probes the device directly instead of trusting lsblk: lsblk reports the
# filesystem from the udev/blkid cache, which still says "ext4" for a device
# that stage 5 just reformatted to btrfs until udev catches up.  blkid -p
# reads the superblock itself; an empty result means "cannot tell", which is
# not an error - mount will complain if it really is not btrfs.
_mnt_probe_fstype() {
    local dev="$1"
    local fstype=''

    if command -v blkid >/dev/null 2>&1; then
        fstype=$(blkid -p -o value -s TYPE -- "$dev" 2>/dev/null || true)
    else
        fstype=$(lsblk -dno FSTYPE -- "$dev" 2>/dev/null || true)
    fi
    _MNT_FSTYPE="$fstype"
}

# _mnt_require_root
# The root partition comes from stage 4; refuse to guess or to mount a disk.
_mnt_require_root() {
    local root="${ROOT:-}"

    if [[ -z $root ]]; then
        die 'ROOT is not set. Run stage 4 first so the root partition is chosen.'
    fi

    _mnt_loop_guard "$root"

    if [[ ! -b $root ]]; then
        die "ROOT '${root}' is not a block device."
    fi

    _mnt_probe_fstype "$root"
    if [[ -n ${_MNT_FSTYPE} && ${_MNT_FSTYPE} != 'btrfs' ]]; then
        die "ROOT '${root}' holds '${_MNT_FSTYPE}', not btrfs. Run stage 5 again and format it as Btrfs."
    fi
}

# _mnt_require_target
# /mnt is shared with the live environment, so it is never stolen from
# somebody else: a busy /mnt aborts instead of being unmounted silently.
_mnt_require_target() {
    if [[ ! -d $AIT_MNT_TARGET ]]; then
        log_info "Creating the mount point ${AIT_MNT_TARGET}."
        mkdir -p -- "$AIT_MNT_TARGET" || die "Could not create ${AIT_MNT_TARGET}."
    fi

    if _mnt_is_mounted; then
        log_error "${AIT_MNT_TARGET} already has a mounted filesystem; refusing to unmount somebody else's mount."
        _mnt_print_mounts
        die "Unmount ${AIT_MNT_TARGET} yourself (for example 'umount -R ${AIT_MNT_TARGET}') and run stage 6 again."
    fi
}

# _mnt_mount_root
_mnt_mount_root() {
    local out=''

    log_info "Mounting ${ROOT} on ${AIT_MNT_TARGET} (first mount, subvolume creation)."
    if ! out=$(mount -t btrfs "$ROOT" "$AIT_MNT_TARGET" 2>&1); then
        [[ -n $out ]] && log_warn "mount said: ${out}"
        die "Failed to mount ${ROOT} on ${AIT_MNT_TARGET}; nothing was created."
    fi
}

# _mnt_create_subvolume <name>
# Creates $AIT_MNT_TARGET/<name>; an existing subvolume is kept and reported.
_mnt_create_subvolume() {
    local name="$1"
    local path="${AIT_MNT_TARGET}/${name}"
    local out=''

    if btrfs subvolume show "$path" >/dev/null 2>&1; then
        log_info "Subvolume ${name} already exists on ${ROOT}; keeping it as-is."
        _MNT_EXISTING=$((_MNT_EXISTING + 1))
        return 0
    fi

    if ! out=$(btrfs subvolume create "$path" 2>&1); then
        [[ -n $out ]] && log_warn "btrfs said: ${out}"
        die "Failed to create the subvolume ${name} on ${ROOT}; the filesystem was left untouched."
    fi

    log_ok "Subvolume created: ${name}"
    _MNT_CREATED=$((_MNT_CREATED + 1))
}

# _mnt_create_subvolumes
_mnt_create_subvolumes() {
    local name=''

    for name in "${AIT_MNT_SUBVOLUMES[@]}"; do
        _mnt_create_subvolume "$name"
    done
}

# _mnt_verify_subvolumes
# Re-reads the filesystem instead of trusting the create calls.
_mnt_verify_subvolumes() {
    local name=''
    local missing=''

    for name in "${AIT_MNT_SUBVOLUMES[@]}"; do
        if ! btrfs subvolume show "${AIT_MNT_TARGET}/${name}" >/dev/null 2>&1; then
            missing="${missing} ${name}"
        fi
    done

    if [[ -n $missing ]]; then
        die "These subvolumes are missing after creation:${missing}. Nothing was unmounted yet."
    fi

    log_ok "All ${#AIT_MNT_SUBVOLUMES[@]} subvolumes are present on ${ROOT} (created: ${_MNT_CREATED}, already there: ${_MNT_EXISTING})."
}

# _mnt_unmount
_mnt_unmount() {
    local tries=0

    log_info "Unmounting ${AIT_MNT_TARGET}; stage 7 will mount the subvolumes properly."
    if ! umount -R "$AIT_MNT_TARGET" 2>/dev/null; then
        log_warn "umount -R ${AIT_MNT_TARGET} failed; retrying."
    fi

    while _mnt_is_mounted; do
        tries=$((tries + 1))
        if [[ $tries -ge 5 ]]; then
            _mnt_print_mounts
            die "Could not unmount ${AIT_MNT_TARGET} after 5 attempts; stopping so stage 7 does not run on a busy mount."
        fi
        sleep 1
        umount -R "$AIT_MNT_TARGET" 2>/dev/null || true
    done

    log_ok "${AIT_MNT_TARGET} is unmounted again."
}

# stage_06_mount - Plan-Main.md section 6 entry point (no arguments).
stage_06_mount() {
    _MNT_CREATED=0
    _MNT_EXISTING=0

    log_info 'Stage 6: first mount and subvolume creation.'
    _mnt_require_root
    _mnt_require_target
    _mnt_mount_root
    _mnt_create_subvolumes
    _mnt_verify_subvolumes
    _mnt_unmount
}
