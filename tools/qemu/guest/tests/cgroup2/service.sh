#!/usr/bin/env bash
#
# Exercise per-service cgroup v2 settings inside the QEMU guest.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/guest/tests/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

SVC="cgtest"
INITD="/etc/init.d/${SVC}"
CONFD="/etc/conf.d/${SVC}"
SETTINGS_FILE="/run/${SVC}.cgroup-settings"
EXPECTED_FILE="/run/${SVC}.cgroup-expected"
ACTUAL_FILE="/run/${SVC}.cgroup-actual"
PIDFILE="/run/${SVC}.pid"
CGROUP_PATH="/sys/fs/cgroup/openrc.${SVC}"
SWAP_FILE="/swap-openrc-cgroup-test"
SWAP_ENABLED=0

cleanup()
{
	rc-service "${SVC}" stop >/dev/null 2>&1 || true
	if [ "${SWAP_ENABLED}" = 1 ]; then
		swapoff "${SWAP_FILE}" >/dev/null 2>&1 || true
	fi
	rm -f "${INITD}" "${CONFD}" "${SETTINGS_FILE}" "${EXPECTED_FILE}" "${ACTUAL_FILE}" "${PIDFILE}" "${SWAP_FILE}" || true
}
trap cleanup EXIT

add_setting()
{
	local key="$1" value="$2" expected="$3"

	[ -f "/sys/fs/cgroup/${key}" ] || return 0
	printf '%s %s\n' "${key}" "${value}" >> "${SETTINGS_FILE}"
	printf '%s	%s\n' "${key}" "${expected}" >> "${EXPECTED_FILE}"
}

first_cpuset_item()
{
	local value="$1"

	value="${value%%,*}"
	value="${value%%-*}"
	printf '%s' "${value}"
}

setup_swap()
{
	command -v mkswap >/dev/null || fail "missing mkswap"
	command -v swapon >/dev/null || fail "missing swapon"
	command -v swapoff >/dev/null || fail "missing swapoff"

	rm -f "${SWAP_FILE}"
	dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=64 >/dev/null 2>&1
	chmod 600 "${SWAP_FILE}"
	mkswap "${SWAP_FILE}" >/dev/null
	swapon "${SWAP_FILE}"
	SWAP_ENABLED=1

	if [ -w /sys/module/zswap/parameters/enabled ]; then
		printf 1 > /sys/module/zswap/parameters/enabled || true
	fi
}

print_settings_diff()
{
	if command -v diff >/dev/null; then
		diff -u "${EXPECTED_FILE}" "${ACTUAL_FILE}" >&2 || true
		return
	fi

	echo "expected cgroup settings:" >&2
	cat "${EXPECTED_FILE}" >&2
	echo "actual cgroup settings:" >&2
	cat "${ACTUAL_FILE}" >&2
}

main()
{
	local cpuset_cpus="" cpuset_mems="" cgroup_file="" key=""
	local i=0 daemon_pid="" checked=0 mismatch=0 actual="" expected=""
	local service_pids="" pid="" actual_cgroup="<not running>"
	local hierarchy="" controllers="" process_cgroup=""

	setup_openrc_path
	: > "${SETTINGS_FILE}"
	: > "${EXPECTED_FILE}"

	assert_init_layout "after boot"
	rc-service cgroups status >/dev/null || fail "cgroups service is not started"

	# Exercise idempotency against an already mounted and initialized hierarchy.
	rc-service cgroups zap >/dev/null
	rc-service cgroups start >/dev/null
	assert_init_layout "after restarting cgroups"

	setup_swap

	add_setting cpu.weight 200 200
	add_setting cpu.max "100000 100000" "100000 100000"
	add_setting cpu.max.burst 10000 10000
	add_setting cpu.idle 1 1

	if [ -r /sys/fs/cgroup/cpuset.cpus.effective ]; then
		cpuset_cpus="$(first_cpuset_item "$(cat /sys/fs/cgroup/cpuset.cpus.effective)")"
		[ -z "${cpuset_cpus}" ] || add_setting cpuset.cpus "${cpuset_cpus}" "${cpuset_cpus}"
	fi
	if [ -r /sys/fs/cgroup/cpuset.mems.effective ]; then
		cpuset_mems="$(first_cpuset_item "$(cat /sys/fs/cgroup/cpuset.mems.effective)")"
		[ -z "${cpuset_mems}" ] || add_setting cpuset.mems "${cpuset_mems}" "${cpuset_mems}"
	fi

	add_setting io.weight "default 200" "default 200"

	add_setting memory.min 1048576 1048576
	add_setting memory.low 2097152 2097152
	add_setting memory.high 25165824 25165824
	add_setting memory.max 33554432 33554432
	add_setting memory.oom.group 1 1
	add_setting memory.swap.high 16777216 16777216
	add_setting memory.swap.max 33554432 33554432
	add_setting memory.zswap.max 16777216 16777216
	add_setting memory.zswap.writeback 1 1

	add_setting pids.max 64 64

	for cgroup_file in /sys/fs/cgroup/hugetlb.*.max /sys/fs/cgroup/hugetlb.*.rsvd.max; do
		[ -f "${cgroup_file}" ] || continue
		key="${cgroup_file#/sys/fs/cgroup/}"
		add_setting "${key}" 0 0
	done

	[ -s "${SETTINGS_FILE}" ] || fail "no writable cgroup v2 settings were selected"

	cat > "${INITD}" <<-EOF_INIT
		#!/sbin/openrc-run

		description="OpenRC cgroup v2 test service"
		command="/bin/sleep"
		command_args="600"
		command_background=true
		pidfile="${PIDFILE}"
		EOF_INIT
	chmod 755 "${INITD}"

	{
		printf "%s\n" "rc_cgroup_settings='"
		cat "${SETTINGS_FILE}"
		printf "%s\n" "'"
	} > "${CONFD}"

	rc-service cgroups start
	rc-service "${SVC}" start

	i=0
	while [ "${i}" -lt 50 ]; do
		daemon_pid=
		if [ -s "${PIDFILE}" ] &&
			read -r daemon_pid < "${PIDFILE}" &&
			[ -n "${daemon_pid}" ] &&
			[ -s "${CGROUP_PATH}/cgroup.procs" ] &&
			grep -qx "${daemon_pid}" "${CGROUP_PATH}/cgroup.procs"; then
			break
		fi
		i=$((i + 1))
		sleep 0.1
	done
	[ -d "${CGROUP_PATH}" ] || fail "missing cgroup ${CGROUP_PATH}"
	[ -s "${PIDFILE}" ] || fail "missing service pidfile ${PIDFILE}"
	read -r daemon_pid < "${PIDFILE}"
	case "${daemon_pid}" in
		''|*[!0-9]*) fail "invalid service pidfile ${PIDFILE}: ${daemon_pid}" ;;
	esac
	if ! grep -qx "${daemon_pid}" "${CGROUP_PATH}/cgroup.procs"; then
		if [ -r "/proc/${daemon_pid}/cgroup" ]; then
			while IFS=: read -r hierarchy controllers process_cgroup; do
				if [ "${hierarchy}" = 0 ] && [ -z "${controllers}" ]; then
					actual_cgroup="${process_cgroup}"
					break
				fi
			done < "/proc/${daemon_pid}/cgroup"
		fi
		fail "service pid ${daemon_pid} is not in ${CGROUP_PATH}; actual cgroup: ${actual_cgroup}"
	fi

	checked=0
	mismatch=0
	: > "${ACTUAL_FILE}"
	while IFS='	' read -r key expected; do
		[ -n "${key}" ] || continue
		if [ -f "${CGROUP_PATH}/${key}" ]; then
			actual="$(cat "${CGROUP_PATH}/${key}")"
		else
			actual="<missing>"
		fi
		printf '%s	%s\n' "${key}" "${actual}" >> "${ACTUAL_FILE}"
		[ "${actual}" = "${expected}" ] || mismatch=1
		checked=$((checked + 1))
	done < "${EXPECTED_FILE}"

	[ "${checked}" -gt 0 ] || fail "no cgroup settings were checked"
	if [ "${mismatch}" = 1 ]; then
		print_settings_diff
		fail "cgroup settings do not match expected values"
	fi

	service_pids="$(cat "${CGROUP_PATH}/cgroup.procs")"
	rc-service "${SVC}" stop

	i=0
	while [ "${i}" -lt 50 ]; do
		[ ! -e "${CGROUP_PATH}" ] && break
		i=$((i + 1))
		sleep 0.1
	done
	[ ! -e "${CGROUP_PATH}" ] || fail "${CGROUP_PATH} was not removed after stop"

	for pid in ${service_pids}; do
		[ ! -d "/proc/${pid}" ] || fail "service pid ${pid} is still running"
	done

	echo "checked ${checked} cgroup v2 settings"
	echo "service cgroup removed: ${CGROUP_PATH}"
	echo "service pids:"
	printf '%s\n' "${service_pids}"
}

main "$@"
