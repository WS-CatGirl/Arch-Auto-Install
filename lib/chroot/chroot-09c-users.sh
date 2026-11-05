#!/usr/bin/env bash
#
# lib/chroot/chroot-09c-users.sh - stage 9C: accounts, zram and NetworkManager.
#
# Implements the tail of Plan-Main.md section 9 ("chroot system configuration",
# source lines 463-468), items 14 to 19:
#
#   14. uncomment "# %wheel ALL=(ALL:ALL) ALL" in /etc/sudoers and validate
#       the result with visudo
#   15. ask for the root password twice (silently) and apply it with chpasswd
#   16. ask for the everyday user name, create it with
#       useradd -m -G wheel -s /bin/bash, then ask for that account password
#   17. write /etc/systemd/zram-generator.conf
#   18. systemctl enable NetworkManager
#   19. print the "leave the chroot" notice; proc/sys/dev are released by
#       arch-chroot itself, the remaining mounts are unmounted by the host in
#       stage 10 (nothing is unmounted here)
#
# Runs INSIDE the target system, i.e. after arch-chroot.  Every target path is
# prefixed with ${AIT_TARGET_ROOT:-} so the same code can be exercised against
# a throw-away fake root (empty prefix = the real system).
#
# Password handling is the dangerous part of this module and is built around
# three rules:
#   * the password is read with `read -s` into a shell variable, never through
#     `read_answer` (which echoes) and never through an argument list;
#   * it reaches chpasswd only as "user:password" on standard input, written
#     by the printf builtin, so it cannot show up in `ps`, in a temp file or in
#     a log line;
#   * every statement that touches the secret - the reads, the comparison, the
#     chpasswd pipe - runs with xtrace switched off and restored afterwards.
#     `bash -x` therefore prints no secret even when the caller traces the
#     whole installation (see _chroot9c_read_secret / _chroot9c_apply_password).
#
# Coding contract: Plan-Main.md appendix J (values returned through globals,
# no stdout diagnostics, every case has a fallback, /dev/tty only through a
# helper with a stderr fallback, interactive loops stop after 5 attempts).
# Every runtime message is pure ASCII (appendix C).  The entry point
# chroot_09c_users takes no arguments and is sourced by the chroot dispatcher.

# Global result of the user name prompt (plan item 16).
: "${CHROOT_USER_NAME:=}"

# Private state: _CHROOT9C_SECRET carries whatever was just read (one prompt),
# _CHROOT9C_PASSWORD carries the confirmed password until chpasswd consumed it.
# Both are wiped as soon as they are no longer needed.
_CHROOT9C_SECRET=''
_CHROOT9C_PASSWORD=''
_CHROOT9C_NAME_ERR=''

# ---------------------------------------------------------------------------
# terminal helpers
# ---------------------------------------------------------------------------
# _chroot9c_print_tty <text>
# Prints one block of text on the controlling terminal.  Same shape as
# _mirror_print_tty / _disk_print_tty / _fmt_print_tty / _mnt7_print_tty: when
# /dev/tty cannot be opened (setsid, CI, cron) the text falls back to stderr
# and common.sh explains that once - the fallback is never silent.
_chroot9c_print_tty() {
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
# secrets
# ---------------------------------------------------------------------------
# _chroot9c_read_secret <prompt>
# Reads one line without echo and stores it in _CHROOT9C_SECRET.  The prompt is
# not secret and is printed as usual; the answer is not echoed, not logged and
# never passed on the command line.  Tracing is suspended for the whole read so
# `bash -x` cannot print the typed value.
_chroot9c_read_secret() {
    local prompt="$1"
    local value=''
    local from_tty=0
    local xtrace_was=0

    case $- in
        *x*)
            xtrace_was=1
            set +x
            ;;
        *) ;;
    esac

    if _ait_tty_usable; then
        if { printf '%s' "$prompt" >/dev/tty; } 2>/dev/null; then
            IFS= read -r -s value </dev/tty || value=''
            { printf '\n' >/dev/tty; } 2>/dev/null || true
            from_tty=1
        fi
    fi
    if [[ $from_tty -eq 0 ]]; then
        _ait_tty_notice
        printf '%s' "$prompt" >&2
        IFS= read -r -s value || value=''
        printf '\n' >&2
    fi

    # Both assignments run while tracing is still off.
    _CHROOT9C_SECRET="$value"
    value=''

    if [[ $xtrace_was -eq 1 ]]; then
        set -x
    fi
    return 0
}

# _chroot9c_apply_password <account>
# Feeds "account:password" to chpasswd on stdin.  printf is a shell builtin, so
# the pair never appears in an argv list; chpasswd is the only process and it
# reads from its standard input.  The variable is wiped immediately afterwards.
_chroot9c_apply_password() {
    local account="$1"
    local xtrace_was=0
    local rc=0

    case $- in
        *x*)
            xtrace_was=1
            set +x
            ;;
        *) ;;
    esac

    printf '%s:%s\n' "$account" "$_CHROOT9C_PASSWORD" | chpasswd || rc=$?
    _CHROOT9C_PASSWORD=''

    if [[ $xtrace_was -eq 1 ]]; then
        set -x
    fi

    if [[ $rc -ne 0 ]]; then
        die "chpasswd failed for '${account}' (rc=${rc}); that password was NOT set."
    fi
    log_ok "Password set for '${account}'."
}

# _chroot9c_change_password <account>
# Asks twice, compares, and only then calls chpasswd.  Empty input and a
# mismatch both count as a failed attempt; after 5 attempts the module dies and
# says that nothing was changed.  The whole loop runs with xtrace disabled so
# the comparison cannot leak either value into a `bash -x` log.
_chroot9c_change_password() {
    local account="$1"
    local first=''
    local tries=0
    local xtrace_was=0

    case $- in
        *x*)
            xtrace_was=1
            set +x
            ;;
        *) ;;
    esac

    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            first=''
            _CHROOT9C_SECRET=''
            _CHROOT9C_PASSWORD=''
            if [[ $xtrace_was -eq 1 ]]; then
                set -x
            fi
            die "No matching password was entered for '${account}' after 5 attempts; that password was not changed."
        fi

        _chroot9c_read_secret "New password for ${account}: "
        first="$_CHROOT9C_SECRET"
        _CHROOT9C_SECRET=''

        _chroot9c_read_secret "Retype new password for ${account}: "

        if [[ -z $first ]]; then
            _CHROOT9C_SECRET=''
            log_warn 'An empty password is not allowed. Please retry.'
            continue
        fi
        if [[ "$_CHROOT9C_SECRET" != "$first" ]]; then
            first=''
            _CHROOT9C_SECRET=''
            log_warn 'The two passwords do not match. Please retry.'
            continue
        fi

        _CHROOT9C_PASSWORD="$_CHROOT9C_SECRET"
        _CHROOT9C_SECRET=''
        first=''
        _chroot9c_apply_password "$account"
        if [[ $xtrace_was -eq 1 ]]; then
            set -x
        fi
        return 0
    done
}

# ---------------------------------------------------------------------------
# item 14 - sudo for the wheel group
# ---------------------------------------------------------------------------
# _chroot9c_enable_wheel_sudo
# Removes the leading comment from the packaged
#   # %wheel ALL=(ALL:ALL) ALL
# rule and nothing else: the sed expression is anchored on both ends and only
# matches that exact rule, so every other commented line is left byte for byte
# identical (a one-line diff).  The edited file is then checked with visudo; a
# rejection restores the backup and aborts, because shipping a broken sudoers
# locks the user out of every administrative command.
_chroot9c_enable_wheel_sudo() {
    local sudoers="${AIT_TARGET_ROOT:-}/etc/sudoers"
    local backup="${AIT_TARGET_ROOT:-}/etc/sudoers.ait-backup"
    local out=''

    ait_require_file "$sudoers" 'pacstrap should have installed sudo'

    if grep -qE '^%wheel[[:space:]]+ALL=' "$sudoers"; then
        log_info "${sudoers} already grants the wheel group; nothing to change."
        return 0
    fi

    if ! grep -qE '^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL[[:space:]]*$' "$sudoers"; then
        die "No commented '%wheel ALL=(ALL:ALL) ALL' line was found in ${sudoers}; nothing was changed."
    fi

    if ! cp -p "$sudoers" "$backup"; then
        die "Could not back up ${sudoers}; nothing was changed."
    fi

    if ! sed -i -E 's|^#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL)[[:space:]]*$|\1|' "$sudoers"; then
        cp -f "$backup" "$sudoers" || true
        rm -f "$backup" || true
        die "Could not edit ${sudoers}; the backup was restored and nothing was changed."
    fi

    if ! out=$(visudo -c -q -f "$sudoers" 2>&1); then
        cp -f "$backup" "$sudoers" || true
        rm -f "$backup" || true
        log_error "visudo rejected the edited file: ${out:-no output}"
        die "${sudoers} would have been broken by the edit; the original file was restored. sudoers is unchanged and nothing else was touched."
    fi

    rm -f "$backup" || true
    log_ok "Uncommented the %wheel rule in ${sudoers}; visudo accepted the result."
}

# ---------------------------------------------------------------------------
# item 16 - the everyday account
# ---------------------------------------------------------------------------
# _chroot9c_username_reason <name>
# RFC1123 single label: starts with a lowercase letter, then lowercase letters,
# digits and hyphens, at most 32 characters, and must not end with a hyphen
# (useradd would otherwise reject it) or be "root".  On failure the reason is
# written to _CHROOT9C_NAME_ERR and 1 is returned; nothing is printed here, so
# the caller can decide how to report it.
_chroot9c_username_reason() {
    local name="$1"

    _CHROOT9C_NAME_ERR=''

    if [[ -z $name ]]; then
        _CHROOT9C_NAME_ERR='the name is empty'
        return 1
    fi
    if [[ ${#name} -gt 32 ]]; then
        _CHROOT9C_NAME_ERR="the name is ${#name} characters long, the limit is 32"
        return 1
    fi
    if [[ ! $name =~ ^[a-z][a-z0-9-]*$ ]]; then
        _CHROOT9C_NAME_ERR='use lowercase letters, digits and hyphens only, starting with a lowercase letter'
        return 1
    fi
    if [[ $name == *- ]]; then
        _CHROOT9C_NAME_ERR='a name must not end with a hyphen'
        return 1
    fi
    if [[ $name == 'root' ]]; then
        _CHROOT9C_NAME_ERR='root already exists, pick another name'
        return 1
    fi
    return 0
}

# _chroot9c_ask_username
# Prompts until a valid name is entered, stores it in CHROOT_USER_NAME.  Five
# attempts maximum (J-6).  read_answer is reused for the prompt: the user name
# is not a secret, so the echoed line is fine.
_chroot9c_ask_username() {
    local name=''
    local tries=0

    while :; do
        tries=$((tries + 1))
        if [[ $tries -gt 5 ]]; then
            die 'No valid user name was entered after 5 attempts; no account was created.'
        fi
        name=$(read_answer 'User name for the everyday account (lowercase, max 32 chars): ' '')
        if ! _chroot9c_username_reason "$name"; then
            log_warn "Rejected '${name}': ${_CHROOT9C_NAME_ERR}. Please retry (attempt ${tries} of 5)."
            continue
        fi
        CHROOT_USER_NAME="$name"
        log_ok "User name accepted: ${CHROOT_USER_NAME}"
        return 0
    done
}

# _chroot9c_create_user
# useradd -m -G wheel -s /bin/bash "$CHROOT_USER_NAME" (plan item 16).  An
# account that already exists is reported and kept, so a re-run after a crash
# can continue instead of failing on a duplicate uid.
_chroot9c_create_user() {
    local name="$CHROOT_USER_NAME"

    if [[ -z $name ]]; then
        die 'Internal error: CHROOT_USER_NAME is empty; nothing was changed.'
    fi
    if id -u "$name" >/dev/null 2>&1; then
        log_warn "User '${name}' already exists; useradd is skipped."
        return 0
    fi
    if ! useradd -m -G wheel -s /bin/bash "$name"; then
        die "useradd failed for '${name}'; no account was created and nothing else was changed."
    fi
    log_ok "Created '${name}' with a home directory, the wheel group and /bin/bash."
}

# ---------------------------------------------------------------------------
# item 17 - zram
# ---------------------------------------------------------------------------
# _chroot9c_write_zram_config
# Writes /etc/systemd/zram-generator.conf and then re-reads it line by line, so
# a truncated or half-written file is caught here instead of at boot.
_chroot9c_write_zram_config() {
    local dir="${AIT_TARGET_ROOT:-}/etc/systemd"
    local conf="${AIT_TARGET_ROOT:-}/etc/systemd/zram-generator.conf"
    local line=''

    if [[ ! -d $dir ]]; then
        if ! mkdir -p "$dir"; then
            die "Could not create ${dir}; zram was not configured."
        fi
    fi

    if ! cat >"$conf" <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOF
    then
        die "Could not write ${conf}; zram was not configured."
    fi

    for line in '[zram0]' 'zram-size = ram' 'compression-algorithm = zstd' 'swap-priority = 100'; do
        if ! grep -qxF "$line" "$conf"; then
            die "${conf} is missing the entry '${line}' right after writing it; zram is NOT configured."
        fi
    done

    log_ok "Wrote ${conf} ([zram0], ram-sized, zstd, swap-priority 100)."
}

# ---------------------------------------------------------------------------
# item 18 - NetworkManager
# ---------------------------------------------------------------------------
_chroot9c_enable_networkmanager() {
    if ! command -v systemctl >/dev/null 2>&1; then
        die 'systemctl is not available in the target system; NetworkManager was NOT enabled.'
    fi
    if ! systemctl enable NetworkManager; then
        die 'systemctl enable NetworkManager failed; NetworkManager is NOT enabled.'
    fi
    log_ok 'NetworkManager is enabled at boot.'
}

# ---------------------------------------------------------------------------
# item 19 - leaving the chroot (notice only)
# ---------------------------------------------------------------------------
_chroot9c_print_exit_hint() {
    local text=''
    text=$(
        printf '\n'
        printf 'All chroot configuration is done.\n'
        printf 'Leave the chroot with "exit": proc, sys and dev are released automatically.\n'
        printf 'Everything else (/mnt and its subvolumes) is unmounted by the host in stage 10.\n'
    )
    _chroot9c_print_tty "$text"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
chroot_09c_users() {
    log_info 'Stage 09C: sudoers, root password, user account, zram, NetworkManager.'

    _chroot9c_enable_wheel_sudo
    _chroot9c_change_password 'root'

    _chroot9c_ask_username
    _chroot9c_create_user
    _chroot9c_change_password "$CHROOT_USER_NAME"

    _chroot9c_write_zram_config
    _chroot9c_enable_networkmanager
    _chroot9c_print_exit_hint

    log_ok 'Stage 09C finished.'
}
