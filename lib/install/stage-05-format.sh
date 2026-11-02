#!/usr/bin/env bash
#
# lib/install/stage-05-format.sh - stage 5: format the ESP and the root
# partition.
#
# Mirrors Config/Main/Plan-Main.md section "5." (formatting, source lines
# 221-230), with one deviation explicitly requested by the user: the plan
# formatted both partitions after a single [y/N], which can silently wipe a
# FAT32 ESP that Windows is already booting from.  Here every partition gets
# its own confirmation:
#
#   1. ESP  - if it already holds FAT32 and looks like a live ESP (it is
#             exported read-only and inspected for /EFI or /efi, or its GPT
#             partition type is the EFI system partition GUID) a red
#             three-option prompt is shown: keep it, format it anyway, or
#             abort and pick another partition
#   2. ROOT - its own Btrfs question, never reusing the ESP answer
#
# Skipping one partition only skips that partition; only an explicit "yes"
# runs `wipefs -a` followed by `mkfs`.
#
# Every runtime message is pure ASCII (Plan-Main.md appendix C).
# The function is called by lib/install/main.sh; it takes no arguments and
# reads $ESP / $ROOT set by stage 4.

AIT_FMT_ESP_LABEL='ARCH_ESP'
AIT_FMT_ROOT_LABEL='ARCH_ROOT'
AIT_FMT_ESP_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'

# _fmt_require_vars
# Both partition names come from stage 4; refuse to guess.
_fmt_require_vars() {
    local esp="${ESP:-}"
    local root="${ROOT:-}"

    if [[ -z $esp || -z $root ]]; then
        die 'ESP and ROOT are not set. Run stage 4 first so both partitions are chosen.'
    fi
    if [[ $esp == "$root" ]]; then
        die "ESP and ROOT point at the same device (${esp}); refusing to format it twice."
    fi
}

# _fmt_print_tty <text>
# Writes one block of text to the controlling terminal.  When /dev/tty cannot
# be opened the text goes to stderr instead of letting errexit kill the script
# silently.  The fallback notice is delegated to common.sh's _ait_tty_notice so
# that it lands on stderr (never stdout) and is printed only once per run, the
# same contract _mirror_print_tty (stage 3) and _disk_print_tty (stage 4) use.
_fmt_print_tty() {
    local text="$1"

    if { printf '%s\n' "$text" >/dev/tty; } 2>/dev/null; then
        return 0
    fi
    _ait_tty_notice
    printf '%s\n' "$text" >&2
}

# _fmt_loop_guard <device>
# Same policy as stage 4: loop devices are image files, so they are refused
# unless AIT_ALLOW_LOOP=1 was set for testing.
_fmt_loop_guard() {
    local dev="$1"

    case $dev in
        /dev/loop*) ;;
        *) return 0 ;;
    esac

    if [[ ${AIT_ALLOW_LOOP:-} == '1' ]]; then
        if [[ ${_FMT_LOOP_WARNED} -eq 0 ]]; then
            log_warn 'AIT_ALLOW_LOOP is set - loop devices are allowed for TESTING ONLY, never use this on a real install.'
            _FMT_LOOP_WARNED=1
        fi
        return 0
    fi

    log_danger "REFUSED: ${dev} is a loop device (an image file, not a physical disk)."
    die 'loop devices are not supported as install targets. Type the name of a real partition.'
}

# _fmt_require_partition <device> <name>
# Only partitions may be formatted: a whole disk such as /dev/sda or
# /dev/nvme0n1 is rejected before any destructive command runs.
_fmt_require_partition() {
    local dev="$1"
    local name="$2"
    local partn=''
    local type=''

    _fmt_loop_guard "$dev"
    if [[ ! -b $dev ]]; then
        die "${name} '${dev}' is not a block device."
    fi
    partn=$(lsblk -dno PARTN -- "$dev" 2>/dev/null || true)
    if [[ -z $partn ]]; then
        type=$(lsblk -dno TYPE -- "$dev" 2>/dev/null || true)
        die "${name} '${dev}' is a whole disk (type '${type:-unknown}'), not a partition. Pick a partition such as /dev/sda2 or /dev/nvme0n1p2."
    fi
}

# _fmt_fs_type <device>
# Prints the current filesystem type, empty when nothing is recognised.
_fmt_fs_type() {
    local type=''
    type=$(blkid -o value -s TYPE -- "$1" 2>/dev/null || true)
    printf '%s' "$type"
}

# _fmt_blkid_field <device> <field>
_fmt_blkid_field() {
    local value=''
    value=$(blkid -o value -s "$2" -- "$1" 2>/dev/null || true)
    printf '%s' "$value"
}

# _fmt_parttype <device>
# Prints the GPT partition type GUID in lowercase, empty when unknown.
_fmt_parttype() {
    local guid=''
    guid=$(lsblk -dno PARTTYPE -- "$1" 2>/dev/null || true)
    printf '%s' "${guid,,}"
}

# _fmt_is_vfat <fstype>
_fmt_is_vfat() {
    case "$1" in
        vfat | fat | fat32 | msdos) return 0 ;;
        *) return 1 ;;
    esac
}

# _fmt_describe <device>
# Logs the current filesystem, UUID and label so the user can recognise the
# partition before answering.
_fmt_describe() {
    local dev="$1"
    local fstype=''
    local uuid=''
    local label=''

    fstype=$(_fmt_fs_type "$dev")
    uuid=$(_fmt_blkid_field "$dev" UUID)
    label=$(_fmt_blkid_field "$dev" LABEL)
    log_info "Existing filesystem on ${dev}: type=${fstype:-(none)} uuid=${uuid:-(none)} label=${label:-(none)}"
}

# _fmt_show_layout <device>...
# Re-prints the two target partitions (Plan-Main.md line 225).
_fmt_show_layout() {
    # A freshly created filesystem is only visible to lsblk after udev has
    # settled; without this the second listing can still show an empty FSTYPE.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi
    log_info 'Current state of the target partitions:'
    lsblk -pf --output NAME,SIZE,FSTYPE,LABEL,PARTTYPE "$@" 2>/dev/null || log_warn 'lsblk could not inspect the target partitions.'
}

# _fmt_esp_in_use <device>
# Returns 0 when the partition looks like a live ESP, 1 otherwise.
# Sets _FMT_ESP_REASON to a short human readable explanation.
#
# The decisive evidence is content, not the GPT type: a freshly created ESP
# carries the "EFI System" type GUID too, so the GUID alone would make every
# new partition trigger the red warning.  The partition is exported read-only
# and an /EFI or /efi directory is looked for (a Microsoft/Boot/Windows
# subdirectory is reported as extra proof).  When the partition cannot be
# mounted its content is unknown, so it is treated as possibly in use.
_fmt_esp_in_use() {
    local dev="$1"
    local mnt=''
    local probe=''
    local in_use=1

    _FMT_ESP_REASON=''

    mnt=$(mktemp -d "${TMPDIR:-/tmp}/ait-esp.XXXXXX") || die 'Failed to create a temporary directory to inspect the ESP.'
    if mount -o ro -- "$dev" "$mnt" 2>/dev/null; then
        if [[ -d $mnt/EFI || -d $mnt/efi ]]; then
            in_use=0
            _FMT_ESP_REASON='it contains an EFI directory'
            for probe in Microsoft Boot Windows; do
                if [[ -d $mnt/EFI/$probe || -d $mnt/efi/$probe ]]; then
                    _FMT_ESP_REASON="it contains ${probe} boot files"
                    break
                fi
            done
            if [[ $(_fmt_parttype "$dev") == "$AIT_FMT_ESP_GUID" ]]; then
                _FMT_ESP_REASON="${_FMT_ESP_REASON} and its GPT type is EFI System"
            fi
        fi
        umount -- "$mnt" 2>/dev/null || log_warn "Could not unmount ${mnt}; it stays mounted read-only."
    else
        log_warn "Could not mount ${dev} read-only to inspect it; treating it as possibly in use."
        in_use=0
        _FMT_ESP_REASON='it could not be mounted read-only, so its content is unknown'
    fi
    rmdir -- "$mnt" 2>/dev/null || true
    return "$in_use"
}

# _fmt_ask_esp_action <device> <reason>
# Red three-option prompt for an ESP that already looks live.
# The answer is stored in the global _FMT_ACTION (1 keep, 2 format, 3 abort).
# Nothing is written to stdout on purpose: callers used to capture the result
# with $(...), and a single log_warn inside that capture turned the "keep"
# answer into the "format" answer, silently wiping a shared Windows ESP.
_fmt_ask_esp_action() {
    local dev="$1"
    local reason="$2"
    local choice=''
    local menu=''
    local tries=0

    menu=$(
        printf '\n'
        printf '==============================================================\n'
        printf ' DANGER: %s already holds a FAT32 filesystem and looks like\n' "$dev"
        printf ' a live EFI system partition (ESP) - most likely the one that\n'
        printf ' is shared with Windows, because %s.\n' "$reason"
        printf '\n'
        printf ' Formatting it will destroy the Windows boot loader and every\n'
        printf ' other boot entry stored on it.\n'
        printf '==============================================================\n'
        printf '  1) keep it as-is and reuse it (safe for dual boot) [DEFAULT]\n'
        printf '  2) format it as FAT32 anyway (wipes everything on it)\n'
        printf '  3) abort so you can pick another partition\n'
    )
    _fmt_print_tty "$menu"

    _FMT_ACTION=''
    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die 'Too many invalid answers for the ESP; nothing was formatted.'
        fi
        choice=$(read_answer 'Your choice [1-3]: ' '1')
        choice="${choice//[[:space:]]/}"
        case $choice in
            1 | 2 | 3)
                _FMT_ACTION="$choice"
                return 0
                ;;
            *)
                log_warn "Invalid choice '${choice}'. Please enter 1, 2 or 3."
                ;;
        esac
    done
}

# _fmt_ask_yes_no <prompt>
# Answers "y" or "n" through the global _FMT_ANSWER; anything unrecognised is
# asked again.  Diagnostics go to the log only, never to a caller's $(...).
_fmt_ask_yes_no() {
    local prompt="$1"
    local answer=''
    local tries=0

    _FMT_ANSWER=''
    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die "Too many invalid answers for '${prompt}'; nothing was formatted."
        fi
        answer=$(read_answer "${prompt} [y/N]: " 'n')
        answer="${answer,,}"
        case $answer in
            y | yes)
                _FMT_ANSWER='y'
                return 0
                ;;
            n | no | '')
                _FMT_ANSWER='n'
                return 0
                ;;
            *)
                log_warn "Please answer y or n, not '${answer}'."
                ;;
        esac
    done
}

# _fmt_handle_esp
# First independent question: the ESP only.
_fmt_handle_esp() {
    local dev="${ESP}"
    local fstype=''
    local action=''
    local answer=''

    _fmt_describe "$dev"
    fstype=$(_fmt_fs_type "$dev")

    if _fmt_is_vfat "$fstype" && _fmt_esp_in_use "$dev"; then
        _fmt_ask_esp_action "$dev" "$_FMT_ESP_REASON"
        action="${_FMT_ACTION}"
        case $action in
            1)
                log_info "ESP kept as-is (pre-existing vfat): ${dev}"
                _FMT_ESP_KEPT=1
                return 0
                ;;
            2)
                log_warn "User chose to format the existing ESP ${dev} as FAT32."
                ;;
            3)
                die 'Aborted by user. Re-run stage 4 and choose a different ESP.'
                ;;
            *)
                die "Internal error: the ESP prompt returned '${action}'. Nothing was formatted."
                ;;
        esac
    else
        if _fmt_is_vfat "$fstype"; then
            log_info "${dev} already holds FAT32 but does not look like a live ESP."
        elif [[ -n $fstype ]]; then
            log_warn "${dev} currently holds ${fstype}; the ESP must be FAT32."
        else
            log_info "${dev} currently holds no recognised filesystem."
        fi

        _fmt_ask_yes_no "Format ${dev} as FAT32 for the ESP?"
        answer="${_FMT_ANSWER}"
        case $answer in
            y) ;;
            n)
                log_info "ESP not formatted; skipping ${dev}."
                _FMT_ESP_SKIPPED=1
                return 0
                ;;
            *)
                die "Internal error: the ESP question returned '${answer}'. Nothing was formatted."
                ;;
        esac
    fi

    wipefs -a -- "$dev" || die "wipefs failed on ${dev}; no signature was removed."
    mkfs.fat -F 32 -n "$AIT_FMT_ESP_LABEL" "$dev" || die "mkfs.fat failed on ${dev}."
    log_ok "ESP formatted: ${dev} (FAT32, label ${AIT_FMT_ESP_LABEL})."
    _FMT_ESP_FORMATTED=1
}

# _fmt_handle_root
# Second independent question: the root partition only.  The ESP answer is
# never reused here.
_fmt_handle_root() {
    local dev="${ROOT}"
    local fstype=''
    local answer=''

    _fmt_describe "$dev"
    fstype=$(_fmt_fs_type "$dev")

    case $fstype in
        vfat | fat | fat32 | msdos | ntfs | ntfs3)
            log_danger "WARNING: ${dev} currently holds a ${fstype} filesystem. That is what a Windows boot or data partition looks like - double check that you picked the right partition!"
            ;;
        '')
            log_info "${dev} currently holds no recognised filesystem."
            ;;
        *)
            log_info "${dev} currently holds ${fstype}; it will be replaced by Btrfs."
            ;;
    esac

    _fmt_ask_yes_no "Format ${dev} as Btrfs for the root filesystem?"
    answer="${_FMT_ANSWER}"
    case $answer in
        y) ;;
        n)
            log_info "Root partition not formatted; skipping ${dev}."
            _FMT_ROOT_SKIPPED=1
            return 0
            ;;
        *)
            die "Internal error: the root question returned '${answer}'. Nothing was formatted."
            ;;
    esac

    wipefs -a -- "$dev" || die "wipefs failed on ${dev}; no signature was removed."
    mkfs.btrfs -f -L "$AIT_FMT_ROOT_LABEL" "$dev" || die "mkfs.btrfs failed on ${dev}."
    log_ok "Root formatted: ${dev} (Btrfs, label ${AIT_FMT_ROOT_LABEL})."
    _FMT_ROOT_FORMATTED=1
}

# _fmt_verify
# Plan-Main.md line 229: re-check the resulting filesystem types.
_fmt_verify() {
    local fstype=''

    _fmt_show_layout "$ESP" "$ROOT"

    if [[ ${_FMT_ESP_KEPT} -ne 1 ]]; then
        fstype=$(_fmt_fs_type "$ESP")
        if ! _fmt_is_vfat "$fstype"; then
            die "ESP verification failed: ${ESP} is '${fstype:-empty}', expected FAT32 (vfat)."
        fi
    fi

    fstype=$(_fmt_fs_type "$ROOT")
    if [[ $fstype != 'btrfs' ]]; then
        die "Root verification failed: ${ROOT} is '${fstype:-empty}', expected btrfs."
    fi

    if [[ ${_FMT_ESP_KEPT} -eq 1 ]]; then
        log_ok 'Filesystem check passed: ESP reused as-is (FAT32), root is Btrfs.'
    else
        log_ok 'Filesystem check passed: ESP is FAT32, root is Btrfs.'
    fi
}

# stage_05_format
# Entry point called by lib/install/main.sh.
stage_05_format() {
    _FMT_ESP_REASON=''
    _FMT_ESP_KEPT=0
    _FMT_ESP_SKIPPED=0
    _FMT_ESP_FORMATTED=0
    _FMT_ROOT_SKIPPED=0
    _FMT_ROOT_FORMATTED=0
    _FMT_LOOP_WARNED=0
    _FMT_ACTION=''
    _FMT_ANSWER=''

    log_info 'Stage 5: formatting the target partitions.'
    _fmt_require_vars
    _fmt_require_partition "${ESP}" 'ESP'
    _fmt_require_partition "${ROOT}" 'ROOT'
    _fmt_show_layout "${ESP}" "${ROOT}"

    _fmt_handle_esp
    _fmt_handle_root

    if [[ ${_FMT_ESP_SKIPPED} -eq 1 && ${_FMT_ROOT_SKIPPED} -eq 1 ]]; then
        die 'No partition was formatted: both the ESP and the root partition were skipped, so there is nothing to install into.'
    fi

    _fmt_verify
}
