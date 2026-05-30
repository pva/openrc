#!/usr/bin/env bash
#
# Run the Gentoo OpenRC qcow2 image built by build-gentoo-qemu-image.sh.
# Usage: run-gentoo-qemu-image.sh [OUTDIR]

set -euo pipefail

prog="${0##*/}"
outdir="${1:-gentoo-qemu}"
image="${IMAGE:-${outdir}/gentoo-test.qcow2}"
boot="${BOOT:-${outdir}/boot}"
append="${APPEND:-root=/dev/vda1 rw console=ttyS0,115200n8 cgroup_no_v1=all loglevel=7}"

die()
{
	echo "${prog}: $*" >&2
	exit 1
}

[ -e "${image}" ] || die "image not found: ${image}"
[ -d "${boot}" ] || die "boot directory not found: ${boot}"

kernel="${KERNEL:-}"
initrd="${INITRD:-}"

if [ -z "${kernel}" ]; then
	kernel="$(find "${boot}" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -n 1)"
fi

if [ -z "${initrd}" ]; then
	initrd="$(find "${boot}" -maxdepth 1 -type f \( -name 'initramfs-*' -o -name 'initrd-*' \) | sort -V | tail -n 1)"
fi

[ -n "${kernel}" ] || die "kernel not found in ${boot}"
[ -e "${kernel}" ] || die "kernel not found: ${kernel}"

qemu_args=(
	-enable-kvm
	-m "${MEM:-1024}"
	-smp "${SMP:-2}"
	-nographic
	-drive "file=${image},if=virtio,format=qcow2"
	-kernel "${kernel}"
)

if [ -n "${initrd}" ]; then
	qemu_args+=( -initrd "${initrd}" )
fi

qemu_args+=( -append "${append}" )

exec qemu-system-x86_64 "${qemu_args[@]}"
