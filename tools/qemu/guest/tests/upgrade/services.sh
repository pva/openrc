#!/usr/bin/env bash
# Record and verify runlevel services across an OpenRC package upgrade.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/guest/tests/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

MODE="${1:?usage: services.sh record|check [phase]}"
PHASE="${2:-upgrade}"
STATE_DIR=/var/lib/openrc-qemu-tests
BEFORE_FILE="${STATE_DIR}/services-before-upgrade"

started_services()
{
	# --servicelist is limited to services assigned to runlevels, so manually
	# started one-off services do not make the post-reboot comparison unstable.
	rc-status --format ini --servicelist |
		sed -n 's/^[[:space:]]*\([^=][^=]*\)[[:space:]]*=[[:space:]]*started.*$/\1/p' |
		sed 's/[[:space:]]*$//' |
		sort -u
}

case "${MODE}" in
	record)
		mkdir -p -- "${STATE_DIR}"
		started_services > "${BEFORE_FILE}"
		[ -s "${BEFORE_FILE}" ] || fail "no started runlevel services were found"
		echo "recorded started services:"
		cat "${BEFORE_FILE}"
		;;
	check)
		[ -s "${BEFORE_FILE}" ] || fail "missing service snapshot: ${BEFORE_FILE}"
		CURRENT_FILE="$(mktemp)"
		MISSING_FILE="$(mktemp)"
		trap 'rm -f -- "${CURRENT_FILE}" "${MISSING_FILE}"' EXIT
		started_services > "${CURRENT_FILE}"
		comm -23 "${BEFORE_FILE}" "${CURRENT_FILE}" > "${MISSING_FILE}"
		if [ -s "${MISSING_FILE}" ]; then
			echo "services missing after ${PHASE}:" >&2
			cat "${MISSING_FILE}" >&2
			exit 1
		fi
		if CRASHED="$(rc-status --crashed)"; then
			[ -z "${CRASHED}" ] || fail "crashed services after ${PHASE}: ${CRASHED}"
		fi
		echo "all recorded services remain started after ${PHASE}"
		;;
	*) fail "unknown mode: ${MODE}" ;;
esac
