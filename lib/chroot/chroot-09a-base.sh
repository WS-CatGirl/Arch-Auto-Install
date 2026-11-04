#!/usr/bin/env bash
#
# lib/chroot/chroot-09a-base.sh - stage 9 part A: base configuration, executed
# INSIDE the freshly installed system (after arch-chroot), never on the Live ISO.
#
# Implements Plan-Main.md section 9 steps 1-6 (source lines 433-441):
#   * pacman-key --init and pacman-key --populate archlinux
#   * Asia/Shanghai timezone plus hwclock --systohc
#   * en_US.UTF-8 / zh_CN.UTF-8 locale generation and LANG=en_US.UTF-8
#   * hostname prompt (RFC 1123 label) and the 127.0.1.1 line in /etc/hosts
#   * mkinitcpio MODULES=(btrfs) and the systemd HOOKS style
#   * mkinitcpio -P to regenerate every initramfs image
#
# Every path is resolved through ${AIT_TARGET_ROOT}: empty on a real
# installation (the chroot root really is /), a scratch directory during the
# tests.  No path in this module is hard-coded to /etc.
#
# Coding contract (Plan-Main.md appendix J): values come back through global
# variables (_CH9_*), no function writes diagnostics to stdout, every case has
# a *) arm, every prompt loop stops after 5 invalid answers and every /dev/tty
# write goes through a helper with a stderr fallback.  Runtime text is pure
# ASCII (appendix C: the TTY has no CJK fonts).
#
# errexit / nounset / pipefail are already enabled by chroot/chroot-install.sh;
# this module is sourced, never executed.

# Target root prefix.  Empty string means the real "/"; a path such as
# /tmp/t48-root is used by the test suite to keep every write inside scratch.
AIT_TARGET_ROOT="${AIT_TARGET_ROOT:-}"

# Fixed values from Plan-Main.md section 9 steps 3, 4 and 6.
AIT_CH9_ZONEINFO='/usr/share/zoneinfo/Asia/Shanghai'
AIT_CH9_LOCALES='en_US.UTF-8 zh_CN.UTF-8'
AIT_CH9_LANG='en_US.UTF-8'
AIT_CH9_MODULES_LINE='MODULES=(btrfs)'

# Kept in sync with dependence/mkinitcpio.conf (Arch default, no sd-encrypt:
# this installer only handles plain Btrfs subvolumes, never LUKS).
AIT_CH9_HOOKS_LINE='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)'

# ---------------------------------------------------------------------------
# result variables - see appendix J-1, never return values through stdout
# ---------------------------------------------------------------------------
_CH9_HOSTNAME=''       # validated hostname from _ch9_ask_hostname
_CH9_REASON=''         # why a hostname is rejected, set by _ch9_hostname_valid
_CH9_HOOKS_STYLE=''    # systemd | replaced, set by _ch9_mkinitcpio
_CH9_HOSTS_ACTION=''   # replaced | appended, set by _ch9_write_hostname

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
# _ch9_print_tty <text>
# Prints one block of text on the controlling terminal; without one it falls
# back to stderr and common.sh explains that once (appendix J-7).
_ch9_print_tty() {
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
# step 2: pacman keyring
# ---------------------------------------------------------------------------
_ch9_pacman_key() {
    log_info 'Initialising the pacman keyring and trusting the Arch Linux keys.'
    pacman-key --init || die 'pacman-key --init failed; the keyring was not created.'
    pacman-key --populate archlinux || die 'pacman-key --populate archlinux failed; the Arch keys are not trusted.'
    log_ok 'The pacman keyring is initialised and populated.'
}

# ---------------------------------------------------------------------------
# step 3: timezone and hardware clock
# ---------------------------------------------------------------------------
_ch9_timezone() {
    local etc="${AIT_TARGET_ROOT}/etc"
    local link="${etc}/localtime"

    if [[ ! -e $AIT_CH9_ZONEINFO ]]; then
        die "Timezone data not found: ${AIT_CH9_ZONEINFO}"
    fi
    ln -sfn -- "$AIT_CH9_ZONEINFO" "$link" || die "Cannot point ${link} at ${AIT_CH9_ZONEINFO}."
    log_ok "Timezone set to Asia/Shanghai (${link})."

    # hwclock writes the system clock into the RTC.  It fails on virtualised
    # guests without an emulated RTC, so a failure is a warning, not a reason
    # to abort a finished installation.
    if ! hwclock --systohc; then
        log_warn 'hwclock --systohc failed; the RTC still holds its previous time.'
    else
        log_ok 'The hardware clock was synchronised from the system clock.'
    fi
}

# ---------------------------------------------------------------------------
# step 4: locale generation
# ---------------------------------------------------------------------------
_ch9_locale() {
    local etc="${AIT_TARGET_ROOT}/etc"
    local locale_gen="${etc}/locale.gen"
    local locale_conf="${etc}/locale.conf"
    local name=''

    if [[ ! -e $locale_gen ]]; then
        die "Locale list not found: ${locale_gen}"
    fi

    # Uncomment "#en_US.UTF-8 UTF-8" and "#zh_CN.UTF-8 UTF-8".  The pattern
    # tolerates extra blanks and a missing leading '#'.
    sed -i -E \
        -e 's/^#[[:space:]]*(en_US\.UTF-8[[:space:]]+UTF-8)/\1/' \
        -e 's/^#[[:space:]]*(zh_CN\.UTF-8[[:space:]]+UTF-8)/\1/' \
        "$locale_gen" || die "Cannot update ${locale_gen}."

    # A trimmed locale.gen may lack the line entirely; add it instead of
    # failing halfway through the stage.
    for name in $AIT_CH9_LOCALES; do
        if ! grep -qE "^${name//./\\.}([[:space:]]+UTF-8)" "$locale_gen"; then
            printf '%s UTF-8\n' "$name" >>"$locale_gen" || die "Cannot append ${name} to ${locale_gen}."
            log_warn "${name} was missing from locale.gen and has been appended."
        fi
        if ! grep -qE "^${name//./\\.}([[:space:]]+UTF-8)" "$locale_gen"; then
            die "${name} is still commented out in ${locale_gen}."
        fi
    done
    log_ok 'en_US.UTF-8 and zh_CN.UTF-8 are enabled in locale.gen.'

    locale-gen || die 'locale-gen failed; the locales were not generated.'
    log_ok 'Locales generated.'

    printf 'LANG=%s\n' "$AIT_CH9_LANG" >"$locale_conf" || die "Cannot write ${locale_conf}."
    log_ok "LANG=${AIT_CH9_LANG} written to ${locale_conf}."
}

# ---------------------------------------------------------------------------
# step 5: hostname
# ---------------------------------------------------------------------------
# _ch9_hostname_valid <name>
# Checks an RFC 1123 host label: 1-63 characters, letters/digits/hyphens,
# starting and ending with a letter or digit.  The reason goes to _CH9_REASON
# (appendix J-1) so the caller can log it without touching stdout.
_ch9_hostname_valid() {
    local name="$1"
    local re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

    _CH9_REASON=''
    if [[ -z $name ]]; then
        _CH9_REASON='the hostname is empty'
        return 1
    fi
    if [[ ${#name} -gt 63 ]]; then
        _CH9_REASON='the hostname is longer than 63 characters'
        return 1
    fi
    if [[ ! $name =~ $re ]]; then
        _CH9_REASON="'${name}' is not an RFC 1123 label (letters, digits and '-'; it must start and end with a letter or a digit)"
        return 1
    fi
    return 0
}

# _ch9_ask_hostname - prompt with the default "arch", 5 invalid answers max
_ch9_ask_hostname() {
    local answer=''
    local tries=0

    _CH9_HOSTNAME=''
    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die 'No valid hostname was entered after 5 attempts; nothing was changed.'
        fi
        answer=$(read_answer 'Hostname [arch]: ' 'arch')
        if _ch9_hostname_valid "$answer"; then
            _CH9_HOSTNAME="$answer"
            log_ok "Hostname set to '${_CH9_HOSTNAME}'."
            return 0
        fi
        log_warn "Invalid hostname: ${_CH9_REASON}"
    done
}

# _ch9_write_hostname - /etc/hostname plus the 127.0.1.1 line in /etc/hosts
_ch9_write_hostname() {
    local etc="${AIT_TARGET_ROOT}/etc"
    local hosts_file="${etc}/hosts"

    printf '%s\n' "$_CH9_HOSTNAME" >"${etc}/hostname" || die "Cannot write ${etc}/hostname."
    log_ok "Hostname written to ${etc}/hostname."

    if [[ ! -e $hosts_file ]]; then
        printf '127.0.0.1 localhost\n::1 localhost\n' >"$hosts_file" || die "Cannot create ${hosts_file}."
        log_warn "${hosts_file} was missing and has been created."
    fi

    # Keep exactly one 127.0.1.1 line: rewrite it when present, append otherwise.
    if grep -qE '^127\.0\.1\.1([[:space:]]|$)' "$hosts_file"; then
        sed -i -E "s|^127\.0\.1\.1([[:space:]].*)?$|127.0.1.1 ${_CH9_HOSTNAME}|" "$hosts_file" \
            || die "Cannot update the 127.0.1.1 line in ${hosts_file}."
        _CH9_HOSTS_ACTION='replaced'
    else
        printf '127.0.1.1 %s\n' "$_CH9_HOSTNAME" >>"$hosts_file" || die "Cannot append to ${hosts_file}."
        _CH9_HOSTS_ACTION='appended'
    fi
    log_ok "127.0.1.1 ${_CH9_HOSTNAME} recorded in ${hosts_file} (${_CH9_HOSTS_ACTION})."
}

# ---------------------------------------------------------------------------
# step 6: mkinitcpio
# ---------------------------------------------------------------------------
# _ch9_hooks_is_systemd <conf>
# Succeeds when the HOOKS line already contains the "systemd" hook, i.e. the
# line is in the systemd style this installer wants.  An unknown or missing
# line is a failure and the caller then rewrites it.  The detected style lands
# in _CH9_HOOKS_STYLE.
_ch9_hooks_is_systemd() {
    local conf="$1"
    local line=''
    local hooks=''
    local hook=''

    line=$(grep -E '^HOOKS=' "$conf" 2>/dev/null | tail -n 1 || true)
    if [[ -z $line ]]; then
        _CH9_HOOKS_STYLE='missing'
        return 1
    fi
    hooks=$(printf '%s\n' "$line" | sed -E 's/^HOOKS=\((.*)\)[[:space:]]*$/\1/')
    for hook in $hooks; do
        if [[ $hook == 'systemd' ]]; then
            _CH9_HOOKS_STYLE='systemd'
            return 0
        fi
    done
    _CH9_HOOKS_STYLE='udev'
    return 1
}

_ch9_mkinitcpio() {
    local etc="${AIT_TARGET_ROOT}/etc"
    local conf="${etc}/mkinitcpio.conf"
    local hooks_line=''

    if [[ ! -e $conf ]]; then
        die "mkinitcpio configuration not found: ${conf}"
    fi

    # 6-1: MODULES=(btrfs) - replace the line when present, append otherwise.
    if grep -qE '^MODULES=' "$conf"; then
        sed -i -E "s|^MODULES=.*|${AIT_CH9_MODULES_LINE}|" "$conf" || die "Cannot update MODULES in ${conf}."
    else
        printf '%s\n' "$AIT_CH9_MODULES_LINE" >>"$conf" || die "Cannot append MODULES to ${conf}."
    fi
    log_ok "MODULES=(btrfs) is set in ${conf}."

    # 6-2: keep a systemd-style HOOKS line as it is, otherwise install ours.
    if _ch9_hooks_is_systemd "$conf"; then
        _CH9_HOOKS_STYLE='systemd'
        log_ok 'HOOKS already uses the systemd style; the line is kept as it is.'
    else
        if grep -qE '^HOOKS=' "$conf"; then
            sed -i -E "s|^HOOKS=.*|${AIT_CH9_HOOKS_LINE}|" "$conf" || die "Cannot update HOOKS in ${conf}."
        else
            printf '%s\n' "$AIT_CH9_HOOKS_LINE" >>"$conf" || die "Cannot append HOOKS to ${conf}."
        fi
        _CH9_HOOKS_STYLE='replaced'
        log_ok 'HOOKS replaced with the Arch systemd preset (no sd-encrypt).'
    fi

    # 6-3: per-item verification before touching the initramfs.
    if ! grep -qxF -e "$AIT_CH9_MODULES_LINE" "$conf"; then
        die "${conf} does not hold '${AIT_CH9_MODULES_LINE}' after the update."
    fi

    hooks_line=$(grep -E '^HOOKS=' "$conf" | tail -n 1 || true)
    case $_CH9_HOOKS_STYLE in
        'systemd')
            # A kept line may legitimately differ from the preset (extra hooks),
            # so only the systemd hook itself is required here.
            case $hooks_line in
                *systemd*) ;;
                *) die "The HOOKS line lost the systemd hook: '${hooks_line}'." ;;
            esac
            ;;
        'replaced')
            if [[ $hooks_line != "$AIT_CH9_HOOKS_LINE" ]]; then
                die "The HOOKS line is '${hooks_line}' instead of '${AIT_CH9_HOOKS_LINE}'."
            fi
            ;;
        *)
            die "Internal error: unknown HOOKS handling '${_CH9_HOOKS_STYLE}'; nothing was changed."
            ;;
    esac
    log_ok 'mkinitcpio.conf verified (MODULES and HOOKS).'

    mkinitcpio -P || die 'mkinitcpio -P failed; the initramfs images were not generated.'
    log_ok 'Initramfs images regenerated with mkinitcpio -P.'
}

# ---------------------------------------------------------------------------
# entry point - called by chroot/chroot-install.sh
# ---------------------------------------------------------------------------
chroot_09a_base() {
    log_info 'Stage 9A: base configuration inside the target system.'

    if [[ $EUID -ne 0 ]]; then
        die 'Stage 9A must run as root inside the chroot; nothing was changed.'
    fi

    _ch9_pacman_key
    _ch9_timezone
    _ch9_locale
    _ch9_ask_hostname
    _ch9_write_hostname
    _ch9_mkinitcpio

    log_ok 'Stage 9A finished: keyring, timezone, locale, hostname and mkinitcpio are configured.'
}
