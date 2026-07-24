#!/usr/bin/env bash

# Shared helpers for guest-side cgroup tests.

CGROUP_TEST_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/guest/tests/lib/common.sh
. "${CGROUP_TEST_LIB_DIR}/../lib/common.sh"
unset CGROUP_TEST_LIB_DIR

cgroup_process_is_kthread()
{
	local flags line pid="$1"

	[ -r "/proc/${pid}/stat" ] || return 1
	read -r line < "/proc/${pid}/stat" || return 1
	line="${line##*) }"
	# shellcheck disable=SC2086 # Split the stat fields intentionally.
	set -- ${line}
	flags="${7:-}"
	[ -n "${flags}" ] || return 1
	[ $((flags & 2097152)) -ne 0 ]
}

assert_root_has_only_kthreads()
{
	local pid unexpected=

	while read -r pid; do
		[ -n "${pid}" ] || continue
		[ -d "/proc/${pid}" ] || continue
		cgroup_process_is_kthread "${pid}" || unexpected="${unexpected} ${pid}"
	done < /sys/fs/cgroup/cgroup.procs

	[ -z "${unexpected}" ] ||
		fail "userspace pids remain in the cgroup v2 root:${unexpected}"
}

assert_controllers_enabled()
{
	local context="${1:-the cgroup v2 root}"
	local available controller enabled

	read -r available < /sys/fs/cgroup/cgroup.controllers
	read -r enabled < /sys/fs/cgroup/cgroup.subtree_control
	[ -n "${available}" ] || fail "${context} exposes no controllers"
	for controller in ${available}; do
		case " ${enabled} " in
			*" ${controller} "*) ;;
			*) fail "controller ${controller} is not enabled in ${context}" ;;
		esac
	done
}

assert_cgroup_empty()
{
	local cgroup_procs="$1" context="$2" pid

	[ -e "${cgroup_procs}" ] ||
		fail "${context}: missing ${cgroup_procs}"
	if read -r pid < "${cgroup_procs}"; then
		fail "${context}: process ${pid} remains in ${cgroup_procs}"
	fi
}

assert_init_layout()
{
	local context="$1"

	mountinfo -q -f '^cgroup2$' /sys/fs/cgroup ||
		fail "${context}: /sys/fs/cgroup is not cgroup2"
	[ -e /sys/fs/cgroup/rc.init/cgroup.procs ] ||
		fail "${context}: missing rc.init/cgroup.procs"
	grep -qx 1 /sys/fs/cgroup/rc.init/cgroup.procs ||
		fail "${context}: pid 1 is not in rc.init"
	assert_root_has_only_kthreads
	assert_controllers_enabled
}
