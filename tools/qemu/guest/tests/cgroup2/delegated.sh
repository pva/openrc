#!/usr/bin/env bash
#
# Exercise the cgroups service from a delegated cgroup namespace root.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/guest/tests/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

DELEGATE_NAME="openrc-cgroup-ns-test"
DELEGATE_PATH="/sys/fs/cgroup/${DELEGATE_NAME}"

cleanup_delegate()
{
	local controller enabled pid

	[ -d "${DELEGATE_PATH}" ] || return 0
	if [ -e "${DELEGATE_PATH}/rc.init/cgroup.procs" ]; then
		while read -r pid; do
			[ -n "${pid}" ] || continue
			printf '%s' "${pid}" > /sys/fs/cgroup/rc.init/cgroup.procs 2>/dev/null || true
		done < "${DELEGATE_PATH}/rc.init/cgroup.procs"
		rmdir "${DELEGATE_PATH}/rc.init" 2>/dev/null || true
	fi
	if [ -r "${DELEGATE_PATH}/cgroup.subtree_control" ]; then
		read -r enabled < "${DELEGATE_PATH}/cgroup.subtree_control" || enabled=
		for controller in ${enabled}; do
			printf -- '-%s' "${controller}" > "${DELEGATE_PATH}/cgroup.subtree_control" 2>/dev/null || true
		done
	fi
	rmdir "${DELEGATE_PATH}" 2>/dev/null || true
}

run_inner()
{
	local extra_stopped_commands=""

	# A mount created after entering a cgroup namespace is rooted at the
	# namespace root instead of exposing the host's complete hierarchy.
	umount /sys/fs/cgroup

	# shellcheck source=sh/rc-cgroup.sh
	. "${RC_LIBEXECDIR}/sh/rc-cgroup.sh"
	# shellcheck source=init.d/cgroups.in
	. /etc/init.d/cgroups

	cgroups_unified

	mountinfo -q -f '^cgroup2$' /sys/fs/cgroup || fail "delegated cgroup2 mount is missing"
	[ -e /sys/fs/cgroup/rc.init/cgroup.procs ] || fail "delegated rc.init was not created"
	grep -qx "$$" /sys/fs/cgroup/rc.init/cgroup.procs || fail "test process was not moved to delegated rc.init"
	[ ! -s /sys/fs/cgroup/cgroup.procs ] || fail "delegated cgroup root still contains processes"
	assert_controllers_enabled "the delegated root"

	echo "delegated cgroup namespace root initialized successfully"
}

setup_openrc_path
[ -f "${RC_LIBEXECDIR}/sh/rc-cgroup.sh" ] ||
	fail "cannot find installed rc-cgroup.sh"
if [ "${1:-}" = --inner ]; then
	run_inner
	exit 0
fi

[ "$(id -u)" -eq 0 ] || fail "test must run as root"
command -v unshare >/dev/null || fail "missing unshare"
mountinfo -q -f '^cgroup2$' /sys/fs/cgroup || fail "/sys/fs/cgroup is not cgroup2"
[ -e /sys/fs/cgroup/rc.init/cgroup.procs ] || fail "host rc.init is missing"

cleanup_delegate
trap cleanup_delegate EXIT
mkdir "${DELEGATE_PATH}"

(
	printf '%s' "${BASHPID}" > "${DELEGATE_PATH}/cgroup.procs"
	exec unshare --cgroup --mount --propagation private bash "$0" --inner
)

[ -e "${DELEGATE_PATH}/rc.init/cgroup.procs" ] || fail "delegated rc.init is not visible from the host hierarchy"
[ ! -s "${DELEGATE_PATH}/rc.init/cgroup.procs" ] || fail "delegated rc.init still contains processes"

echo "delegated cgroup v2 test passed"
