#!/usr/bin/env bash
# Builds the SimpleTreeSitter daemon and installs it into lib/.
#
# The work is shared with the rest of the simple* suite; see install-common.sh,
# which is vendored from .simplecore and must not be edited in place.
set -euo pipefail

SIMPLECORE_BINARY="ts-hl-daemon"
SIMPLECORE_DISPLAY="SimpleTreeSitter"
SIMPLECORE_MIN_RUST_MINOR=88
SIMPLECORE_VERIFY="self-test"

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install-common.sh"
