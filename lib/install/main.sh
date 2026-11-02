#!/usr/bin/env bash
#
# lib/install/main.sh - stage 1 dispatcher (runs inside the Arch Live ISO).
#
# Every stage lives in its own module lib/install/stage-NN-*.sh and defines
# exactly one function named after it (no arguments).  Adding a module needs
# no edit here: all stage-NN-*.sh files are sourced automatically.
#
# See Config/Main/Plan-Main.md stages 0-16 for the behaviour of each step.

AIT_STAGE_FUNCS=(
    stage_00_welcome
    stage_01_detect_os
    stage_02_network
    stage_03_mirror
    stage_04_disk
    stage_05_format
)

_ait_source_stage_modules() {
    local f
    for f in "${AIT_LIB}"/install/stage-*.sh; do
        [[ -r $f ]] || continue
        # shellcheck disable=SC1090
        source "$f"
    done
}

main_install() {
    _ait_source_stage_modules

    local fn
    for fn in "${AIT_STAGE_FUNCS[@]}"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            die "Stage function '${fn}' is not implemented yet."
        fi
        "$fn"
    done

    # Stages 06-16 are not written yet (Plan-Main.md stages 6-10 and the
    # chroot half 11-16).  Stop loudly instead of pretending to succeed.
    die "Stages 06-16 are not implemented yet. Aborting after stage 05."
}
