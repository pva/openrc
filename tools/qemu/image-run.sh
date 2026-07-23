#!/usr/bin/env bash
# Start a base image through a new disposable per-run overlay.
# Usage: image-run.sh [QEMU_TEST_ROOT]

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=tools/qemu/lib/qemu.sh
. "${SCRIPT_DIR}/lib/qemu.sh"

need_cmd qemu-img
need_cmd qemu-system-x86_64
need_cmd realpath
need_cmd sha256sum

qemu_root_init "${1:-qemu-tests}"
RUN_ID="${RUN_ID:-$(run_id_default)}"
qemu_run_create "${RUN_ID}"
qemu_overlay_create

cleanup()
{
	qemu_runtime_cleanup
}
trap cleanup EXIT

log "run directory: ${G_RUN_DIR}"
log "SSH socket: ${G_SSH_SOCKET}"
log "SSH example: ssh -o 'ProxyCommand=socat - UNIX-CONNECT:${G_SSH_SOCKET}' -o HostKeyAlias=openrc-qemu -o UserKnownHostsFile=${G_SSH_KNOWN_HOSTS} -i ${G_SSH_PRIVATE_KEY} root@openrc-qemu"
qemu_run_foreground
