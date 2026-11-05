#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh
#
# Version : v1.0.1-rc
#
# Small bootstrap entry point for github520-deploy.
#
# It does not install packages. It checks the environment, lets the user pick
# one repository source, clones that source into a temporary directory, and
# hands the terminal to install.sh.
#
# Intended public URL:
#   https://get.whitesocks-crs.top/bootstrap.sh
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

WORKDIR=""
REPO_DIR=""
REPO_URL=""
AUTH_DIR=""
ASKPASS_SCRIPT=""
GITEE_TOKEN_FILE=""
GITEE_USERNAME=""
KEEP_CLONE=0
INSTALL_STARTED=0
INTERRUPTED=0
VERSION="v1.0.1-rc"
RELEASE_CHANNEL="rc"

info() {
    printf '[ INFO ] %s\n' "$*"
}

ok() {
    printf '[  OK  ] %s\n' "$*"
}

warn() {
    printf '[ WARN ] %s\n' "$*" >&2
}

err() {
    printf '[ FAIL ] %s\n' "$*" >&2
}

die() {
    err "$*"
    exit 1
}

show_prerelease_notice() {
    printf '\n'
    printf '============================================================\n'
    printf '[ WARN ] RELEASE CANDIDATE: %s (%s)\n' "$VERSION" "$RELEASE_CHANNEL"
    printf 'This is not a Stable release. Keep backups and test before use.\n'
    printf 'Stable v1.0.1 is expected after RC validation.\n'
    printf '============================================================\n'
    printf '\n'
}

prompt_keep_clone() {
    local rc=$1
    local choice=""

    [ -d "${REPO_DIR:-}" ] || return 0

    printf '\n'
    warn "Installation failed (exit code $rc)."
    printf 'The cloned repository is still available at:\n'
    printf '  %s\n' "$REPO_DIR"
    printf '  [k] Keep it for troubleshooting (default)\n'
    printf '  [d] Delete it\n'
    printf 'Choice [k/d]: '

    if ! { exec 3</dev/tty; } 2>/dev/null; then
        warn "No interactive terminal available; keeping the clone."
        KEEP_CLONE=1
        return 0
    fi

    if ! IFS= read -r choice <&3; then
        exec 3<&-
        warn "No interactive terminal available; keeping the clone."
        KEEP_CLONE=1
        return 0
    fi
    exec 3<&-

    choice=${choice//[[:space:]]/}
    case "${choice,,}" in
        ''|k|keep)
            KEEP_CLONE=1
            ;;
        d|delete)
            KEEP_CLONE=0
            ;;
        *)
            warn "Unrecognized choice; keeping the clone."
            KEEP_CLONE=1
            ;;
    esac
}

clear_gitee_auth() {
    if [ -n "${AUTH_DIR:-}" ] && [ -d "$AUTH_DIR" ]; then
        rm -rf -- "$AUTH_DIR" 2>/dev/null || true
    fi
    AUTH_DIR=""
    ASKPASS_SCRIPT=""
    GITEE_TOKEN_FILE=""
}

cleanup() {
    local rc=$?
    trap - EXIT

    clear_gitee_auth

    if [ "${INSTALL_STARTED:-0}" -eq 1 ] &&
       [ "${INTERRUPTED:-0}" -ne 1 ] &&
       [ "$rc" -ne 0 ] &&
       [ "${KEEP_CLONE:-0}" -ne 1 ]; then
        prompt_keep_clone "$rc"
    fi

    if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        if [ "${KEEP_CLONE:-0}" -eq 1 ]; then
            printf '\n[ INFO ] Repository kept at: %s\n' "$REPO_DIR"
            printf '[ INFO ] Remove it later with: rm -rf -- %q\n' "$WORKDIR"
        else
            rm -rf -- "$WORKDIR" 2>/dev/null || true
        fi
    fi

    exit "$rc"
}

trap cleanup EXIT
trap 'INTERRUPTED=1; exit 130' INT
trap 'INTERRUPTED=1; exit 143' TERM
trap 'INTERRUPTED=1; exit 129' HUP

print_package_commands() {
    local package=$1
    local os_id="" os_like="" prefix=""

    if [ "$(id -u)" -eq 0 ]; then
        prefix=""
    else
        prefix="sudo "
    fi

    if [ -r /etc/os-release ]; then
        os_id=$(
            # shellcheck disable=SC1091
            . /etc/os-release 2>/dev/null || true
            printf '%s' "${ID:-}"
        )
        os_like=$(
            # shellcheck disable=SC1091
            . /etc/os-release 2>/dev/null || true
            printf '%s' "${ID_LIKE:-}"
        )
    fi

    case "$os_id $os_like" in
        *arch*)
            printf '  Arch Linux: %spacman -S %s\n' "$prefix" "$package"
            ;;
        *debian*|*ubuntu*)
            printf '  Debian/Ubuntu: %sapt update && %sapt install -y %s\n' \
                "$prefix" "$prefix" "$package"
            ;;
        *fedora*|*rhel*|*centos*)
            printf '  Fedora/RHEL: %sdnf install -y %s\n' "$prefix" "$package"
            ;;
        *suse*|*opensuse*)
            printf '  openSUSE: %szypper install -y %s\n' "$prefix" "$package"
            ;;
        *alpine*)
            printf '  Alpine: %sapk add %s\n' "$prefix" "$package"
            ;;
        *)
            printf '  Install %s with your distribution package manager.\n' "$package"
            ;;
    esac
}

require_linux() {
    if [ "$(uname -s 2>/dev/null || true)" != "Linux" ]; then
        err "This bootstrap only supports Linux."
        exit 1
    fi
    ok "Linux detected."
}

require_bash() {
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        err "Bash 4 or newer is required."
        exit 1
    fi
    ok "Bash ${BASH_VERSION} detected."
}

require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required to download the repository."
        print_package_commands curl
        exit 1
    fi
    ok "curl detected."
}

require_tty() {
    if ! (exec 3</dev/tty) 2>/dev/null; then
        err "An interactive terminal is required (/dev/tty is not available)."
        exit 1
    fi
    ok "Interactive terminal detected."
}

require_git() {
    if ! command -v git >/dev/null 2>&1; then
        err "git is required. Install it manually, then run this bootstrap again."
        print_package_commands git
        exit 1
    fi
    ok "Git detected: $(git --version 2>/dev/null || printf 'unknown')"
}

read_gitee_token_file() {
    local file=$1
    local mode=""
    local token=""

    [ -f "$file" ] || return 1

    mode=$(stat -c '%a' "$file" 2>/dev/null || true)
    case "$mode" in
        400|600) ;;
        *)
            warn "Gitee token file must have mode 600 or 400: $file (found ${mode:-unknown})"
            return 1
            ;;
    esac

    token=$(tr -d '\r\n' < "$file" 2>/dev/null || true)
    [ -n "$token" ] || return 1
    printf '%s' "$token"
}

prepare_gitee_auth() {
    local token="${GITEE_TOKEN:-}"
    local username="${GITEE_USERNAME:-}"
    local token_file=""
    local old_umask=""

    clear_gitee_auth

    if [ -z "$token" ]; then
        token_file="${XDG_CONFIG_HOME:-$HOME/.config}/github520-deploy/gitee-token"
        if [ -e "$token_file" ]; then
            token=$(read_gitee_token_file "$token_file" || true)
        fi
    fi

    if [ -z "$token" ]; then
        printf '\nGitee HTTPS may require login.\n'
        printf 'Create a token: https://gitee.com/profile/personal_access_tokens\n'
        printf 'Suggested scope: projects (read-only if available).\n'
        printf 'Token input is hidden; press Enter to try an anonymous clone.\n'
        printf 'Gitee token: '
        if ! IFS= read -r -s token < /dev/tty; then
            die "Failed to read the Gitee token."
        fi
        printf '\n'
        token=${token%$'\r'}
        if [ -z "$token" ]; then
            warn "No token provided; trying an anonymous Gitee clone."
            return 0
        fi
    fi

    username=${username//[[:space:]]/}
    if [ -z "$username" ]; then
        printf 'Gitee username (token owner): '
        if ! IFS= read -r username < /dev/tty; then
            die "Failed to read the Gitee username."
        fi
        username=${username//[[:space:]]/}
    fi

    if [ -z "$username" ]; then
        warn "No Gitee username provided; token authentication disabled."
        return 0
    fi

    old_umask=$(umask)
    umask 077

    if ! AUTH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/github520-gitee.XXXXXX"); then
        umask "$old_umask"
        die "Failed to create a temporary authentication directory."
    fi

    ASKPASS_SCRIPT="$AUTH_DIR/askpass.sh"
    GITEE_TOKEN_FILE="$AUTH_DIR/token"

    printf '%s' "$token" > "$GITEE_TOKEN_FILE"
    chmod 600 "$GITEE_TOKEN_FILE"

    cat > "$ASKPASS_SCRIPT" <<'ASKPASS'
#!/bin/sh
set -eu

prompt=${1:-}

case "$prompt" in
    *[Uu]sername*)
        [ -n "${GITEE_USERNAME:-}" ] || exit 1
        printf '%s\n' "$GITEE_USERNAME"
        ;;
    *[Pp]assword*|*[Tt]oken*)
        [ -n "${GITEE_TOKEN_FILE:-}" ] || exit 1
        [ -r "$GITEE_TOKEN_FILE" ] || exit 1
        token=$(tr -d '\r\n' < "$GITEE_TOKEN_FILE")
        [ -n "$token" ] || exit 1
        printf '%s\n' "$token"
        ;;
    *)
        exit 1
        ;;
esac
ASKPASS

    chmod 700 "$ASKPASS_SCRIPT"
    GITEE_USERNAME="$username"
    umask "$old_umask"

    unset token
    unset GITEE_TOKEN

    ok "Gitee token prepared."
}

select_source() {
    local choice=""

    clear_gitee_auth

    printf '\nSelect a repository source:\n'
    printf '  [1] GitHub\n'
    printf '  [2] Gitee (HTTPS token supported)\n'
    printf '  [3] GitCode (Recommended for Chinese Users)\n'
    printf '  [4] Codeberg\n'
    printf '  [5] Gitea\n'
    printf 'Choice [1-5, default 3]: '

    if ! IFS= read -r choice < /dev/tty; then
        die "Failed to read the repository selection."
    fi

    choice=${choice//[[:space:]]/}
    choice=${choice:-3}

    case "$choice" in
        1)
            REPO_URL="https://github.com/WS-CatGirl/github520-deploy.git"
            ok "Selected GitHub."
            ;;
        2)
            REPO_URL="https://gitee.com/wscatgirl/github520-deploy.git"
            ok "Selected Gitee."
            prepare_gitee_auth
            ;;
        3)
            REPO_URL="https://gitcode.com/WS_CatGirl/github520-deploy.git"
            ok "Selected GitCode."
            ;;
        4)
            REPO_URL="https://codeberg.org/WS_CatGirl/github520-deploy.git"
            ok "Selected Codeberg."
            ;;
        5)
            REPO_URL="https://gitea.com/WS-CatGirl/github520-deploy.git"
            ok "Selected Gitea."
            ;;
        *)
            die "Invalid selection: $choice"
            ;;
    esac
}

clone_repository() {
    local attempt
    local -a clone_cmd=(env "GIT_TERMINAL_PROMPT=0")

    if [ -n "${ASKPASS_SCRIPT:-}" ]; then
        clone_cmd+=(
            "GIT_ASKPASS=$ASKPASS_SCRIPT"
            "GIT_ASKPASS_REQUIRE=force"
            "GITEE_USERNAME=$GITEE_USERNAME"
            "GITEE_TOKEN_FILE=$GITEE_TOKEN_FILE"
        )
    fi
    clone_cmd+=(git -c credential.helper= clone --depth 1 --branch main "$REPO_URL" "$REPO_DIR")

    for attempt in 1 2 3; do
        info "Cloning $REPO_URL (attempt $attempt/3)..."
        if "${clone_cmd[@]}"; then
            ok "Repository cloned."
            return 0
        fi

        warn "Clone failed (attempt $attempt/3)."
        rm -rf -- "$REPO_DIR" 2>/dev/null || true
        if [ "$attempt" -lt 3 ]; then
            sleep 3
        fi
    done

    return 1
}

check_repository_files() {
    local file

    for file in install.sh Github520-Arch.sh github520-deploy.sh \
        lib/github520-common.sh lib/core.sh lib/snapshots.sh \
        lib/network.sh lib/ssh.sh lib/hosts.sh lib/systemd.sh \
        lib/uninstall.sh lib/installer.sh lib/cli.sh \
        lib/platform-arch.sh lib/platform-generic.sh; do
        if [ ! -f "$REPO_DIR/$file" ]; then
            die "Required file is missing from the repository: $file"
        fi
    done
    ok "Repository files verified."
}

prompt_reselect_source() {
    local choice=""

    while true; do
        printf '\nClone failed after 3 attempts.\n'
        printf '  [r] Select another repository source\n'
        printf '  [q] Quit\n'
        printf 'Choice [r/q]: '

        if ! IFS= read -r choice < /dev/tty; then
            die "Failed to read the repository selection."
        fi

        choice=${choice//[[:space:]]/}
        case "${choice,,}" in
            r|reselect) return 0 ;;
            q|quit) return 1 ;;
            *) warn "Enter r or q." ;;
        esac
    done
}

main() {
    show_prerelease_notice

    require_linux
    require_bash
    require_curl
    require_tty
    require_git

    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/github520-bootstrap.XXXXXX") || \
        die "Failed to create a temporary directory."
    REPO_DIR="$WORKDIR/repo"

    while true; do
        select_source
        if clone_repository; then
            clear_gitee_auth
            break
        fi

        warn "Could not clone the repository after 3 attempts."
        if ! prompt_reselect_source; then
            die "Installation cancelled by user."
        fi
    done

    check_repository_files

    info "Launching install.sh from the temporary clone..."
    INSTALL_STARTED=1
    set +e
    bash "$REPO_DIR/install.sh" < /dev/tty
    local rc=$?
    set -e
    exit "$rc"
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
