#!/usr/bin/env bash
#
# Intended to be run inside the Gentoo QEMU guest created by our test image tools.

set -eu

svc="cgtest"
initd="/etc/init.d/${svc}"
confd="/etc/conf.d/${svc}"
settings_file="/run/${svc}.cgroup-settings"
expected_file="/run/${svc}.cgroup-expected"
actual_file="/run/${svc}.cgroup-actual"
pidfile="/run/${svc}.pid"
cgroup_path="/sys/fs/cgroup/openrc.${svc}"
swap_file="/swap-openrc-cgroup-test"
swap_enabled=0

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

cleanup()
{
	rc-service "${svc}" stop >/dev/null 2>&1 || true
	if [ "${swap_enabled}" = 1 ]; then
		swapoff "${swap_file}" >/dev/null 2>&1 || true
	fi
	rm -f "${initd}" "${confd}" "${settings_file}" "${expected_file}" "${actual_file}" "${pidfile}" "${swap_file}"
}
trap cleanup EXIT

add_setting()
{
	key="$1"
	value="$2"
	expected="$3"
	[ -f "/sys/fs/cgroup/${key}" ] || return 0
	printf '%s %s\n' "${key}" "${value}" >> "${settings_file}"
	printf '%s	%s\n' "${key}" "${expected}" >> "${expected_file}"
}

first_cpuset_item()
{
	value="$1"
	value="${value%%,*}"
	value="${value%%-*}"
	printf '%s' "${value}"
}

setup_swap()
{
	command -v mkswap >/dev/null || fail "missing mkswap"
	command -v swapon >/dev/null || fail "missing swapon"
	command -v swapoff >/dev/null || fail "missing swapoff"

	rm -f "${swap_file}"
	dd if=/dev/zero of="${swap_file}" bs=1M count=64 >/dev/null 2>&1
	chmod 600 "${swap_file}"
	mkswap "${swap_file}" >/dev/null
	swapon "${swap_file}"
	swap_enabled=1

	if [ -w /sys/module/zswap/parameters/enabled ]; then
		printf 1 > /sys/module/zswap/parameters/enabled || true
	fi
}

print_settings_diff()
{
	if command -v diff >/dev/null; then
		diff -u "${expected_file}" "${actual_file}" >&2 || true
		return
	fi

	echo "expected cgroup settings:" >&2
	cat "${expected_file}" >&2
	echo "actual cgroup settings:" >&2
	cat "${actual_file}" >&2
}

: > "${settings_file}"
: > "${expected_file}"

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

for file in /sys/fs/cgroup/hugetlb.*.max /sys/fs/cgroup/hugetlb.*.rsvd.max; do
	[ -f "${file}" ] || continue
	key="${file#/sys/fs/cgroup/}"
	add_setting "${key}" 0 0
done

[ -s "${settings_file}" ] || fail "no writable cgroup v2 settings were selected"

cat > "${initd}" <<-EOF_INIT
	#!/sbin/openrc-run

	description="OpenRC cgroup v2 test service"
	command="/bin/sleep"
	command_args="600"
	command_background=true
	pidfile="${pidfile}"
	EOF_INIT
chmod 755 "${initd}"

{
	printf "%s\n" "rc_cgroup_settings='"
	cat "${settings_file}"
	printf "%s\n" "'"
} > "${confd}"

rc-service cgroups start
rc-service "${svc}" start

i=0
while [ "${i}" -lt 50 ]; do
	[ -d "${cgroup_path}" ] && break
	i=$((i + 1))
	sleep 0.1
done
[ -d "${cgroup_path}" ] || fail "missing cgroup ${cgroup_path}"
[ -s "${cgroup_path}/cgroup.procs" ] || fail "empty ${cgroup_path}/cgroup.procs"

checked=0
mismatch=0
: > "${actual_file}"
while IFS='	' read -r key expected; do
	[ -n "${key}" ] || continue
	if [ -f "${cgroup_path}/${key}" ]; then
		actual="$(cat "${cgroup_path}/${key}")"
	else
		actual="<missing>"
	fi
	printf '%s	%s\n' "${key}" "${actual}" >> "${actual_file}"
	[ "${actual}" = "${expected}" ] || mismatch=1
	checked=$((checked + 1))
done < "${expected_file}"

[ "${checked}" -gt 0 ] || fail "no cgroup settings were checked"
if [ "${mismatch}" = 1 ]; then
	print_settings_diff
	fail "cgroup settings do not match expected values"
fi

service_pids="$(cat "${cgroup_path}/cgroup.procs")"

rc-service "${svc}" stop

i=0
while [ "${i}" -lt 50 ]; do
	[ ! -e "${cgroup_path}" ] && break
	i=$((i + 1))
	sleep 0.1
done
[ ! -e "${cgroup_path}" ] || fail "${cgroup_path} was not removed after stop"

for pid in ${service_pids}; do
	[ ! -d "/proc/${pid}" ] || fail "service pid ${pid} is still running"
done

echo "checked ${checked} cgroup v2 settings"
echo "service cgroup removed: ${cgroup_path}"
echo "service pids:"
printf '%s\n' "${service_pids}"
