#!/usr/bin/env bash

# Guest operations combining SSH and QEMU.

guest_start()
{
	qemu_start
	ssh_init
	ssh_wait_ready
}

guest_reboot()
{
	log "rebooting guest"
	ssh_exec "sync; reboot" >/dev/null 2>&1 || true
	ssh_wait_unready
	ssh_wait_ready
}

guest_shutdown()
{
	local wait_seconds="${1:-60}"

	qemu_is_started || return 0
	ssh_poweroff
	qemu_shutdown "${wait_seconds}"
}

guest_install_openrc()
{
	local repository="$1" revision="$2" expected="$3" label="$4"
	local command log_file status

	command="$(shell_join bash /mnt/host/tests/setup/install-openrc.sh \
		"${repository}" "${revision}" "${expected}" "${label}")"
	log_file="${G_RESULTS_DIR}/install-${label}.log"
	log "installing OpenRC ${revision} in the guest"
	set +e
	ssh_exec "${command}" 2>&1 | tee "${log_file}"
	status=${PIPESTATUS[0]}
	set -e
	[ "${status}" -eq 0 ] || die "guest OpenRC install failed; log: ${log_file}"
}
