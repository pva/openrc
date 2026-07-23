#!/usr/bin/env bash
# Run the complete OpenRC QEMU test workflow in a new per-run directory.
# Usage: tests-run.sh [QEMU_TEST_ROOT] [SOURCE_DIR]
# Set UPGRADE_FROM to an OpenRC tag/revision to exercise an old-to-current upgrade.

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=tools/qemu/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=tools/qemu/lib/qemu.sh
. "${SCRIPT_DIR}/lib/qemu.sh"
# shellcheck source=tools/qemu/lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=tools/qemu/lib/guest.sh
. "${SCRIPT_DIR}/lib/guest.sh"

need_cmd git
need_cmd qemu-img
need_cmd qemu-system-x86_64
need_cmd realpath
need_cmd sha256sum
need_cmd socat
need_cmd ssh
need_cmd tar

qemu_root_init "${1:-qemu-tests}"
SOURCE_DIR="$(realpath_m "${2:-${REPO_ROOT}}")"
RUN_ID="${RUN_ID:-$(run_id_default)}"
UPGRADE_FROM="${UPGRADE_FROM:-}"
UPGRADE_EXPECTED_VERSION="${UPGRADE_EXPECTED_VERSION:-${UPGRADE_FROM#v}}"
GUEST_TESTS="${GUEST_TESTS:-cgroup2/boot.sh cgroup2/delegated.sh cgroup2/service.sh}"
QEMU_EXIT_WAIT="${QEMU_EXIT_WAIT:-60}"
CURRENT_REPO=
CURRENT_VERSION=
HISTORY_REPO=

[ -d "${SOURCE_DIR}/.git" ] || die "source directory is not a Git checkout: ${SOURCE_DIR}"
[ -f "${SOURCE_DIR}/meson.build" ] || die "source directory has no meson.build: ${SOURCE_DIR}"

project_version()
{
	sed -n "s/^[[:space:]]*version : '\([^']*\)'.*/\1/p" \
		"${SOURCE_DIR}/meson.build" | sed -n '1p'
}

stage_current_source()
{
	local content_id tree version_prefix

	CURRENT_REPO="${G_SHARE_DIR}/source/current"
	mkdir -- "${CURRENT_REPO}"
	log "staging the current worktree in ${CURRENT_REPO}"
	git -C "${SOURCE_DIR}" ls-files -z --cached --others --exclude-standard |
		tar -C "${SOURCE_DIR}" --null -T - --ignore-failed-read -cf - |
		tar -C "${CURRENT_REPO}" -xf -

	git -C "${CURRENT_REPO}" init -q -b openrc-qemu
	git -C "${CURRENT_REPO}" add -A
	git -C "${CURRENT_REPO}" \
		-c user.name='OpenRC QEMU' \
		-c user.email=openrc-qemu@example.invalid \
		commit -q -m 'OpenRC QEMU worktree snapshot'
	tree="$(git -C "${CURRENT_REPO}" rev-parse 'HEAD^{tree}')"
	content_id="${tree:0:12}"
	version_prefix="$(project_version)"
	[ -n "${version_prefix}" ] || die "cannot read the OpenRC project version"
	CURRENT_VERSION="${version_prefix}-qemu-${content_id}"
	git -C "${CURRENT_REPO}" \
		-c user.name='OpenRC QEMU' \
		-c user.email=openrc-qemu@example.invalid \
		tag -a "${CURRENT_VERSION}" -m "${CURRENT_VERSION}"
}

stage_history()
{
	[ -n "${UPGRADE_FROM}" ] || return 0
	HISTORY_REPO="${G_SHARE_DIR}/source/history.git"
	log "staging repository history for upgrade from ${UPGRADE_FROM}"
	git -C "${SOURCE_DIR}" rev-parse --verify "${UPGRADE_FROM}^{commit}" >/dev/null ||
		die "upgrade revision does not exist in the source repository: ${UPGRADE_FROM}"
	git clone -q --bare --no-local "${SOURCE_DIR}" "${HISTORY_REPO}"
	git -C "${HISTORY_REPO}" rev-parse --verify "${UPGRADE_FROM}^{commit}" >/dev/null
}

run_guest_test()
{
	"${SCRIPT_DIR}/tests-run-guest.sh" "${G_RUN_DIR}" "$@"
}

run_selected_guest_tests()
{
	local guest_test

	# shellcheck disable=SC2086 # GUEST_TESTS is intentionally a whitespace list.
	for guest_test in ${GUEST_TESTS}; do
		run_guest_test "${guest_test}"
	done
}

cleanup()
{
	local status=$?

	trap - EXIT INT TERM
	set +e
	guest_shutdown 10 >/dev/null 2>&1 || true
	if [ "${status}" -ne 0 ] && [ -n "${G_RUN_DIR:-}" ]; then
		log "test run failed; artifacts are preserved in ${G_RUN_DIR}"
		if [ -s "${G_QEMU_LOG:-}" ]; then
			log "last QEMU messages:"
			tail -100 "${G_QEMU_LOG}" >&2
		fi
		if [ -s "${G_SERIAL_LOG:-}" ]; then
			log "last serial-console messages:"
			tail -100 "${G_SERIAL_LOG}" >&2
		fi
	fi
	exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

qemu_run_create "${RUN_ID}"
log "run directory: ${G_RUN_DIR}"
cp -a -- "${SCRIPT_DIR}/guest/setup" "${G_SHARE_DIR}/tests/"
cp -a -- "${SCRIPT_DIR}/guest/tests/." "${G_SHARE_DIR}/tests/"
stage_current_source
stage_history
qemu_overlay_create

guest_start
ssh_exec "openrc --version" | tee "${G_RESULTS_DIR}/version-base.log"

if [ -n "${UPGRADE_FROM}" ]; then
	guest_install_openrc /mnt/host/source/history.git \
		"${UPGRADE_FROM}" "${UPGRADE_EXPECTED_VERSION}" old
	guest_reboot
	run_guest_test upgrade/services.sh record

	guest_install_openrc /mnt/host/source/current \
		"${CURRENT_VERSION}" "${CURRENT_VERSION}" current
	# A package update must not disturb services which are already running.
	run_guest_test upgrade/services.sh check live-upgrade
	guest_reboot
	# The same runlevel services must also come back under the new OpenRC.
	run_guest_test upgrade/services.sh check reboot
else
	guest_install_openrc /mnt/host/source/current \
		"${CURRENT_VERSION}" "${CURRENT_VERSION}" current
	guest_reboot
fi

ssh_exec "openrc --version; rc-service cgroups status" |
	tee "${G_RESULTS_DIR}/version-tested.log"

run_selected_guest_tests

guest_shutdown "${QEMU_EXIT_WAIT}" ||
	die "guest did not shut down cleanly; see ${G_QEMU_LOG}"

printf 'PASS\nversion=%s\nupgrade_from=%s\n' \
	"${CURRENT_VERSION}" "${UPGRADE_FROM:-none}" > "${G_RESULTS_DIR}/summary.txt"
log "all tests passed; artifacts: ${G_RUN_DIR}"
