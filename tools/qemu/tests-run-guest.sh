#!/usr/bin/env bash
# Run any staged guest test over the per-run SSH Unix socket.
# Usage: tests-run-guest.sh RUN_DIR TEST_PATH [TEST_ARGUMENT ...]

set -euo pipefail

PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/qemu/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=tools/qemu/lib/qemu.sh
. "${SCRIPT_DIR}/lib/qemu.sh"
# shellcheck source=tools/qemu/lib/ssh.sh
. "${SCRIPT_DIR}/lib/ssh.sh"

need_cmd realpath
need_cmd sha256sum
need_cmd socat
need_cmd ssh

main()
{
	local requested_run test_path host_test result_id result_log guest_test
	local remote_command status arg

	[ "$#" -ge 2 ] || die "usage: ${PROG} RUN_DIR TEST_PATH [TEST_ARGUMENT ...]"
	requested_run="$1"
	test_path="$2"
	shift 2

	case "${test_path}" in
		/*|../*|*/../*|*/..|./*|*/./*|*/.|*//*)
			die "guest test must be relative and must not contain dot components: ${test_path}"
			;;
		*.sh) ;;
		*) die "guest test must have a .sh suffix: ${test_path}" ;;
	esac

	qemu_run_load "${requested_run}"
	host_test="$(realpath_m "${G_SHARE_DIR}/tests/${test_path}")"
	case "${host_test}" in
		"${G_SHARE_DIR}/tests/"*) ;;
		*) die "guest test escapes the staged test directory: ${test_path}" ;;
	esac
	[ -f "${host_test}" ] || die "guest test does not exist: ${host_test}"

	ssh_init
	result_id="${test_path%.sh}"
	for arg in "$@"; do
		result_id="${result_id}-${arg}"
	done
	result_id="$(printf '%s' "${result_id}" | tr -c 'A-Za-z0-9._-' '-')"
	result_log="${G_RESULTS_DIR}/${result_id}.log"
	guest_test="/mnt/host/tests/${test_path}"
	remote_command="$(shell_join bash "${guest_test}" "$@")"

	log "running guest test ${test_path}"
	set +e
	ssh_exec "${remote_command}" 2>&1 | tee "${result_log}"
	status=${PIPESTATUS[0]}
	set -e
	if [ "${status}" -ne 0 ]; then
		log "guest test failed with status ${status}; log: ${result_log}"
		return "${status}"
	fi
	log "guest test passed; log: ${result_log}"
}

main "$@"
