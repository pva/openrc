#!/usr/bin/env bash
# Start a base image through a new or existing per-run overlay.
# Usage: image-run.sh [QEMU_TEST_ROOT]

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=tools/qemu/lib/qemu.sh
. "${SCRIPT_DIR}/lib/qemu.sh"

usage()
{
	cat <<-EOF
		Usage: ${PROG} [QEMU_TEST_ROOT]

		Start a new or existing persistent run. QEMU_TEST_ROOT defaults to qemu-tests.

		Environment:
		  RUN_ID          run to create or resume (default: generated timestamp and PID)
		  IMAGE           base qcow2 path (default: ROOT/images/gentoo-base.qcow2)
		  NET             ISOLATED (default) or NAT
		  SERIAL_MODE     stdio (default) or file
		  QEMU_ACCEL      kvm (default) or tcg
		  MEM             guest memory passed to QEMU (default: 1024)
		  SMP             guest CPU count passed to QEMU (default: 2)
	EOF
}

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

need_cmd qemu-img
need_cmd qemu-system-x86_64
need_cmd realpath
need_cmd sha256sum

qemu_root_init "${1:-qemu-tests}"
RUN_ID="${RUN_ID:-$(run_id_default)}"
validate_name run-id "${RUN_ID}"
if [ -d "${G_RUNS_DIR}/${RUN_ID}" ]; then
	qemu_run_load "${G_RUNS_DIR}/${RUN_ID}"
	[ -f "${G_OVERLAY_IMAGE}" ] ||
		die "run overlay does not exist: ${G_OVERLAY_IMAGE}"
	log "resuming run: ${RUN_ID}"
else
	qemu_run_create "${RUN_ID}"
	qemu_overlay_create
	log "created run: ${RUN_ID}"
fi

cleanup()
{
	local status=$?

	trap - EXIT
	if qemu_is_started; then
		qemu_runtime_cleanup
	fi
	log "RUN_ID=${RUN_ID}"
	printf '%s: resume command: RUN_ID=%q %q %q\n' \
		"${PROG}" "${RUN_ID}" "${SCRIPT_DIR}/image-run.sh" "${G_QEMU_ROOT}" >&2
	exit "${status}"
}
trap cleanup EXIT

log "run directory: ${G_RUN_DIR}"
log "SSH socket: ${G_SSH_SOCKET}"
log "SSH example: ssh -o 'ProxyCommand=socat - UNIX-CONNECT:${G_SSH_SOCKET}' -o HostKeyAlias=openrc-qemu -o UserKnownHostsFile=${G_SSH_KNOWN_HOSTS} -i ${G_SSH_PRIVATE_KEY} root@openrc-qemu"
qemu_run_foreground
