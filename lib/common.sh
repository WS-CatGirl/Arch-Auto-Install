#!/usr/bin/env bash
#
# lib/common.sh - helpers shared by both installation stages.
#
# Conventions (Plan-Main.md appendix C):
#   * every runtime message is pure ASCII (the TTY has no CJK fonts)
#   * log labels are uppercase and padded to six characters: [INFO  ] [ OK   ]
#   * messages go to the terminal and, when a log file is active, to that file

# ---------------------------------------------------------------------------
# colors - disabled when stdout is not a terminal
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # AIT_C_* are consumed by the stage modules
if [[ -t 1 ]]; then
    AIT_C_RESET=$'\033[0m'
    AIT_C_BOLD=$'\033[1m'
    AIT_C_BLUE=$'\033[1;34m'
    AIT_C_CYAN=$'\033[1;36m'
    AIT_C_GREEN=$'\033[1;32m'
    AIT_C_YELLOW=$'\033[1;33m'
    AIT_C_RED=$'\033[1;31m'
else
    AIT_C_RESET=''
    AIT_C_BOLD=''
    AIT_C_BLUE=''
    AIT_C_CYAN=''
    AIT_C_GREEN=''
    AIT_C_YELLOW=''
    AIT_C_RED=''
fi

: "${AIT_NAME:=Arch-Auto-Install}"
: "${AIT_VERSION:=beta v0.1}"

# Empty means "do not duplicate output into a file".
AIT_LOG_FILE="${AIT_LOG_FILE:-}"

# ---------------------------------------------------------------------------
# log primitives
#
# CONTRACT - every log line goes to stderr, never to stdout.
#   * Callers capture helper results with x=$(helper), so anything a helper
#     writes to stdout ends up inside $x.  A log line leaking into stdout
#     silently corrupts that value: every case branch misses and the code
#     slides into the wrong (sometimes destructive) path.  That is exactly how
#     the t14 / t16 / t21 incidents happened.
#   * Therefore a function that returns a value on stdout must never log.
#     Pass values back through a global variable instead - _DISK_ANSWER,
#     _FMT_ACTION, _MIRROR_CHOICE are the established examples - or print the
#     value and nothing else.
#   * _ait_emit keeps appending to AIT_LOG_FILE when it is set; that copy is
#     file-only and unaffected by the stream choice above.
# ---------------------------------------------------------------------------
_ait_emit() {
    local label="$1"
    local color="$2"
    shift 2
    printf '%b[%s]%b %s\n' "$color" "$label" "$AIT_C_RESET" "$*" >&2
    if [[ -n $AIT_LOG_FILE ]]; then
        printf '[%s] %s\n' "$label" "$*" >>"$AIT_LOG_FILE" 2>/dev/null || true
    fi
}

log_info()   { _ait_emit 'INFO  ' "$AIT_C_CYAN"   "$@"; }
log_ok()     { _ait_emit ' OK   ' "$AIT_C_GREEN"  "$@"; }
log_warn()   { _ait_emit 'WARN  ' "$AIT_C_YELLOW" "$@"; }
log_error()  { _ait_emit 'ERROR ' "$AIT_C_RED"    "$@"; }
log_danger() { _ait_emit 'DANGER' "$AIT_C_RED"    "$@"; }

die() {
    log_error "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# interactive helpers - always talk to /dev/tty, never to redirected stdout
#
# When there is no controlling terminal (setsid, CI, cron) /dev/tty cannot be
# opened, so prompts fall back to stderr and answers are read from stdin.
# The fallback notice MUST stay on stderr: callers capture the answer with
# $(read_answer ...), so anything written to stdout would end up inside the
# captured value and silently corrupt menu decisions.
# ---------------------------------------------------------------------------
AIT_NO_TTY_WARNED=0

# _ait_tty_usable - succeeds when /dev/tty can be opened for reading
_ait_tty_usable() {
    { : </dev/tty; } 2>/dev/null
}

# _ait_tty_notice - explain the fallback once per run, always on stderr
_ait_tty_notice() {
    local msg='No controlling terminal (/dev/tty is not usable); prompts go to stderr and answers are read from stdin.'
    local marker=''

    if [[ $AIT_NO_TTY_WARNED -ne 0 ]]; then
        return 0
    fi
    AIT_NO_TTY_WARNED=1
    # read_answer runs inside $(...), i.e. a subshell, so the variable above is
    # not shared with the parent shell. $$ survives subshells, so the first
    # notice is also recorded in a per-process marker file to stay quiet later.
    marker="${TMPDIR:-/tmp}/.ait-no-tty-$$"
    if [[ -e $marker ]]; then
        return 0
    fi
    : >"$marker" 2>/dev/null || true
    printf '%b[%s]%b %s\n' "$AIT_C_YELLOW" 'WARN  ' "$AIT_C_RESET" "$msg" >&2
    if [[ -n $AIT_LOG_FILE ]]; then
        printf '[%s] %s\n' 'WARN  ' "$msg" >>"$AIT_LOG_FILE" 2>/dev/null || true
    fi
}

pause() {
    # NOTE: the default must not be wrapped in extra quotes - inside ${1:-...}
    # a single quote is a literal character, not a quoting operator, so the
    # old form printed the quotes into the prompt.
    local prompt="${1:-Press Enter to continue...}"

    if _ait_tty_usable; then
        printf '%s' "$prompt" >/dev/tty
        IFS= read -r _ </dev/tty || true
        return 0
    fi
    _ait_tty_notice
    printf '%s' "$prompt" >&2
    IFS= read -r _ || true
}

# read_answer <prompt> [default]
# Prints the answer on stdout so callers can capture it with $(...).
read_answer() {
    local prompt="$1"
    local default="${2:-}"
    local answer=''

    if _ait_tty_usable; then
        printf '%s' "$prompt" >/dev/tty
        IFS= read -r answer </dev/tty || answer=''
    else
        _ait_tty_notice
        printf '%s' "$prompt" >&2
        IFS= read -r answer || answer=''
    fi
    if [[ -z $answer ]]; then
        answer="$default"
    fi
    printf '%s\n' "$answer"
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------
# Usage: ait_require_file <path> <hint>
ait_require_file() {
    local path="$1"
    local hint="${2:-}"
    if [[ ! -e $path ]]; then
        if [[ -n $hint ]]; then
            die "Required path not found: ${path} (${hint})"
        fi
        die "Required path not found: ${path}"
    fi
}
