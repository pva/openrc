#!/usr/bin/env bash

# SSH transport over QEMU's hostfwd Unix socket.

# shellcheck disable=SC2029,SC2154

# Global context owned and populated by this library.
# Whether the SSH client arguments have been initialized.
declare -g G_SSH_INITIALIZED=0
# Prepared command-line arguments for the SSH client.
declare -ag G_SSH_ARGS=()

ssh_is_initialized()
{
	[ "${G_SSH_INITIALIZED}" = 1 ]
}

ssh_init()
{
	G_SSH_INITIALIZED=0
	[ -r "${G_SSH_PRIVATE_KEY}" ] || die "SSH private key not found: ${G_SSH_PRIVATE_KEY}"
	[ -r "${G_SSH_KNOWN_HOSTS}" ] || die "SSH known-hosts file not found: ${G_SSH_KNOWN_HOSTS}"

	G_SSH_ARGS=(
		-o BatchMode=yes
		-o ConnectTimeout=3
		-o ConnectionAttempts=1
		-o IdentitiesOnly=yes
		-o "IdentityFile=${G_SSH_PRIVATE_KEY}"
		-o StrictHostKeyChecking=yes
		-o "UserKnownHostsFile=${G_SSH_KNOWN_HOSTS}"
		-o HostKeyAlias=openrc-qemu
		-o LogLevel=ERROR
		-o "ProxyCommand=socat - UNIX-CONNECT:${G_SSH_SOCKET}"
	)
	G_SSH_INITIALIZED=1
}

ssh_exec()
{
	local remote_command="${1:-true}"

	ssh "${G_SSH_ARGS[@]}" root@openrc-qemu "${remote_command}"
}

ssh_wait_ready()
{
	local i

	SSH_WAIT="${SSH_WAIT:-90}"
	log "waiting for SSH at ${G_SSH_SOCKET}"
	for ((i = 0; i < SSH_WAIT; i++)); do
		if ! qemu_is_running; then
			die "QEMU exited before SSH became ready; see ${G_QEMU_LOG}"
		fi
		if [ -S "${G_SSH_SOCKET}" ] && ssh_exec true >/dev/null 2>&1; then
			log "SSH is ready"
			return 0
		fi
		sleep 1
	done
	die "SSH did not become ready: ${G_SSH_SOCKET}"
}

ssh_wait_unready()
{
	local i

	ssh_is_initialized || return 0
	SSH_SHUTDOWN_WAIT="${SSH_SHUTDOWN_WAIT:-60}"
	for ((i = 0; i < SSH_SHUTDOWN_WAIT; i++)); do
		if ! ssh_exec true >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	die "SSH remained available after shutdown was requested"
}

ssh_poweroff()
{
	ssh_is_initialized || return 0
	log "powering guest off"
	ssh_exec "sync; poweroff" >/dev/null 2>&1 || true
}
