#!/usr/bin/env bash
#
# Shared helpers for host-side build/install scripts.

# shellcheck disable=SC2154

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

configure_openrc_build_dirs()
{
	local build_dir="$1" bindir="$2" sbindir="$3"

	log "configuring ${build_dir} install directories"
	meson setup --reconfigure "${build_dir}" "-Dbindir=${bindir}" "-Dsbindir=${sbindir}"
}

configure_merged_usr_build()
{
	local build_dir="$1"

	configure_openrc_build_dirs "${build_dir}" bin sbin
}

configure_split_usr_build()
{
	local build_dir="$1"

	configure_openrc_build_dirs "${build_dir}" /bin /sbin
}
