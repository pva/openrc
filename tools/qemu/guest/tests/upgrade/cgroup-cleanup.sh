#!/usr/bin/env bash
# Verify per-service cgroup cleanup across a live upgrade from pre-rc.init OpenRC.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/guest/tests/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

MODE="${1:?usage: cgroup-cleanup.sh prepare|check}"
SVC="openrc-qemu-upgrade-cgroup"
INITD="/etc/init.d/${SVC}"
PIDFILE="/run/${SVC}.pid"
CGROUP_ROOT="/sys/fs/cgroup"
CGROUP_PATH="${CGROUP_ROOT}/openrc.${SVC}"
STATE_DIR="/var/lib/openrc-qemu-tests"
ACTIVE_FILE="${STATE_DIR}/upgrade-cgroup-cleanup-active"
SKIP_FILE="${STATE_DIR}/upgrade-cgroup-cleanup-skip"

wait_for_service_cgroup()
{
	local daemon_pid="" i=0

	while [ "${i}" -lt 50 ]; do
		if [ -s "${PIDFILE}" ] &&
			read -r daemon_pid < "${PIDFILE}" &&
			[ -n "${daemon_pid}" ] &&
			grep -qx "${daemon_pid}" "${CGROUP_PATH}/cgroup.procs" 2>/dev/null; then
			printf '%s' "${daemon_pid}"
			return 0
		fi
		i=$((i + 1))
		sleep 0.1
	done
	return 1
}

case "${MODE}" in
	prepare)
		setup_openrc_path
		mkdir -p -- "${STATE_DIR}"
		rm -f -- "${ACTIVE_FILE}" "${SKIP_FILE}"

		if [ -e "${CGROUP_ROOT}/rc.init/cgroup.procs" ]; then
			: > "${SKIP_FILE}"
			echo "upgrade source already has rc.init; legacy cleanup test skipped"
			exit 0
		fi

		cat > "${INITD}" <<-EOF_INIT
			#!/sbin/openrc-run

			description="OpenRC live-upgrade cgroup cleanup test service"
			command="/bin/sleep"
			command_args="600"
			command_background=true
			pidfile="${PIDFILE}"
			EOF_INIT
		chmod 755 "${INITD}"

		rc-service "${SVC}" start
		daemon_pid="$(wait_for_service_cgroup)" ||
			fail "service did not enter ${CGROUP_PATH}"
		: > "${ACTIVE_FILE}"
		echo "old OpenRC started service pid ${daemon_pid} in ${CGROUP_PATH}"
		;;
	check)
		setup_openrc_path
		if [ -e "${SKIP_FILE}" ]; then
			echo "upgrade source already had rc.init; legacy cleanup test skipped"
			exit 0
		fi
		[ -e "${ACTIVE_FILE}" ] || fail "legacy cleanup test was not prepared"
		[ ! -e "${CGROUP_ROOT}/rc.init/cgroup.procs" ] ||
			fail "live package upgrade unexpectedly created rc.init"
		[ -d "${CGROUP_PATH}" ] || fail "missing service cgroup ${CGROUP_PATH}"
		[ -s "${PIDFILE}" ] || fail "missing service pidfile ${PIDFILE}"
		read -r daemon_pid < "${PIDFILE}"
		case "${daemon_pid}" in
			''|*[!0-9]*) fail "invalid service pidfile ${PIDFILE}: ${daemon_pid}" ;;
		esac

		rc-service "${SVC}" stop

		i=0
		while [ "${i}" -lt 50 ]; do
			[ ! -e "${CGROUP_PATH}" ] && [ ! -d "/proc/${daemon_pid}" ] && break
			i=$((i + 1))
			sleep 0.1
		done
		[ ! -e "${CGROUP_ROOT}/rc.init/cgroup.procs" ] ||
			fail "service stop created rc.init instead of using the legacy root fallback"
		if [ -e "${CGROUP_PATH}" ]; then
			echo "remaining cgroup events:" >&2
			cat "${CGROUP_PATH}/cgroup.events" >&2 || true
			echo "remaining cgroup processes:" >&2
			cat "${CGROUP_PATH}/cgroup.procs" >&2 || true
			fail "${CGROUP_PATH} was not removed after stop"
		fi
		[ ! -d "/proc/${daemon_pid}" ] ||
			fail "service pid ${daemon_pid} is still running after stop"

		rm -f -- "${INITD}" "${PIDFILE}" "${ACTIVE_FILE}"
		echo "live-upgrade service cgroup removed without creating rc.init"
		;;
	*) fail "unknown mode: ${MODE}" ;;
esac
