#!/usr/bin/env bash
#
# Install the current OpenRC build into a libguestfs-supported disk image.
# Usage: install-openrc-to-image.sh IMAGE [BUILD_DIR]
# GUEST_MOUNT may be set to the guest root filesystem device, for example
# /dev/sda1, when libguestfs inspection cannot find the root filesystem.
# Set MERGED_USR=0 for split-usr images.

set -euo pipefail

prog="${0##*/}"

die()
{
	echo "${prog}: $*" >&2
	exit 1
}

need_cmd()
{
	command -v "$1" >/dev/null || die "missing command: $1"
}

guest_readlink()
{
	local path="$1"

	if [ -n "${GUEST_MOUNT:-}" ]; then
		guestfish --ro -a "${image}" <<EOF
run
mount ${GUEST_MOUNT} /
readlink ${path}
umount-all
EOF
	else
		guestfish --ro -a "${image}" -i <<EOF
readlink ${path}
EOF
	fi
}

merged_usr_image()
{
	case "${MERGED_USR:-auto}" in
		0|false|no) return 1 ;;
		1|true|yes) return 0 ;;
		auto) ;;
		*) die "invalid MERGED_USR value: ${MERGED_USR}" ;;
	esac

	[ "$(guest_readlink /bin)" = "usr/bin" ] || return 1
	[ "$(guest_readlink /sbin)" = "usr/bin" ] || return 1
}

move_dir_contents()
{
	local from="$1" to="$2" entry

	[ -d "${from}" ] || return 0
	[ ! -L "${from}" ] || return 0

	mkdir -p -- "${to}"
	for entry in "${from}"/* "${from}"/.[!.]* "${from}"/..?*; do
		[ -e "${entry}" ] || [ -L "${entry}" ] || continue
		mv -f -- "${entry}" "${to}/"
	done
	rmdir -- "${from}"
}

prepare_merged_usr_staging()
{
	move_dir_contents "${staging}/bin" "${staging}/usr/bin"
	move_dir_contents "${staging}/sbin" "${staging}/usr/bin"
	move_dir_contents "${staging}/usr/sbin" "${staging}/usr/bin"
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "usage: $0 IMAGE [BUILD_DIR]" >&2
	exit 2
fi

image="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
build_dir="${2:-${repo_root}/build}"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openrc-image-install.XXXXXXXXXX")"
staging="${tmpdir}/staging"
tarball="${tmpdir}/openrc-install.tar"

cleanup()
{
	rm -rf -- "${tmpdir}"
}
trap cleanup EXIT

need_cmd meson
need_cmd tar
need_cmd guestfish

[ -e "${image}" ] || die "image does not exist: ${image}"
[ -d "${build_dir}" ] || die "build directory does not exist: ${build_dir}"

mkdir -p -- "${staging}"
meson install -C "${build_dir}" --destdir "${staging}"

if merged_usr_image; then
	prepare_merged_usr_staging
fi

tar --numeric-owner --owner=0 --group=0 -C "${staging}" -cpf "${tarball}" .

if [ -n "${GUEST_MOUNT:-}" ]; then
	guestfish --rw -a "${image}" <<EOF
run
mount ${GUEST_MOUNT} /
tar-in ${tarball} /
umount-all
EOF
else
	guestfish --rw -a "${image}" -i <<EOF
tar-in ${tarball} /
EOF
fi
