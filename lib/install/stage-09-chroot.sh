#!/usr/bin/env bash
#
# lib/install/stage-09-chroot.sh - stage 9 host side: hand the installed system
# over to chroot/chroot-install.sh.
#
# Implements Plan-Main.md section 9 (source lines 429-469), host half:
#   1. verify that ${AIT_MNT_ROOT} really holds an installed system; usr/bin/bash
#      is the cheapest proof that pacstrap finished
#   2. copy the chroot payload to /root/arch-auto-install inside the new system:
#        chroot/chroot-install.sh   the entry point
#        lib/chroot/*.sh            the 09A / 09B / 09C modules
#        lib/common.sh              logging, die, read_answer
#      2-1. cp -a, never rsync: rsync is not in the pacstrap package list
#      2-2. /root/arch-auto-install is the ONE canonical path; chroot-install.sh
#           resolves its own repository first, so both sides agree without an
#           environment variable
#   3. arch-chroot <root> /bin/bash /root/arch-auto-install/chroot/chroot-install.sh
#      3-1. the exit status decides the stage; on failure the last lines of the
#           transcript are printed, otherwise the only symptom is "stage 9
#           failed" with no clue
#      3-2. the transcript is kept in a temp file and echoed on stderr, so this
#           module never writes to stdout (appendix J-3)
#      3-3. stdin is inherited on purpose: the chroot asks for the host name
#           once, and it must reach the terminal the user is looking at
#   4. write the stage 2 placeholder lib/config/main.sh, because the hook in
#      /root/.bash_profile (written by stage 8) runs it on every tty1 login
#      4-1. an existing file is left alone unless it carries the placeholder
#           marker - never overwrite a real stage 2 dispatcher
#
# Coding contract (Plan-Main.md appendix J): values come back through global
# variables (_CH9H_*), no function writes diagnostics to stdout, every case has
# a *) arm, every /dev/tty write goes through a helper with a stderr fallback.
# Runtime text is pure ASCII (appendix C: the TTY has no CJK fonts).
#
# errexit / nounset / pipefail are already enabled by Arch-Auto-Install.sh;
# this module is sourced, never executed.

# shellcheck disable=SC2153  # AIT_ROOT / AIT_MNT_ROOT are exported earlier

AIT_MNT_ROOT="${AIT_MNT_ROOT:-/mnt}"

# Where the chroot payload lives inside the new system.  chroot-install.sh is
# started from this very directory, so it resolves AIT_REPO_ROOT to it.
AIT_STAGE9_DEST="${AIT_MNT_ROOT}/root/arch-auto-install"
AIT_STAGE9_ENTRY='/root/arch-auto-install/chroot/chroot-install.sh'

# Stage 8 copied the whole repository to /var/lib/arch-auto-install; the stage 2
# hook in /root/.bash_profile points at the dispatcher below it.
AIT_STAGE9_CONFIG_DIR="${AIT_MNT_ROOT}/var/lib/arch-auto-install/lib/config"
AIT_STAGE9_CONFIG_MAIN="${AIT_STAGE9_CONFIG_DIR}/main.sh"
AIT_STAGE9_STUB_MARKER='# arch-auto-install stage 2 dispatcher (placeholder)'

# Files that must exist in the payload before the chroot is entered.
AIT_STAGE9_PAYLOAD=(
    chroot/chroot-install.sh
    lib/chroot/chroot-09a-base.sh
    lib/chroot/chroot-09b-boot.sh
    lib/chroot/chroot-09c-users.sh
    lib/common.sh
)

# ---------------------------------------------------------------------------
# result variables - see appendix J-1, never return values through stdout
# ---------------------------------------------------------------------------
_CH9H_STATUS=0   # exit status of the arch-chroot run
_CH9H_LOG=''     # transcript file of that run, kept only on failure
_CH9H_STUB=''    # written / kept, set by _ch9h_write_config_stub

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
# _ch9h_require_var <name> <value>
# die when a variable earlier stages must export is empty or unset.
_ch9h_require_var() {
    local name="$1"
    local value="$2"

    if [[ -n $value ]]; then
        return 0
    fi
    die "${name} is empty; an earlier stage must export it before stage 9 runs."
}

# _ch9h_verify_target
# die unless ${AIT_MNT_ROOT} is a directory holding a usable bash.
_ch9h_verify_target() {
    if [[ -z $AIT_MNT_ROOT ]]; then
        die 'AIT_MNT_ROOT is empty; stage 7 must export the mount root.'
    fi
    if [[ ! -d $AIT_MNT_ROOT ]]; then
        die "${AIT_MNT_ROOT} is not a directory; run stage 7 again."
    fi
    if [[ ! -x "${AIT_MNT_ROOT}/usr/bin/bash" ]]; then
        die "${AIT_MNT_ROOT}/usr/bin/bash is missing or not executable; stage 8 (pacstrap) did not finish."
    fi
    log_ok "Target system verified: ${AIT_MNT_ROOT}/usr/bin/bash is present."
}

# ---------------------------------------------------------------------------
# payload
# ---------------------------------------------------------------------------
# _ch9h_copy_payload - plan item 2
# Copy the entry point and its three modules into the new system.  The copy is
# idempotent: both source directories are copied with a trailing "/." so a
# second run merges into the existing tree instead of nesting chroot/chroot.
_ch9h_copy_payload() {
    local src="${AIT_ROOT:-}"
    local f=''
    local missing=()

    _ch9h_require_var 'AIT_ROOT' "$src"
    if [[ ! -d "${src}/chroot" ]]; then
        die "${src}/chroot does not exist; the repository looks incomplete."
    fi
    if [[ ! -d "${src}/lib/chroot" ]]; then
        die "${src}/lib/chroot does not exist; the repository looks incomplete."
    fi
    if [[ ! -f "${src}/lib/common.sh" ]]; then
        die "${src}/lib/common.sh does not exist; the repository looks incomplete."
    fi

    mkdir -p "${AIT_STAGE9_DEST}/chroot" "${AIT_STAGE9_DEST}/lib/chroot" \
        || die "Cannot create the payload directories below ${AIT_STAGE9_DEST}."

    cp -a "${src}/chroot/." "${AIT_STAGE9_DEST}/chroot/" \
        || die "Cannot copy ${src}/chroot to ${AIT_STAGE9_DEST}/chroot."
    cp -a "${src}/lib/chroot/." "${AIT_STAGE9_DEST}/lib/chroot/" \
        || die "Cannot copy ${src}/lib/chroot to ${AIT_STAGE9_DEST}/lib/chroot."
    cp -a "${src}/lib/common.sh" "${AIT_STAGE9_DEST}/lib/common.sh" \
        || die "Cannot copy ${src}/lib/common.sh to ${AIT_STAGE9_DEST}/lib."

    for f in "${AIT_STAGE9_PAYLOAD[@]}"; do
        if [[ ! -s "${AIT_STAGE9_DEST}/${f}" ]]; then
            missing+=("$f")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "The chroot payload is incomplete, missing: ${missing[*]}."
    fi

    log_ok "Chroot payload copied to ${AIT_STAGE9_DEST}."
}

# ---------------------------------------------------------------------------
# stage 2 hand-over placeholder
# ---------------------------------------------------------------------------
# _ch9h_write_config_stub - plan item 4
# Without this file the hook in /root/.bash_profile can only print
# "lib/config/main.sh is missing".  The placeholder says the truth instead and
# deliberately never touches state/stage2.done, so every login keeps landing
# here until the real stage 2 dispatcher replaces it.
_ch9h_write_config_stub() {
    local dir="$AIT_STAGE9_CONFIG_DIR"
    local file="$AIT_STAGE9_CONFIG_MAIN"
    local tmp=''

    if [[ -f $file ]] && ! grep -qF -- "$AIT_STAGE9_STUB_MARKER" "$file"; then
        _CH9H_STUB='kept'
        log_warn "${file} already exists and is not the stage 9 placeholder; leaving it untouched."
        return 0
    fi

    mkdir -p "$dir" || die "Cannot create ${dir}."
    tmp="$(mktemp "${TMPDIR:-/tmp}/ait-config-main.XXXXXX")" \
        || die 'Cannot create a temporary file for lib/config/main.sh.'

    cat >"$tmp" <<'EOF' || die "Cannot write ${tmp}."
#!/usr/bin/env bash
# arch-auto-install stage 2 dispatcher (placeholder)
#
# /root/.bash_profile runs this file on every tty1 login until
# /var/lib/arch-auto-install/state/stage2.done exists (see stage 8).  Stage 2
# (Plan-Main.md sections 10-16) is not written yet, so this placeholder only
# says so and returns; it deliberately never touches state/stage2.done.
#
# TODO(stage 2): source the config modules below, call them in order, and create
# state/stage2.done only after the last step succeeded.

set -o errexit -o nounset -o pipefail

# Filled in when the stage 2 modules land, e.g. stage_10_cleanup and so on.
AIT_CONFIG_FUNCS=()

_main_config() {
    local fn=''

    if (( ${#AIT_CONFIG_FUNCS[@]} == 0 )); then
        printf '[WARN  ] Stage 2 is not implemented yet; nothing to do.\n' >&2
        return 0
    fi
    for fn in "${AIT_CONFIG_FUNCS[@]}"; do
        if declare -F "$fn" >/dev/null 2>&1; then
            "$fn"
        fi
    done
}

_main_config "$@"
EOF

    install -m 755 "$tmp" "$file" || die "Cannot install ${file}."
    rm -f "$tmp"

    if ! grep -qF -- "$AIT_STAGE9_STUB_MARKER" "$file"; then
        die "${file} does not carry the placeholder marker."
    fi
    _CH9H_STUB='written'
    log_ok "Stage 2 placeholder written: ${file}."
}

# ---------------------------------------------------------------------------
# chroot run
# ---------------------------------------------------------------------------
# _ch9h_run_chroot - plan item 3
# Enter the new system and let chroot-install.sh drive 09A / 09B / 09C there.
_ch9h_run_chroot() {
    local logf=''
    local entry="${AIT_MNT_ROOT}${AIT_STAGE9_ENTRY}"

    if ! command -v arch-chroot >/dev/null 2>&1; then
        die 'arch-chroot is not available; install arch-install-scripts on the ISO.'
    fi
    if [[ ! -s $entry ]]; then
        die "${entry} is missing; the payload copy failed."
    fi

    logf="$(mktemp "${TMPDIR:-/tmp}/ait-stage9-chroot.XXXXXX")" \
        || die 'Cannot create a transcript file for the chroot run.'
    _CH9H_LOG="$logf"

    log_info "Running ${AIT_STAGE9_ENTRY} inside ${AIT_MNT_ROOT}."

    # pipefail is already on, so a non-zero exit of arch-chroot wins over tee.
    # The 2>&1 | tee pair only moves the transcript to stderr (J-3); stdin is
    # untouched, so the host name prompt still reaches the terminal.
    if arch-chroot "$AIT_MNT_ROOT" /bin/bash "$AIT_STAGE9_ENTRY" 2>&1 \
        | tee -a "$logf" >&2; then
        _CH9H_STATUS=0
    else
        _CH9H_STATUS=$?
    fi

    if (( _CH9H_STATUS == 0 )); then
        rm -f "$logf"
        _CH9H_LOG=''
        log_ok 'chroot-install.sh finished inside the new system.'
        return 0
    fi

    log_error "chroot-install.sh failed with exit status ${_CH9H_STATUS}; last lines of the transcript:"
    tail -n 20 "$logf" >&2 || true
    log_error "Full transcript kept in ${logf}."
    die 'Stage 9 aborted; the new system is only partly configured. Fix the error above and run stage 9 again.'
}

# ---------------------------------------------------------------------------
# stage entry point
# ---------------------------------------------------------------------------
# stage_09_chroot - Plan-Main.md stage 9 entry point (no arguments).
stage_09_chroot() {
    printf '\n' >&2
    log_info 'Stage 9: configure the installed system from inside the chroot'

    _ch9h_verify_target
    _ch9h_copy_payload
    _ch9h_write_config_stub
    _ch9h_run_chroot

    log_ok 'Stage 9 finished: the installed system is configured.'
}
