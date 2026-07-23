#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/guest/tests/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

setup_openrc_path
rc-service cgroups status >/dev/null || fail "cgroups service is not started"
assert_init_layout "after boot"

# Starting the service again must preserve an already initialized hierarchy.
rc-service cgroups zap >/dev/null
rc-service cgroups start >/dev/null
assert_init_layout "after restarting cgroups"

echo "cgroup v2 boot layout test passed"
