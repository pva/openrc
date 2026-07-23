#!/usr/bin/env bash
# Build the reusable Gentoo base image and its SSH test keys.
# Usage: image-build.sh [QEMU_TEST_ROOT]

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=tools/qemu/lib/files.sh
. "${SCRIPT_DIR}/lib/files.sh"
# shellcheck source=tools/qemu/lib/qemu.sh
. "${SCRIPT_DIR}/lib/qemu.sh"

need_cmd awk
need_cmd curl
need_cmd guestfish
need_cmd qemu-img
need_cmd realpath
need_cmd script
need_cmd ssh-keygen
need_cmd tar
need_cmd virt-copy-out
need_cmd virt-rescue
need_cmd xz

qemu_root_init "${1:-qemu-tests}"

GENTOO_MIRROR="${GENTOO_MIRROR:-https://distfiles.gentoo.org}"
STAGE3_DIR="releases/amd64/autobuilds/current-stage3-amd64-openrc"
IMAGE_SIZE="${IMAGE_SIZE:-8G}"
IMAGE_DISK=/dev/sda
IMAGE_ROOT="${IMAGE_DISK}1"
ROOT_LABEL=openrc-root
KERNEL_PACKAGE="${KERNEL_PACKAGE:-sys-kernel/gentoo-kernel-bin}"
KERNEL_CMDLINE="${KERNEL_CMDLINE:-root=LABEL=${ROOT_LABEL} rw console=ttyS0,115200n8 net.ifnames=0 cgroup_no_v1=all quiet loglevel=3 udev.log_priority=3}"
CACHE_DIR="${G_QEMU_ROOT}/cache"
BUILD_DIR=

[ ! -e "${G_BASE_IMAGE}" ] || die "base image already exists: ${G_BASE_IMAGE}"
mkdir -p -- "${CACHE_DIR}" "${G_SSH_KEY_DIR}"
BUILD_DIR="$(mktemp -d "${G_QEMU_ROOT}/.image-build.XXXXXX")"

cleanup()
{
	case "${BUILD_DIR}" in
		"${G_QEMU_ROOT}/.image-build."*) rm -rf -- "${BUILD_DIR}" ;;
	esac
}
trap cleanup EXIT

ensure_ssh_key()
{
	local path="$1" description="$2"

	if [ -e "${path}" ]; then
		[ -r "${path}" ] || die "cannot read ${description} private key: ${path}"
		[ -r "${path}.pub" ] || die "missing ${description} public key: ${path}.pub"
		return 0
	fi
	[ ! -e "${path}.pub" ] || die "public key exists without its private key: ${path}.pub"
	log "generating ${description} key"
	ssh-keygen -q -t ed25519 -N '' -C openrc-qemu -f "${path}"
}

CLIENT_KEY="${G_SSH_KEY_DIR}/id_ed25519"
GUEST_HOST_KEY="${G_SSH_KEY_DIR}/ssh_host_ed25519_key"
ensure_ssh_key "${CLIENT_KEY}" "SSH client"
ensure_ssh_key "${GUEST_HOST_KEY}" "guest SSH host"
awk 'NF >= 2 { print "openrc-qemu " $1 " " $2; exit }' \
	"${GUEST_HOST_KEY}.pub" > "${G_SSH_KNOWN_HOSTS}"
chmod 600 "${CLIENT_KEY}" "${GUEST_HOST_KEY}" "${G_SSH_KNOWN_HOSTS}"

LATEST="${CACHE_DIR}/latest-stage3-amd64-openrc.txt"
log "downloading latest-stage3-amd64-openrc.txt metadata"
curl -fsSL "${GENTOO_MIRROR}/${STAGE3_DIR}/latest-stage3-amd64-openrc.txt" -o "${LATEST}"

STAGE3_REL="$(awk '$1 ~ /^stage3-.*\.tar\.xz$/ { print $1; exit }' "${LATEST}")"
[ -n "${STAGE3_REL}" ] || die "cannot find a stage3 tarball in ${LATEST}"
STAGE3_XZ="${CACHE_DIR}/$(basename -- "${STAGE3_REL}")"
STAGE3_TAR="${BUILD_DIR}/${STAGE3_XZ##*/}"
STAGE3_TAR="${STAGE3_TAR%.xz}"
case "${STAGE3_REL}" in
	*/*) STAGE3_URL="${GENTOO_MIRROR}/releases/amd64/autobuilds/${STAGE3_REL}" ;;
	*) STAGE3_URL="${GENTOO_MIRROR}/${STAGE3_DIR}/${STAGE3_REL}" ;;
esac

log "downloading ${STAGE3_REL} into ${CACHE_DIR}"
curl -fL -C - -o "${STAGE3_XZ}" "${STAGE3_URL}"
log "decompressing stage3"
xz -dc "${STAGE3_XZ}" > "${STAGE3_TAR}"

WORKING_IMAGE="${BUILD_DIR}/gentoo-base.qcow2"
log "creating ${WORKING_IMAGE}"
qemu-img create -f qcow2 "${WORKING_IMAGE}" "${IMAGE_SIZE}"
log "partitioning, formatting, and extracting stage3"
guestfish --progress-bars --rw -a "${WORKING_IMAGE}" <<-EOF
	run
	part-init ${IMAGE_DISK} mbr
	part-add ${IMAGE_DISK} p 2048 -2048
	part-set-bootable ${IMAGE_DISK} 1 true
	mkfs ext4 ${IMAGE_ROOT}
	set-label ${IMAGE_ROOT} ${ROOT_LABEL}
	mount ${IMAGE_ROOT} /
	tar-in ${STAGE3_TAR} /
	umount-all
	EOF

OVERLAY="${BUILD_DIR}/overlay"
OVERLAY_TAR="${BUILD_DIR}/overlay.tar"
mkdir -p \
	"${OVERLAY}/etc" \
	"${OVERLAY}/etc/init.d" \
	"${OVERLAY}/etc/runlevels/default" \
	"${OVERLAY}/etc/runlevels/sysinit" \
	"${OVERLAY}/mnt/host" \
	"${OVERLAY}/root/.ssh"

tar_extract require "${STAGE3_TAR}" /etc/rc.conf "${OVERLAY}/etc/rc.conf"
tar_extract require "${STAGE3_TAR}" /etc/shadow "${OVERLAY}/etc/shadow"
sed -i 's/^root:[^:]*:/root::/' "${OVERLAY}/etc/shadow"
chmod 600 "${OVERLAY}/etc/shadow"
tar_extract optional "${STAGE3_TAR}" /etc/securetty "${OVERLAY}/etc/securetty"

write_configs "${OVERLAY}" <<-EOF
	APPEND: etc/rc.conf

	rc_cgroup_mode="unified"
	rc_logger="YES"
	rc_verbose=yes

	APPEND: etc/securetty

	ttyS0

	FILE: etc/fstab
	LABEL=${ROOT_LABEL} / ext4 defaults 0 1
	hostshare /mnt/host 9p trans=virtio,version=9p2000.L,ro,nofail 0 0

	FILE: etc/cmdline
	${KERNEL_CMDLINE}

	FILE: etc/default/grub
	GRUB_TIMEOUT=0
	GRUB_TIMEOUT_STYLE=hidden
	GRUB_CMDLINE_LINUX="${KERNEL_CMDLINE}"
	GRUB_TERMINAL="serial console"
	GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

	FILE: etc/hostname
	openrc-qemu

	FILE: etc/conf.d/agetty.ttyS0
	baud="115200"
	term_type="vt100"
	agetty_options="--autologin root --noclear"

	FILE: etc/conf.d/cgroups
	rc_cgroup_mode="unified"

	FILE: etc/conf.d/net
	config_eth0="10.0.2.15/24"
	routes_eth0="default via 10.0.2.2"

	FILE: etc/ssh/sshd_config.d/99-openrc-qemu.conf
	PermitRootLogin prohibit-password
	PasswordAuthentication no
	KbdInteractiveAuthentication no
	PubkeyAuthentication yes
	UseDNS no
	AllowTcpForwarding no
	X11Forwarding no

	FILE: etc/ssh/sshd_config
	Include /etc/ssh/sshd_config.d/*.conf
	Subsystem sftp internal-sftp
	
	FILE: etc/portage/package.use/openrc-qemu
	sys-kernel/installkernel dracut
	dev-vcs/git -perl
	
	FILE: etc/local.d/cgroup-check.start
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

cp -- "${CLIENT_KEY}.pub" "${OVERLAY}/root/.ssh/authorized_keys"
cp -- "${GUEST_HOST_KEY}" "${OVERLAY}/etc/ssh/ssh_host_ed25519_key"
cp -- "${GUEST_HOST_KEY}.pub" "${OVERLAY}/etc/ssh/ssh_host_ed25519_key.pub"
chmod 700 "${OVERLAY}/root/.ssh"
chmod 600 "${OVERLAY}/root/.ssh/authorized_keys" \
	"${OVERLAY}/etc/ssh/ssh_host_ed25519_key"
chmod 644 "${OVERLAY}/etc/ssh/ssh_host_ed25519_key.pub"
chmod 755 "${OVERLAY}/etc/local.d/cgroup-check.start"

ln -s agetty "${OVERLAY}/etc/init.d/agetty.ttyS0"
ln -s net.lo "${OVERLAY}/etc/init.d/net.eth0"
ln -s /etc/init.d/agetty.ttyS0 "${OVERLAY}/etc/runlevels/default/agetty.ttyS0"
ln -s /etc/init.d/local "${OVERLAY}/etc/runlevels/default/local"
ln -s /etc/init.d/net.eth0 "${OVERLAY}/etc/runlevels/default/net.eth0"
ln -s /etc/init.d/cgroups "${OVERLAY}/etc/runlevels/sysinit/cgroups"

tar --numeric-owner --owner=0 --group=0 -C "${OVERLAY}" -cpf "${OVERLAY_TAR}" .
log "installing guest configuration"
guestfish --progress-bars --rw -a "${WORKING_IMAGE}" <<-EOF
	run
	mount ${IMAGE_ROOT} /
	tar-in ${OVERLAY_TAR} /
	umount-all
	EOF

log "installing kernel, bootloader, SSH, and OpenRC build dependencies"
BOOT_MARKER=openrc-qemu-boot-installed
RESCUE_CMD="virt-rescue --rw --network -a \"\$BASE_IMAGE\" -m \"${IMAGE_ROOT}:/\""
BASE_IMAGE="${WORKING_IMAGE}" script -q -e -E never -c "${RESCUE_CMD}" /dev/null <<-EOF
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
	emerge --oneshot --getbinpkg ${KERNEL_PACKAGE} sys-boot/grub net-misc/openssh dev-vcs/git
	ACCEPT_KEYWORDS="**" emerge --oneshot --onlydeps =sys-apps/openrc-9999
	eselect news read >/dev/null 2>&1 || true
	rc-update del dhcpcd default >/dev/null 2>&1 || true
	rc-update add sshd default
	rc-update add net.eth0 default
	grub-install --target=i386-pc --recheck ${IMAGE_DISK}
	grub-mkconfig -o /boot/grub/grub.cfg
	'
	touch /sysroot/var/tmp/${BOOT_MARKER}
	sync
	exit
	EOF

virt-copy-out -a "${WORKING_IMAGE}" -m "${IMAGE_ROOT}:/" \
	"/var/tmp/${BOOT_MARKER}" "${BUILD_DIR}" >/dev/null 2>&1 ||
	die "boot installation failed"
mv -- "${WORKING_IMAGE}" "${G_BASE_IMAGE}"
log "base image created: ${G_BASE_IMAGE}"
printf '%s\n' "${G_BASE_IMAGE}"
