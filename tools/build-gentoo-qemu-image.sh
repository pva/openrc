#!/usr/bin/env bash
#
# Build a Gentoo OpenRC qcow2 image from stage3.
# Usage: build-gentoo-qemu-image.sh [OUTDIR]
# Installs a kernel, GRUB, and qemu-guest-agent in the image.

set -euo pipefail

prog="${0##*/}"
outdir="${1:-qemu-tests}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/tools-helper.sh
. "${script_dir}/tools-helper.sh"

mirror="${GENTOO_MIRROR:-https://distfiles.gentoo.org}"
stage3_dir="releases/amd64/autobuilds/current-stage3-amd64-openrc"
image_size="${IMAGE_SIZE:-8G}"
image_disk="/dev/sda"
image_root="${image_disk}1"
root_label="openrc-root"
kernel_package="${KERNEL_PACKAGE:-sys-kernel/gentoo-kernel-bin}"
kernel_cmdline="${KERNEL_CMDLINE:-root=LABEL=${root_label} rw console=ttyS0,115200n8 cgroup_no_v1=all loglevel=7}"

need_cmd curl
need_cmd guestfish
need_cmd qemu-img
need_cmd tar
need_cmd virt-copy-out
need_cmd xz
need_cmd script
need_cmd virt-rescue

mkdir -p -- "${outdir}"
outdir="$(cd -- "${outdir}" && pwd)"
mkdir -p -- "${outdir}/shared-dir"

base_image="${outdir}/gentoo-base.qcow2"
test_image="${outdir}/gentoo-test.qcow2"
overlay="${outdir}/overlay"
overlay_tar="${outdir}/guest-overlay.tar"

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
log "partitioning and formatting ${image_root}"
log "extracting stage3 into ${base_image}"
guestfish --progress-bars --rw -a "${base_image}" <<-EOF
	run
	part-init ${image_disk} mbr
	part-add ${image_disk} p 2048 -2048
	part-set-bootable ${image_disk} 1 true
	mkfs ext4 ${image_root}
	set-label ${image_root} ${root_label}
	mount ${image_root} /
	tar-in ${stage3_tar} /
	umount-all
	EOF

rm -rf -- "${overlay}"
mkdir -p \
	"${overlay}/etc/conf.d" \
	"${overlay}/etc/default" \
	"${overlay}/etc/init.d" \
	"${overlay}/etc/local.d" \
	"${overlay}/mnt/host" \
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
cat >> "${overlay}/etc/rc.conf" <<-'EOF'

	rc_cgroup_mode="unified"
	rc_logger="YES"
	rc_verbose=yes
	EOF

tar_extract /etc/shadow "${overlay}/etc/shadow"
sed -i 's/^root:[^:]*:/root::/' "${overlay}/etc/shadow"
chmod 600 "${overlay}/etc/shadow"

tar_extract_optional /etc/securetty "${overlay}/etc/securetty"
printf '\nttyS0\n' >> "${overlay}/etc/securetty"

cat > "${overlay}/etc/fstab" <<-EOF
	LABEL=${root_label} / ext4 defaults 0 1
	hostshare /mnt/host 9p trans=virtio,version=9p2000.L,nofail 0 0
	EOF

printf '%s\n' "${kernel_cmdline}" > "${overlay}/etc/cmdline"

cat > "${overlay}/etc/default/grub" <<-EOF
	GRUB_TIMEOUT=1
	GRUB_CMDLINE_LINUX="${kernel_cmdline}"
	GRUB_TERMINAL="serial console"
	GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
	EOF

cat > "${overlay}/etc/hostname" <<-'EOF'
	openrc-qemu
	EOF

cat > "${overlay}/etc/conf.d/agetty.ttyS0" <<-'EOF'
	baud="115200"
	term_type="vt100"
	agetty_options="--autologin root --noclear"
	EOF

cat > "${overlay}/etc/conf.d/cgroups" <<-'EOF'
	rc_cgroup_mode="unified"
	EOF

cat > "${overlay}/etc/conf.d/qemu-guest-agent" <<-'EOF'
	GA_METHOD="virtio-serial"
	GA_PATH="/dev/virtio-ports/org.qemu.guest_agent.0"
	EOF

cat > "${overlay}/etc/local.d/cgroup-check.start" <<-'EOF'
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
guestfish --progress-bars --rw -a "${base_image}" <<-EOF
	run
	mount ${image_root} /
	tar-in ${overlay_tar} /
	umount-all
	EOF

log "installing ${kernel_package}, sys-boot/grub, and app-emulation/qemu-guest-agent"
boot_marker="openrc-qemu-boot-installed"
rescue_cmd="virt-rescue --rw --network -a \"\$BASE_IMAGE\" -m \"${image_root}:/\""
BASE_IMAGE="${base_image}" script -q -e -E never -c "${rescue_cmd}" /dev/null <<-EOF
	set -e
	mount -t proc proc /sysroot/proc
	mount --rbind /sys /sysroot/sys
	mount --rbind /dev /sysroot/dev
	cp /etc/resolv.conf /sysroot/etc/resolv.conf
	chroot /sysroot /bin/bash -lc '
	set -e
	mkdir -p /etc/portage
	printf "\nGRUB_PLATFORMS=\"pc\"\n" >> /etc/portage/make.conf
	getuto
	emerge-webrsync || emerge --sync
	emerge --oneshot --getbinpkg ${kernel_package} sys-boot/grub app-emulation/qemu-guest-agent
	rc-update add qemu-guest-agent default
	grub-install --target=i386-pc --recheck ${image_disk}
	grub-mkconfig -o /boot/grub/grub.cfg
	'
	touch /sysroot/var/tmp/${boot_marker}
	sync
	exit
	EOF
virt-copy-out -a "${base_image}" -m "${image_root}:/" "/var/tmp/${boot_marker}" "${outdir}" >/dev/null 2>&1 ||
	die "boot installation failed"
rm -f -- "${outdir}/${boot_marker}"

log "creating ${test_image}"
qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${test_image}"
rm -f -- "${stage3_tar}"

printf '%s\n' "${test_image}"
