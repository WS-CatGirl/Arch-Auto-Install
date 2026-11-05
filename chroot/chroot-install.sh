#!/usr/bin/env bash
#
# chroot/chroot-install.sh - stage 9 entry point, executed INSIDE the target
# system, never on the Live ISO:
#
#     arch-chroot /mnt /bin/bash /root/arch-auto-install/chroot/chroot-install.sh
#
# It only wires the three stage 9 modules together:
#
#   lib/chroot/chroot-09a-base.sh   chroot_09a_base   base configuration
#   lib/chroot/chroot-09b-boot.sh   chroot_09b_boot   bootloader and services
#   lib/chroot/chroot-09c-users.sh  chroot_09c_users  users, sudo, AUR helper
#
# All three modules exist today (Plan-Main.md section 9).  A module or a step
# function that is still missing is reported and skipped, so a partial checkout
# runs the steps it does have instead of aborting the whole stage.
#
# The repository is copied into the target system by lib/install/stage-09-chroot.sh
# (the host side of stage 9) to /root/arch-auto-install, and this file resolves
# its own repository first; AIT_REPO_ROOT overrides both, which is what the
# tests do.

set -o errexit -o nounset -o pipefail

_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${AIT_REPO_ROOT:-} ]]; then
    # This file lives in <repo>/chroot/, so one level up is the repository.
    # Prefer the checkout it belongs to: that is the tree stage 9 copied to
    # /root/arch-auto-install, and it keeps the entry point and the modules in
    # step even when /var/lib/arch-auto-install holds an older snapshot.
    AIT_REPO_ROOT="$(cd -- "${_script_dir}/.." && pwd)"
    if [[ ! -d "${AIT_REPO_ROOT}/lib/chroot" ]]; then
        if [[ -d '/var/lib/arch-auto-install/lib/chroot' ]]; then
            AIT_REPO_ROOT='/var/lib/arch-auto-install'
        fi
    fi
fi
readonly AIT_REPO_ROOT
export AIT_REPO_ROOT

if [[ ! -r "${AIT_REPO_ROOT}/lib/common.sh" ]]; then
    printf '[ERROR] Cannot find %s/lib/common.sh.\n' "$AIT_REPO_ROOT" >&2
    exit 1
fi

# shellcheck disable=SC1091  # path is resolved at runtime from AIT_REPO_ROOT
source "${AIT_REPO_ROOT}/lib/common.sh"

# ---------------------------------------------------------------------------
# module loading
# ---------------------------------------------------------------------------
_ch9_source_module() {
    local file="$1"

    if [[ -r $file ]]; then
        # shellcheck disable=SC1090  # module paths are built at runtime
        source "$file"
        return 0
    fi
    log_warn "Stage 9 module not present yet: ${file}"
    return 0
}

_ch9_run_step() {
    local fn="$1"

    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn"
        return 0
    fi
    log_warn "Stage 9 function '${fn}' is not implemented yet; skipping it (TODO)."
    return 0
}

main_chroot() {
    log_info 'Stage 9: configuring the installed system from inside the chroot.'

    if [[ $EUID -ne 0 ]]; then
        die 'chroot-install.sh must run as root inside the chroot.'
    fi

    _ch9_source_module "${AIT_REPO_ROOT}/lib/chroot/chroot-09a-base.sh"
    _ch9_source_module "${AIT_REPO_ROOT}/lib/chroot/chroot-09b-boot.sh"
    _ch9_source_module "${AIT_REPO_ROOT}/lib/chroot/chroot-09c-users.sh"

    _ch9_run_step chroot_09a_base
    _ch9_run_step chroot_09b_boot
    _ch9_run_step chroot_09c_users

    log_ok 'Stage 9 finished.'
}

main_chroot "$@"
