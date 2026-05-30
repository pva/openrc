#!/usr/bin/env bash
#
# Build a Gentoo OpenRC qcow2 image from stage3 and generate a QEMU runner.
# Usage: build-gentoo-qemu-image.sh [OUTDIR]
# Set INSTALL_KERNEL=1 to install sys-kernel/gentoo-kernel-bin in the image.
# GUEST_ROOT is the guest root filesystem device created in the image; the
# default is /dev/sda1.

set -euo pipefail

prog="${0##*/}"
outdir="${1:-gentoo-qemu}"
mirror="${GENTOO_MIRROR:-https://distfiles.gentoo.org}"
stage3_dir="releases/amd64/autobuilds/current-stage3-amd64-openrc"
image_size="${IMAGE_SIZE:-8G}"
guest_root="${GUEST_ROOT:-/dev/sda1}"
install_kernel="${INSTALL_KERNEL:-1}"
kernel_package="${KERNEL_PACKAGE:-sys-kernel/gentoo-kernel-bin}"
kernel_cmdline="${KERNEL_CMDLINE:-root=/dev/vda1 rw console=ttyS0,115200n8 cgroup_no_v1=all loglevel=7}"

die()
{
	echo "${prog}: $*" >&2
	exit 1
}

log()
{
	printf '%s: %s\n' "${prog}" "$*" >&2
}

need_cmd()
{
	command -v "$1" >/dev/null || die "missing command: $1"
}

need_cmd curl
need_cmd guestfish
need_cmd qemu-img
need_cmd tar
need_cmd virt-copy-out
need_cmd xz

if [ "${install_kernel}" = 1 ]; then
	need_cmd script
	need_cmd virt-rescue
fi

mkdir -p -- "${outdir}"
outdir="$(cd -- "${outdir}" && pwd)"

base_image="${outdir}/gentoo-base.qcow2"
test_image="${outdir}/gentoo-test.qcow2"
overlay="${outdir}/overlay"
overlay_tar="${outdir}/guest-overlay.tar"
run_qemu="${outdir}/run-qemu.sh"

[ ! -e "${base_image}" ] || die "base image already exists: ${base_image}"
[ ! -e "${test_image}" ] || die "test image already exists: ${test_image}"

latest="${outdir}/latest-stage3-amd64-openrc.txt"
log "downloading stage3 metadata"
curl -fsSL "${mirror}/${stage3_dir}/latest-stage3-amd64-openrc.txt" -o "${latest}"

stage3_rel="$(awk '$1 ~ /^stage3-.*\.tar\.xz$/ { print $1; exit }' "${latest}")"
[ -n "${stage3_rel}" ] || die "cannot find stage3 tarball name in ${latest}"
stage3_xz="${outdir}/$(basename -- "${stage3_rel}")"
stage3_tar="${stage3_xz%.xz}"

case "${stage3_rel}" in
	*/*) stage3_url="${mirror}/releases/amd64/autobuilds/${stage3_rel}" ;;
	*) stage3_url="${mirror}/${stage3_dir}/${stage3_rel}" ;;
esac
log "downloading ${stage3_rel}"
curl -fL -C - -o "${stage3_xz}" "${stage3_url}"
log "decompressing stage3"
xz -dc "${stage3_xz}" > "${stage3_tar}"

log "creating ${base_image}"
qemu-img create -f qcow2 "${base_image}" "${image_size}"
log "partitioning and formatting ${guest_root}"
log "extracting stage3 into ${base_image}"
guestfish --progress-bars --rw -a "${base_image}" <<EOF
run
part-disk /dev/sda mbr
mkfs ext4 ${guest_root}
mount ${guest_root} /
tar-in ${stage3_tar} /
umount-all
EOF

rm -rf -- "${overlay}"
mkdir -p \
	"${overlay}/etc/conf.d" \
	"${overlay}/etc/init.d" \
	"${overlay}/etc/local.d" \
	"${overlay}/etc/runlevels/default" \
	"${overlay}/etc/runlevels/sysinit"

tar_extract()
{
	local path="$1" dest="$2"

	if tar -xOf "${stage3_tar}" ".${path}" > "${dest}" 2>/dev/null; then
		return 0
	fi
	tar -xOf "${stage3_tar}" "${path#/}" > "${dest}"
}

tar_extract_optional()
{
	local path="$1" dest="$2"

	if ! tar_extract "${path}" "${dest}" 2>/dev/null; then
		: > "${dest}"
	fi
}

tar_extract /etc/rc.conf "${overlay}/etc/rc.conf"
cat >> "${overlay}/etc/rc.conf" <<'EOF'

rc_cgroup_mode="unified"
rc_logger="YES"
rc_verbose=yes
EOF

tar_extract /etc/shadow "${overlay}/etc/shadow"
sed -i 's/^root:[^:]*:/root::/' "${overlay}/etc/shadow"
chmod 600 "${overlay}/etc/shadow"

tar_extract_optional /etc/securetty "${overlay}/etc/securetty"
printf '\nttyS0\n' >> "${overlay}/etc/securetty"

cat > "${overlay}/etc/fstab" <<'EOF'
/dev/vda1 / ext4 defaults 0 1
EOF

printf '%s\n' "${kernel_cmdline}" > "${overlay}/etc/cmdline"

cat > "${overlay}/etc/hostname" <<'EOF'
openrc-qemu
EOF

cat > "${overlay}/etc/conf.d/agetty.ttyS0" <<'EOF'
baud="115200"
term_type="vt100"
agetty_options="--autologin root --noclear"
EOF

cat > "${overlay}/etc/conf.d/cgroups" <<'EOF'
rc_cgroup_mode="unified"
EOF

cat > "${overlay}/etc/local.d/cgroup-check.start" <<'EOF'
#!/bin/sh

{
	echo "=== cgroup check ==="
	echo "root cgroup.procs:"
	cat /sys/fs/cgroup/cgroup.procs 2>/dev/null
	echo "root cgroup.subtree_control:"
	cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
	echo "rc.init cgroup.procs:"
	cat /sys/fs/cgroup/rc.init/cgroup.procs 2>/dev/null
	echo "cgroup tree:"
	find /sys/fs/cgroup -maxdepth 2 -type d | sort
	echo "=== end cgroup check ==="
} >/dev/console 2>&1
EOF
chmod 755 "${overlay}/etc/local.d/cgroup-check.start"

ln -s agetty "${overlay}/etc/init.d/agetty.ttyS0"
ln -s /etc/init.d/agetty.ttyS0 "${overlay}/etc/runlevels/default/agetty.ttyS0"
ln -s /etc/init.d/local "${overlay}/etc/runlevels/default/local"
ln -s /etc/init.d/cgroups "${overlay}/etc/runlevels/sysinit/cgroups"

tar --numeric-owner --owner=0 --group=0 -C "${overlay}" -cpf "${overlay_tar}" .

log "installing guest overlay"
guestfish --progress-bars --rw -a "${base_image}" <<EOF
run
mount ${guest_root} /
tar-in ${overlay_tar} /
umount-all
EOF

if [ "${install_kernel}" = 1 ]; then
	log "installing ${kernel_package}"
	kernel_marker="openrc-qemu-kernel-installed"
	rescue_cmd="virt-rescue --rw --network -a \"\$BASE_IMAGE\" -m \"\$GUEST_ROOT:/\""
	BASE_IMAGE="${base_image}" GUEST_ROOT="${guest_root}" script -q -e -E never -c "${rescue_cmd}" /dev/null <<EOF
set -e
mount -t proc proc /sysroot/proc
mount --rbind /sys /sysroot/sys
mount --rbind /dev /sysroot/dev
cp /etc/resolv.conf /sysroot/etc/resolv.conf
chroot /sysroot /bin/bash -lc 'set -e; getuto; emerge-webrsync || emerge --sync; emerge --oneshot --getbinpkg ${kernel_package}'
touch /sysroot/var/tmp/${kernel_marker}
sync
exit
EOF
	virt-copy-out -a "${base_image}" -m "${guest_root}:/" "/var/tmp/${kernel_marker}" "${outdir}" >/dev/null 2>&1 ||
		die "kernel installation failed"
	rm -f -- "${outdir}/${kernel_marker}"
fi

mkdir -p "${outdir}/boot"
log "copying /boot out of image"
virt-copy-out -a "${base_image}" -m "${guest_root}:/" /boot "${outdir}"

log "creating ${test_image}"
qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${test_image}"

kernel=""
initrd=""
if [ -d "${outdir}/boot" ]; then
	kernel="$(find "${outdir}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -n 1)"
	initrd="$(find "${outdir}/boot" -maxdepth 1 -type f \( -name 'initramfs-*' -o -name 'initrd-*' \) | sort -V | tail -n 1)"
fi

cat > "${run_qemu}" <<EOF
#!/usr/bin/env bash

set -euo pipefail

image="\${IMAGE:-${test_image}}"
kernel="\${KERNEL:-${kernel}}"
initrd="\${INITRD:-${initrd}}"

[ -n "\${kernel}" ]
[ -e "\${kernel}" ]

qemu-system-x86_64 \\
	-enable-kvm \\
	-m "\${MEM:-1024}" \\
	-smp "\${SMP:-2}" \\
	-nographic \\
	-drive "file=\${image},if=virtio,format=qcow2" \\
	-kernel "\${kernel}" \\
	\${initrd:+-initrd "\${initrd}"} \\
	-append "\${APPEND:-${kernel_cmdline}}"
EOF
chmod 755 "${run_qemu}"

log "wrote ${run_qemu}"
printf '%s\n' "${test_image}"
