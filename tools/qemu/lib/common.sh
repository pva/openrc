#!/usr/bin/env bash

# Common host-side helpers for the QEMU test tools.

die()
{
	printf '%s: %s\n' "${PROG:-openrc-qemu}" "$*" >&2
	exit 1
}

log()
{
	printf '%s: %s\n' "${PROG:-openrc-qemu}" "$*" >&2
}

need_cmd()
{
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# Return a normalized absolute path even if some components do not exist.
realpath_m()
{
	realpath -m -- "$1"
}

validate_name()
{
	local kind="$1" value="$2"

	[ -n "${value}" ] || die "empty ${kind}"
	case "${value}" in
		*[!A-Za-z0-9._-]*) die "invalid ${kind}: ${value}" ;;
	esac
}

validate_boolean()
{
	local name="$1" value="$2"

	case "${value}" in
		0|1) ;;
		*) die "${name} must be 0 or 1, got: ${value}" ;;
	esac
}

shell_join()
{
	local arg joined=

	for arg in "$@"; do
		printf -v arg '%q' "${arg}"
		joined="${joined}${joined:+ }${arg}"
	done
	printf '%s\n' "${joined}"
}

run_id_default()
{
	printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}
