#!/usr/bin/env bash
#
# lib/install/stage-04-disk.sh - stage 4: disk detection and partitioning.
#
# Implements Plan-Main.md section "4. Disk detection and partitioning"
# (source lines 199-220):
#   * list physical disks, excluding optical drives, loop/zram/ram devices and
#     anything with no medium; show the excluded ones with the reason
#   * ask whether to partition automatically or manually
#   * automatic: confirm the target disk, require the literal answer YES,
#     wipefs -a + sgdisk --zap-all, create a 1 GiB EFI system partition and a
#     root partition using the rest of the disk, refresh the kernel view and
#     read the two partition devices into $ESP and $ROOT
#   * manual: hint that no swap partition is needed (zram-generator later),
#     hand the real terminal to cfdisk (a piped stdout breaks cfdisk's window
#     size and keypad handling), then ask for the ESP and root devices
#   * both paths validate $ESP / $ROOT and refuse anything that is not a
#     partition with a partition number
#
# Safety net from the t1 audit: a disk that currently hosts the running
# system (source of / or /mnt* in /proc/mounts) is refused with a hard error
# before any destructive command, and the answer YES cannot override it.
#
# Runtime text is pure ASCII (Plan-Main.md appendix C: the TTY has no CJK
# fonts).  errexit / nounset / pipefail come from Arch-Auto-Install.sh; this
# module is sourced, never executed.

# ---------------------------------------------------------------------------
# module state
# ---------------------------------------------------------------------------
# Set by the automatic path or by the manual prompts, consumed by stage 5.
: "${ESP:=}"
: "${ROOT:=}"

# Devices that are selectable / skipped, filled by _disk_scan.
_DISK_OK=()
_DISK_SKIPPED=()
_DISK_DETAIL=()

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
_disk_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# _disk_field <device> <lsblk column> -> first value on stdout (may be empty)
_disk_field() {
    lsblk -dnro "$2" "$1" 2>/dev/null | head -n 1 || true
}

# _disk_parent_disk <device> -> whole disk that owns the device
_disk_parent_disk() {
    local device="$1"
    local disk=''

    disk=$(lsblk -snlpo NAME "$device" 2>/dev/null | tail -n 1 || true)
    if [[ -z $disk ]]; then
        disk="$device"
    fi
    printf '%s' "$disk"
}

# ---------------------------------------------------------------------------
# device classification
# ---------------------------------------------------------------------------
# _disk_unusable_reason <device> -> reason on stdout, empty when usable
_disk_unusable_reason() {
    local device="$1"
    local type=''
    local size=''
    local name=''

    type=$(_disk_field "$device" TYPE)
    size=$(_disk_field "$device" SIZE)
    name="${device##*/}"

    case $type in
        rom)
            printf '%s' 'optical drive, no writable medium'
            return 0
            ;;
        loop)
            printf '%s' 'loop device (image / snap), not a real disk'
            return 0
            ;;
        zram)
            printf '%s' 'zram swap device'
            return 0
            ;;
        ram | ramdisk)
            printf '%s' 'RAM disk, contents vanish on reboot'
            return 0
            ;;
        '')
            printf '%s' 'device cannot be inspected'
            return 0
            ;;
        # NOTE: no *) branch on purpose.  An unknown TYPE simply falls through
        # to the size/name checks below; adding a *) catch-all here would
        # short-circuit them, so please do not "fix" it.
    esac

    if [[ $size == '0B' || -z $size ]]; then
        printf '%s' 'no medium inserted or zero size'
        return 0
    fi

    case $name in
        sr[0-9]*)
            printf '%s' 'optical drive'
            return 0
            ;;
        loop[0-9]*)
            printf '%s' 'loop device'
            return 0
            ;;
        zram[0-9]* | ram[0-9]*)
            printf '%s' 'virtual memory device'
            return 0
            ;;
        # NOTE: no *) branch on purpose - unmatched names fall through to the
        # TYPE check below; a *) catch-all would hide real disks.
    esac

    if [[ $type != 'disk' ]]; then
        printf '%s' "not a whole disk (TYPE=${type})"
        return 0
    fi

    printf '%s' ''
}

# _disk_scan -> fills _DISK_OK / _DISK_SKIPPED / _DISK_DETAIL, prints nothing
_disk_scan() {
    local device=''
    local reason=''
    local size=''
    local model=''

    _DISK_OK=()
    _DISK_SKIPPED=()
    _DISK_DETAIL=()

    while IFS= read -r device; do
        [[ -n $device ]] || continue
        reason=$(_disk_unusable_reason "$device")
        if [[ -n $reason ]]; then
            _DISK_SKIPPED+=("${device}|${reason}")
            continue
        fi
        size=$(_disk_field "$device" SIZE)
        # lsblk -r escapes spaces as \x20; show them as plain spaces again.
        model=$(_disk_field "$device" MODEL)
        model="${model//\\x20/ }"
        model=$(_disk_trim "$model")
        _DISK_OK+=("$device")
        _DISK_DETAIL+=("${device}|${size}|${model}")
    done < <(lsblk -dpnro NAME 2>/dev/null || true)
}

# _disk_print_tty <text>
# Everything the user must see goes through here: /dev/tty when there is a
# controlling terminal, otherwise stderr - the shared _ait_tty_notice explains
# that fallback once per run, so this stays in sync with stage 3.
_disk_print_tty() {
    local text="$1"

    if _ait_tty_usable; then
        if { printf '%s\n' "$text" >/dev/tty; } 2>/dev/null; then
            return 0
        fi
    fi
    _ait_tty_notice
    printf '%s\n' "$text" >&2
}

# _disk_print_menu - the selectable list plus the excluded devices and reasons
_disk_print_menu() {
    local entry=''
    local device=''
    local size=''
    local model=''
    local reason=''

    _disk_print_tty ''
    _disk_print_tty 'Disks you can choose from:'
    if [[ ${#_DISK_DETAIL[@]} -eq 0 ]]; then
        _disk_print_tty '  (none)'
    fi
    for entry in "${_DISK_DETAIL[@]}"; do
        device="${entry%%|*}"
        entry="${entry#*|}"
        size="${entry%%|*}"
        model="${entry#*|}"
        if [[ -n $model ]]; then
            _disk_print_tty "$(printf '  %-16s %-8s %s' "$device" "$size" "$model")"
        else
            _disk_print_tty "$(printf '  %-16s %s' "$device" "$size")"
        fi
    done

    if [[ ${#_DISK_SKIPPED[@]} -gt 0 ]]; then
        _disk_print_tty ''
        _disk_print_tty 'Devices that are hidden on purpose:'
        for entry in "${_DISK_SKIPPED[@]}"; do
            device="${entry%%|*}"
            reason="${entry#*|}"
            _disk_print_tty "$(printf '  %-16s %s' "$device" "$reason")"
        done
    fi
    _disk_print_tty ''
}

# ---------------------------------------------------------------------------
# protections
# ---------------------------------------------------------------------------
# _disk_in_use - prints every whole disk that hosts / or a /mnt* mount
_disk_in_use() {
    local source=''
    local mountpoint=''
    local disk=''
    local -A seen=()

    while read -r source mountpoint _; do
        [[ $source == /dev/* ]] || continue
        case $mountpoint in
            / | /boot | /boot/efi | /mnt | /mnt/*) ;;
            *) continue ;;
        esac
        disk=$(_disk_parent_disk "$source")
        [[ -n $disk ]] || continue
        [[ -n ${seen[$disk]:-} ]] && continue
        seen[$disk]=1
        printf '%s\n' "$disk"
    done < /proc/mounts
}

# _disk_refuse_if_system_disk <device>
# Hard stop, not a prompt: the running system must never be repartitioned.
_disk_refuse_if_system_disk() {
    local device="$1"
    local real=''
    local disk=''
    local real_disk=''

    real=$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")

    while IFS= read -r disk; do
        [[ -n $disk ]] || continue
        real_disk=$(readlink -f "$disk" 2>/dev/null || printf '%s' "$disk")
        if [[ $real_disk == "$real" ]]; then
            log_danger "REFUSED: ${device} is the disk that currently runs this system."
            log_danger "It is mounted at / or /mnt; partitioning it would destroy the machine."
            die "Target disk ${device} is in use by the running system. Nothing was changed."
        fi
    done < <(_disk_in_use)
}

# _disk_loop_guard <device>
# Loop devices are image files, never install targets.  They are refused with a
# hard stop, whatever the user typed, unless AIT_ALLOW_LOOP=1 is set - that
# switch exists only for the WSL/CI test harness and prints a loud warning.
# Returns 0 when the device may be used, dies otherwise.
_DISK_LOOP_WARNED=0
_disk_loop_guard() {
    local device="$1"

    case $device in
        /dev/loop*) ;;
        *) return 0 ;;
    esac

    if [[ ${AIT_ALLOW_LOOP:-} == '1' ]]; then
        if [[ $_DISK_LOOP_WARNED -eq 0 ]]; then
            log_warn 'AIT_ALLOW_LOOP is set - loop devices are allowed for TESTING ONLY, never use this on a real install.'
            _DISK_LOOP_WARNED=1
        fi
        return 0
    fi

    log_danger "REFUSED: ${device} is a loop device (an image file, not a physical disk)."
    die 'loop devices are not supported as install targets. Type the name of a real disk.'
}

# _disk_validate_target <device>
# Result goes to the global _DISK_REASON; returns 0 when usable, 1 otherwise.
# Must be called directly (not via $(...)), so that die really exits.
_DISK_REASON=''
_disk_validate_target() {
    local device="$1"
    local type=''
    local size=''
    local partn=''

    _DISK_REASON=''

    if [[ ! -e $device ]]; then
        _DISK_REASON='device does not exist'
        return 1
    fi
    if [[ ! -b $device ]]; then
        _DISK_REASON='not a block device'
        return 1
    fi

    # Never a valid target unless the test switch explicitly allows it.
    _disk_loop_guard "$device"

    type=$(_disk_field "$device" TYPE)
    size=$(_disk_field "$device" SIZE)
    partn=$(_disk_field "$device" PARTN)

    if [[ $type == 'rom' ]]; then
        _DISK_REASON='optical drive, pick a hard disk instead'
        return 1
    fi
    if [[ $size == '0B' || -z $size ]]; then
        _DISK_REASON='no medium or zero size'
        return 1
    fi
    if [[ -n $partn ]]; then
        _DISK_REASON='this is a partition, not a whole disk'
        return 1
    fi

    return 0
}

# _disk_validate_partition <device> -> empty on success, reason on stdout
_disk_validate_partition() {
    local device="$1"
    local partn=''

    if [[ ! -b $device ]]; then
        printf '%s' 'not an existing block device'
        return 1
    fi

    partn=$(_disk_field "$device" PARTN)
    if [[ -z $partn ]]; then
        printf '%s' 'this is a whole disk, a partition with a partition number is required'
        return 1
    fi

    printf '%s' ''
    return 0
}

# ---------------------------------------------------------------------------
# prompts
# ---------------------------------------------------------------------------
# _disk_ask_target <prompt>
# Result goes to the global _DISK_ANSWER: the caller must not use $(...) here,
# otherwise log_warn output would be captured into the variable as well.
_DISK_ANSWER=''
_disk_ask_target() {
    local prompt="$1"
    local raw=''
    local device=''
    local tries=0

    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die 'Too many invalid disk names; nothing was changed.'
        fi
        raw=$(read_answer "${prompt} (sda or /dev/sda): ")
        raw=$(_disk_trim "$raw")
        raw="${raw#/dev/}"
        raw="${raw#/}"

        if [[ -z $raw ]]; then
            log_warn 'Empty answer. Please type the name of a disk, for example sda.'
            continue
        fi

        device="/dev/${raw}"
        if _disk_validate_target "$device"; then
            _DISK_ANSWER="$device"
            return 0
        fi
        log_warn "Cannot use ${device}: ${_DISK_REASON}. Please try again."
    done
}

# _disk_default_partition <disk> <partition number> -> device or empty
_disk_default_partition() {
    local disk="$1"
    local want="$2"
    local name=''
    local partn=''

    while read -r name partn; do
        [[ -n $name ]] || continue
        if [[ $partn == "$want" ]]; then
            printf '%s' "$name"
            return 0
        fi
    done < <(lsblk -pnro NAME,PARTN "$disk" 2>/dev/null || true)

    printf '%s' ''
}

# _disk_ask_partition <disk> <label> <default partition number>
# Result goes to the global _DISK_ANSWER (never via command substitution, which
# would swallow the log_warn lines into the value).
_disk_ask_partition() {
    local disk="$1"
    local label="$2"
    local want="$3"
    local fallback=''
    local raw=''
    local device=''
    local reason=''
    local tries=0

    fallback=$(_disk_default_partition "$disk" "$want")

    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die "Too many invalid answers for the ${label} partition; nothing was changed."
        fi
        if [[ -n $fallback ]]; then
            raw=$(read_answer "${label} partition device [${fallback}]: " "$fallback")
        else
            raw=$(read_answer "${label} partition device: ")
        fi
        raw=$(_disk_trim "$raw")
        raw="${raw#/dev/}"
        raw="${raw#/}"

        if [[ -z $raw ]]; then
            log_warn "Empty answer. Please type the ${label} device, for example ${disk}${want}."
            continue
        fi

        device="/dev/${raw}"
        _disk_loop_guard "$device"
        if reason=$(_disk_validate_partition "$device"); then
            _DISK_ANSWER="$device"
            return 0
        fi
        log_warn "Cannot use ${device}: ${reason}. Please try again."
    done
}

# ---------------------------------------------------------------------------
# destructive operations
# ---------------------------------------------------------------------------
# _disk_refresh_table <disk> - make the kernel see the new partition table
_disk_refresh_table() {
    local disk="$1"

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$disk" 2>/dev/null || log_warn "partprobe reported a problem for ${disk}; continuing."
    elif command -v partx >/dev/null 2>&1; then
        # WSL and containers ship partx but not partprobe.
        partx -u "$disk" 2>/dev/null || log_warn "partx could not update ${disk}; continuing."
    else
        log_warn 'Neither partprobe nor partx is available; relying on udevadm settle.'
    fi

    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle >/dev/null 2>&1 || true
    fi
    sleep 1
}

# _disk_load_partitions <disk> - writes $ESP and $ROOT from PARTN 1 and 2
_disk_load_partitions() {
    local disk="$1"
    local name=''
    local partn=''
    local esp=''
    local root=''

    while read -r name partn; do
        [[ -n $name ]] || continue
        case $partn in
            1) esp="$name" ;;
            2) root="$name" ;;
        esac
    done < <(lsblk -pnro NAME,PARTN "$disk" 2>/dev/null || true)

    if [[ -z $esp || -z $root ]]; then
        die "Could not read the two new partitions of ${disk}. Check 'lsblk -pf' and retry."
    fi

    ESP="$esp"
    ROOT="$root"
}

# _disk_show_disk <disk> - filtered tree view of one disk
_disk_show_disk() {
    local disk="$1"

    if ! { printf '\nCurrent layout of %s:\n' "$disk" >/dev/tty; } 2>/dev/null; then
        log_warn 'No controlling terminal (/dev/tty is not writable); showing the layout on stderr instead.'
        printf '\nCurrent layout of %s:\n' "$disk" >&2
        lsblk -pf "$disk" >&2 || true
        printf '\n' >&2
        return 0
    fi
    lsblk -pf "$disk" >/dev/tty 2>&1 || true
    printf '\n' >/dev/tty
}

# ---------------------------------------------------------------------------
# fullscreen terminal handling for cfdisk
# ---------------------------------------------------------------------------
# cfdisk needs a real terminal on stdin/stdout: with a pipe it cannot query the
# window size (the TUI is garbled) and terminfo never initialises the keypad
# (arrow keys stop working).  The installer redirects its own output, so the
# terminal is handed over for the duration of the call and the "started /
# finished" notes are the only lines that reach the log.
_disk_fullscreen_begin() {
    if ! { : </dev/tty; } 2>/dev/null; then
        return 1
    fi

    if [[ ! -t 3 ]]; then
        exec 3>/dev/tty 4>&3
    fi
    exec 5>&1 6>&2 7<&0
    exec 0</dev/tty 1>&3 2>&4
    return 0
}

_disk_fullscreen_end() {
    exec 0<&7 1>&5 2>&6
    exec 5>&- 6>&- 7<&-
}

# _disk_run_cfdisk <disk>
_disk_run_cfdisk() {
    local disk="$1"
    local status=0

    if ! command -v cfdisk >/dev/null 2>&1; then
        die 'cfdisk is not installed; manual partitioning is impossible.'
    fi

    if ! _disk_fullscreen_begin; then
        log_error 'No usable terminal was found (/dev/tty cannot be opened).'
        die 'cfdisk needs a real terminal; run this installer on the console.'
    fi

    log_info "cfdisk started on ${disk}"
    cfdisk "$disk" || status=$?
    _disk_fullscreen_end

    if [[ $status -ne 0 ]]; then
        log_warn "cfdisk exited with status ${status}."
    fi
    log_info 'cfdisk finished'
}

# ---------------------------------------------------------------------------
# the two partitioning paths
# ---------------------------------------------------------------------------
# _disk_auto_partition - Plan-Main.md 3-1
_disk_auto_partition() {
    local disk=''
    local answer=''
    local sgdisk_err=''

    _disk_scan
    _disk_print_menu

    _disk_ask_target 'Disk to partition' || return 1
    disk="$_DISK_ANSWER"

    _disk_refuse_if_system_disk "$disk"

    log_danger "!!! LAST WARNING: ${disk} WILL BE COMPLETELY ERASED !!!"
    log_danger "All partitions, all filesystems and all data on it will be destroyed."
    log_danger 'The installer will create a 1 GiB EFI partition and a root partition.'
    log_danger 'Type YES in capitals to continue, anything else cancels.'

    answer=$(read_answer "Type YES to erase ${disk}: " 'NO')
    answer=$(_disk_trim "$answer")

    if [[ $answer != 'YES' ]]; then
        log_warn 'Automatic partitioning cancelled; nothing was changed.'
        return 1
    fi

    log_info "Wiping filesystem signatures on ${disk}."
    wipefs -a "$disk" >/dev/null 2>&1 || die "wipefs failed on ${disk}."

    log_info "Zapping the partition table on ${disk}."
    if ! sgdisk_err=$(sgdisk --zap-all "$disk" 2>&1 >/dev/null); then
        [[ -z $sgdisk_err ]] || log_warn "sgdisk said: ${sgdisk_err}"
        die "sgdisk --zap-all failed on ${disk}."
    fi

    log_info 'Creating the EFI system partition (1 GiB) and the root partition.'
    if ! sgdisk_err=$(sgdisk \
        -n 1:0:+1G -t 1:ef00 -c 1:ARCH_ESP \
        -n 2:0:0 -t 2:8300 -c 2:ARCH_ROOT \
        "$disk" 2>&1 >/dev/null); then
        [[ -z $sgdisk_err ]] || log_warn "sgdisk said: ${sgdisk_err}"
        die "sgdisk failed to create the partitions on ${disk}."
    fi

    _disk_refresh_table "$disk"
    _disk_load_partitions "$disk"

    log_ok "Partitioning finished: ESP=${ESP} ROOT=${ROOT}"
    _disk_show_disk "$disk"
}

# _disk_manual_partition - Plan-Main.md 3-2
_disk_manual_partition() {
    local disk=''
    local esp_disk=''
    local root_disk=''

    _disk_scan
    _disk_print_menu

    _disk_ask_target 'Disk to partition' || return 1
    disk="$_DISK_ANSWER"

    _disk_refuse_if_system_disk "$disk"

    log_info "Manual partitioning of ${disk}."
    log_info 'Recommendation: do not create a swap partition.'
    log_info 'Swap is provided later by zram-generator, which is faster and uses no disk space.'
    log_info 'Create exactly two partitions:'
    log_info '  1) EFI system partition, type EFI System, at least 512 MiB (1 GiB is comfortable)'
    log_info '  2) Linux filesystem partition for the root filesystem, using the rest of the disk'
    pause "Press Enter to open cfdisk on ${disk}... "

    _disk_run_cfdisk "$disk"
    _disk_refresh_table "$disk"
    _disk_show_disk "$disk"

    _disk_ask_partition "$disk" 'ESP' 1 || return 1
    ESP="$_DISK_ANSWER"
    _disk_ask_partition "$disk" 'Root' 2 || return 1
    ROOT="$_DISK_ANSWER"

    # Second safety net: never accept partitions that live on the running disk.
    esp_disk=$(_disk_parent_disk "$ESP")
    root_disk=$(_disk_parent_disk "$ROOT")
    _disk_refuse_if_system_disk "$esp_disk"
    _disk_refuse_if_system_disk "$root_disk"

    log_ok "Manual partitioning finished: ESP=${ESP} ROOT=${ROOT}"
}

# ---------------------------------------------------------------------------
# result validation
# ---------------------------------------------------------------------------
_disk_final_check() {
    local reason=''

    if [[ -z ${ESP:-} ]]; then
        die 'ESP is empty; refusing to continue to formatting.'
    fi
    if [[ -z ${ROOT:-} ]]; then
        die 'ROOT is empty; refusing to continue to formatting.'
    fi

    _disk_loop_guard "$ESP"
    _disk_loop_guard "$ROOT"

    if reason=$(_disk_validate_partition "$ESP"); then
        :
    else
        die "ESP=${ESP} is not usable: ${reason}."
    fi
    if reason=$(_disk_validate_partition "$ROOT"); then
        :
    else
        die "ROOT=${ROOT} is not usable: ${reason}."
    fi

    if [[ $ESP == "$ROOT" ]]; then
        die "ESP and ROOT point at the same device (${ESP}); they must differ."
    fi

    export ESP ROOT
}

# ---------------------------------------------------------------------------
# stage entry point
# ---------------------------------------------------------------------------
# stage_04_disk - Plan-Main.md stage 4 entry point (no arguments).
stage_04_disk() {
    local choice=''
    local tries=0

    printf '\n'
    log_info 'Stage 4: disk detection and partitioning'
    log_warn 'Nothing has been written to any disk yet. Every destructive step asks first.'
    if ! { : </dev/tty; } 2>/dev/null; then
        log_warn 'No controlling terminal: this stage asks its questions on /dev/tty, so prompts are printed on stderr and answers must be piped in.'
    fi

    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die 'Too many invalid answers; aborting stage 4 without touching any disk.'
        fi
        _disk_print_tty 'How do you want to partition?'
        _disk_print_tty '  1) automatic - wipe the disk, create ESP (1 GiB) + root  [RECOMMENDED]'
        _disk_print_tty '  2) manual    - open cfdisk and create the partitions yourself'

        choice=$(read_answer 'Your choice [1-2]: ' '1')
        choice="${choice//[[:space:]]/}"

        case $choice in
            1)
                _disk_auto_partition || return 1
                _disk_final_check
                return 0
                ;;
            2)
                _disk_manual_partition || return 1
                _disk_final_check
                return 0
                ;;
            *)
                log_warn "Invalid choice '${choice}'. Please enter 1 or 2."
                ;;
        esac
    done
}
