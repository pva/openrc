#!/usr/bin/env bash
#
# Run an OpenRC cgroup v2 service test in a running QEMU guest.
# Usage: test-qemu-cgroup2-service.sh [OUTDIR]
# Set IMAGE to use the QGA socket and shared-dir next to a custom running image.

set -euo pipefail

prog="${0##*/}"
outdir="${1:-qemu-tests}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu-helpers.sh
. "${script_dir}/qemu-helpers.sh"

guest_script_name="guest-test-qemu-cgroup2-service.sh"
guest_script_src="${script_dir}/${guest_script_name}"
guest_script="${host_share}/${guest_script_name}"

need_cmd base64
need_cmd jq
need_cmd socat

mkdir -p -- "${host_share}"
[ -f "${guest_script_src}" ] || die "missing guest script: ${guest_script_src}"
cp -- "${guest_script_src}" "${guest_script}"

qga_wait_ready
log "running guest cgroup v2 service test"
qga_exec "bash '${guest_share}/${guest_script_name}'"
