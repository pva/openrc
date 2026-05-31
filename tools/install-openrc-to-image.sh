#!/usr/bin/env bash
#
# Install the current OpenRC build into a libguestfs-supported disk image.
# Usage: install-openrc-to-image.sh IMAGE [BUILD_DIR]

set -euo pipefail

prog="${0##*/}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/tools-helper.sh
. "${script_dir}/tools-helper.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "usage: $0 IMAGE [BUILD_DIR]" >&2
	exit 2
fi

image="$1"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
build_dir="${2:-${repo_root}/build}"
image_root="/dev/sda1"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openrc-image-install.XXXXXXXXXX")"
staging="${tmpdir}/staging"
tarball="${tmpdir}/openrc-install.tar"

cleanup()
{
	rm -rf -- "${tmpdir}"
}
trap cleanup EXIT

guest_readlink()
{
	local path="$1"

	guestfish --ro -a "${image}" <<-EOF
	run
	mount ${image_root} /
	readlink ${path}
	umount-all
	EOF
}

merged_usr_image()
{
	[ "$(guest_readlink /bin)" = "usr/bin" ] || return 1
	[ "$(guest_readlink /sbin)" = "usr/sbin" ] || return 1
}

need_cmd guestfish
need_cmd meson
need_cmd tar

[ -e "${image}" ] || die "image does not exist: ${image}"
[ -d "${build_dir}" ] || die "build directory does not exist: ${build_dir}"

mkdir -p -- "${staging}"
if merged_usr_image; then
	configure_merged_usr_build "${build_dir}"
else
	configure_split_usr_build "${build_dir}"
fi

log "staging OpenRC install"
meson install -C "${build_dir}" --destdir "${staging}"

tar --numeric-owner --owner=0 --group=0 -C "${staging}" -cpf "${tarball}" .

log "installing OpenRC into ${image}"
guestfish --rw -a "${image}" <<-EOF
	run
	mount ${image_root} /
	tar-in ${tarball} /
	umount-all
	EOF
