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
# ---------------------------------------------------------------------------
_ait_emit() {
    local label="$1"
    local color="$2"
    shift 2
    printf '%b[%s]%b %s\n' "$color" "$label" "$AIT_C_RESET" "$*"
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
# ---------------------------------------------------------------------------
pause() {
    # NOTE: the default must not be wrapped in extra quotes - inside ${1:-...}
    # a single quote is a literal character, not a quoting operator, so the
    # old form printed the quotes into the prompt.
    local prompt="${1:-Press Enter to continue...}"
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r _ </dev/tty || true
}

# read_answer <prompt> [default]
# Prints the answer on stdout so callers can capture it with $(...).
read_answer() {
    local prompt="$1"
    local default="${2:-}"
    local answer=''

    printf '%s' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || answer=''
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
