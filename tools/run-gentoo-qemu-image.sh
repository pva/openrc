#!/usr/bin/env bash
#
# Run the Gentoo OpenRC qcow2 image built by build-gentoo-qemu-image.sh.
# Usage: run-gentoo-qemu-image.sh [OUTDIR]
# IMAGE may point at a custom qcow2 image. The image directory is used for QGA
# socket and shared-dir placement.
# QEMU runs with -snapshot by default; set SNAPSHOT=0 to persist guest writes.

set -euo pipefail

prog="${0##*/}"
outdir="${1:-qemu-tests}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu-helpers.sh
. "${script_dir}/qemu-helpers.sh"

host_share_readonly="${HOST_SHARE_READONLY:-1}"
qemu_snapshot="${SNAPSHOT:-1}"
qemu_memory="${MEM:-1024}"
qemu_smp="${SMP:-2}"

cleanup()
{
	rm -f -- "${qga_socket}"
}
trap cleanup EXIT

[ -e "${image}" ] || die "image not found: ${image}"

mkdir -p -- "${host_share}"
host_share_opts="local,path=${host_share},mount_tag=hostshare,security_model=none"
if [ "${host_share_readonly}" = 1 ]; then
	host_share_opts="${host_share_opts},readonly=on"
fi

rm -f -- "${qga_socket}"
qemu_args=(
	-enable-kvm
)
if [ "${qemu_snapshot}" = 1 ]; then
	qemu_args+=( -snapshot )
fi
qemu_args+=(
	-m "${qemu_memory}"
	-smp "${qemu_smp}"
	-nographic
	-drive "file=${image},if=virtio,format=qcow2"
	-device virtio-serial-pci
	-chardev "socket,path=${qga_socket},server=on,wait=off,id=qga0"
	-device "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"
	-virtfs "${host_share_opts}"
)

qemu-system-x86_64 "${qemu_args[@]}"
