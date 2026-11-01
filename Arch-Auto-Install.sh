#!/usr/bin/env bash
#
# Arch-Auto-Install - stage 1 entry point (runs inside the Arch Live ISO).
#
# All runtime messages MUST be pure ASCII: the installer runs on a TTY that
# has no CJK fonts.  See Config/Main/Plan-Main.md appendix C.
#
# Stage 1 responsibilities are described in Plan-Main.md stages 0-10.

set -o errexit
set -o nounset
set -o pipefail

AIT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly AIT_ROOT
AIT_LIB="${AIT_ROOT}/lib"
readonly AIT_LIB
AIT_NAME="Arch-Auto-Install"
readonly AIT_NAME
AIT_VERSION="beta v0.1"
readonly AIT_VERSION

export AIT_ROOT AIT_LIB AIT_NAME AIT_VERSION

# shellcheck source=lib/common.sh
source "${AIT_LIB}/common.sh"
# shellcheck source=lib/install/main.sh
source "${AIT_LIB}/install/main.sh"

main_install "$@"
