#!/usr/bin/env bash
#
# Install the current OpenRC build into a running QEMU guest.
# Usage: install-openrc-to-running-qemu.sh [OUTDIR] [BUILD_DIR]
# Set IMAGE to use the QGA socket and shared-dir next to a custom running image.

set -euo pipefail

prog="${0##*/}"
outdir="${1:-qemu-tests}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu-helpers.sh
. "${script_dir}/qemu-helpers.sh"

repo_root="$(cd -- "${script_dir}/.." && pwd)"
build_dir="${2:-${repo_root}/build}"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openrc-qemu-install.XXXXXXXXXX")"
staging="${tmpdir}/staging"
commit="$(git -C "${repo_root}" rev-parse --short HEAD)"
tar_name="openrc-${commit}-install.tar"
tarball="${host_share}/${tar_name}"

cleanup()
{
	rm -rf -- "${tmpdir}"
	if [ "${KEEP_TAR:-0}" != 1 ]; then
		rm -f -- "${tarball}"
	fi
}
trap cleanup EXIT

need_cmd base64
need_cmd git
need_cmd jq
need_cmd meson
need_cmd socat
need_cmd tar

guest_is_merged_usr()
{
	qga_exec "[ \"\$(readlink /bin)\" = usr/bin ] && [ \"\$(readlink /sbin)\" = usr/sbin ]" >/dev/null 2>&1
}

[ -d "${build_dir}" ] || die "build directory does not exist: ${build_dir}"
mkdir -p -- "${host_share}" "${staging}"

qga_wait_ready

if guest_is_merged_usr; then
	configure_merged_usr_build "${build_dir}"
else
	configure_split_usr_build "${build_dir}"
fi

log "building OpenRC in ${build_dir}"
meson compile -C "${build_dir}"
log "staging OpenRC install"
meson install -C "${build_dir}" --destdir "${staging}"

tar --numeric-owner --owner=0 --group=0 -C "${staging}" -cpf "${tarball}" .

log "installing ${tar_name} inside guest"
qga_exec "tar -C / -xpf '${guest_share}/${tar_name}' && sync && openrc --version"
