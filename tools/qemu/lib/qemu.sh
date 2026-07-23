#!/usr/bin/env bash

# QEMU paths, per-run state, and process lifecycle.

# Global context owned and populated by this library.
# shellcheck disable=SC2034 # Some fields are consumed by sibling libraries.
# Root directory containing all QEMU test state.
declare -g G_QEMU_ROOT=
# Directory containing reusable images and SSH keys.
declare -g G_IMAGE_DIR=
# Directory containing per-run state and artifacts.
declare -g G_RUNS_DIR=
# Reusable base image used as the overlay backing file.
declare -g G_BASE_IMAGE=
# Directory containing the test SSH key material.
declare -g G_SSH_KEY_DIR=
# Private key used by the host SSH client.
declare -g G_SSH_PRIVATE_KEY=
# Known-hosts file containing the guest SSH host key.
declare -g G_SSH_KNOWN_HOSTS=
# Directory containing state for the active run.
declare -g G_RUN_DIR=
# Disposable qcow2 overlay used by the active run.
declare -g G_OVERLAY_IMAGE=
# Host directory mounted read-only inside the guest.
declare -g G_SHARE_DIR=
# Directory receiving test results from the active run.
declare -g G_RESULTS_DIR=
# File receiving the guest serial-console output.
declare -g G_SERIAL_LOG=
# File receiving QEMU diagnostics and standard error.
declare -g G_QEMU_LOG=
# Pidfile written by QEMU for the active run.
declare -g G_QEMU_PIDFILE=
# Unix socket forwarding host SSH connections to the guest.
declare -g G_SSH_SOCKET=
# Prepared command-line arguments for QEMU.
declare -ag G_QEMU_ARGS=()
# PID of the QEMU child process started by this shell.
declare -g G_QEMU_PID=
# PID of the shell which started the QEMU child process.
declare -g G_QEMU_PARENT_PID=
# Whether QEMU startup has begun and runtime cleanup is still pending.
declare -g G_QEMU_STARTED=0

qemu_root_init()
{
	local requested_root="${1:-qemu-tests}"

	G_QEMU_ROOT="$(realpath_m "${requested_root}")"
	G_IMAGE_DIR="${G_QEMU_ROOT}/images"
	G_RUNS_DIR="${G_QEMU_ROOT}/runs"
	G_BASE_IMAGE="$(realpath_m "${IMAGE:-${G_IMAGE_DIR}/gentoo-base.qcow2}")"
	G_SSH_KEY_DIR="${G_IMAGE_DIR}/ssh"
	G_SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-${G_SSH_KEY_DIR}/id_ed25519}"
	G_SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-${G_SSH_KEY_DIR}/known_hosts}"

	mkdir -p -- "${G_IMAGE_DIR}" "${G_RUNS_DIR}"
}

qemu_run_paths()
{
	local socket_id

	G_RUN_DIR="$(realpath_m "$1")"
	G_OVERLAY_IMAGE="${G_RUN_DIR}/overlay.qcow2"
	G_SHARE_DIR="${G_RUN_DIR}/share"
	G_RESULTS_DIR="${G_RUN_DIR}/results"
	G_SERIAL_LOG="${G_RUN_DIR}/serial.log"
	G_QEMU_LOG="${G_RUN_DIR}/qemu.log"
	G_QEMU_PIDFILE="${G_RUN_DIR}/qemu.pid"

	# QEMU through 10.2 mistakes dashes in a Unix hostfwd path for the
	# host/guest separator. Use a deterministic, short, dash-free path so a
	# separate process loading this run derives the same socket name.
	# https://gitlab.com/qemu-project/qemu/-/commit/2ec80ad92840df9750e9ad5beed494cb0b202ba9
	socket_id="$(printf '%s' "${G_RUN_DIR}" | sha256sum)"
	socket_id="${socket_id%% *}"
	G_SSH_SOCKET="/tmp/openrc_qemu_${socket_id:0:24}.socket"
}

qemu_run_create()
{
	local requested_id="${1:-$(run_id_default)}"

	validate_name run-id "${requested_id}"
	qemu_run_paths "${G_RUNS_DIR}/${requested_id}"
	if ! mkdir -- "${G_RUN_DIR}"; then
		die "run directory already exists: ${G_RUN_DIR}"
	fi
	mkdir -p -- \
		"${G_SHARE_DIR}/source" \
		"${G_SHARE_DIR}/tests" \
		"${G_RESULTS_DIR}"
	: > "${G_SERIAL_LOG}"
	: > "${G_QEMU_LOG}"
}

qemu_run_load()
{
	local requested_run

	requested_run="$(realpath_m "$1")"
	[ -d "${requested_run}" ] || die "run directory does not exist: ${requested_run}"
	qemu_root_init "$(dirname -- "$(dirname -- "${requested_run}")")"
	qemu_run_paths "${requested_run}"
	[ -d "${G_SHARE_DIR}" ] || die "run share directory does not exist: ${G_SHARE_DIR}"
	mkdir -p -- "${G_RESULTS_DIR}"
}

qemu_overlay_create()
{
	[ -f "${G_BASE_IMAGE}" ] ||
		die "base image not found: ${G_BASE_IMAGE}; run tools/qemu/image-build.sh first"
	[ ! -e "${G_OVERLAY_IMAGE}" ] || die "overlay already exists: ${G_OVERLAY_IMAGE}"
	log "creating disposable overlay ${G_OVERLAY_IMAGE}"
	qemu-img create -f qcow2 -F qcow2 -b "${G_BASE_IMAGE}" "${G_OVERLAY_IMAGE}"
}

qemu_pid()
{
	local pid=

	if [ -r "${G_QEMU_PIDFILE}" ]; then
		read -r pid < "${G_QEMU_PIDFILE}" || pid=
	fi
	case "${pid}" in
		''|*[!0-9]*) pid="${G_QEMU_PID:-}" ;;
	esac
	case "${pid}" in
		''|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "${pid}"
}

qemu_is_started()
{
	[ "${G_QEMU_STARTED}" = 1 ]
}

qemu_is_running()
{
	local pid

	pid="$(qemu_pid)" || return 1
	kill -0 "${pid}" 2>/dev/null
}

qemu_assert_not_running()
{
	local pid

	if pid="$(qemu_pid)" && kill -0 "${pid}" 2>/dev/null; then
		die "QEMU is already running for ${G_RUN_DIR} with pid ${pid}"
	fi
	if [ -e "${G_SSH_SOCKET}" ] || [ -L "${G_SSH_SOCKET}" ]; then
		die "SSH socket path already exists: ${G_SSH_SOCKET}"
	fi
}

qemu_check_socket_path()
{
	# sockaddr_un.sun_path is 108 bytes on Linux. Leave room for QEMU's handling.
	[ "${#G_SSH_SOCKET}" -lt 100 ] ||
		die "SSH socket path is too long for a Unix socket: ${G_SSH_SOCKET}"
	case "${G_SSH_SOCKET}" in
		*-*) die "SSH socket path contains a dash unsupported by older QEMU: ${G_SSH_SOCKET}" ;;
	esac
}

qemu_prepare_args()
{
	local serial_mode="${1:-file}"
	local share_opts

	MEM="${MEM:-1024}"
	SMP="${SMP:-2}"
	QEMU_ACCEL="${QEMU_ACCEL:-kvm}"
	case "${QEMU_ACCEL}" in
		kvm)
			[ -e /dev/kvm ] || die "/dev/kvm is unavailable; set QEMU_ACCEL=tcg"
			;;
		tcg) ;;
		*) die "unsupported QEMU_ACCEL: ${QEMU_ACCEL}" ;;
	esac
	case "${serial_mode}" in
		file|stdio) ;;
		*) die "unsupported serial mode: ${serial_mode}" ;;
	esac

	qemu_check_socket_path
	share_opts="local,path=${G_SHARE_DIR},mount_tag=hostshare,security_model=none,readonly=on"
	G_QEMU_ARGS=(
		-accel "${QEMU_ACCEL}"
		-m "${MEM}"
		-smp "${SMP}"
		-pidfile "${G_QEMU_PIDFILE}"
		-drive "file=${G_OVERLAY_IMAGE},if=virtio,format=qcow2"
		-netdev "user,id=testnet,restrict=on,hostfwd=unix:${G_SSH_SOCKET}-:22"
		-device "virtio-net-pci,netdev=testnet"
		-virtfs "${share_opts}"
	)
	if [ "${serial_mode}" = stdio ]; then
		G_QEMU_ARGS+=( -nographic )
	else
		G_QEMU_ARGS+=(
			-display none
			-monitor none
			-serial "file:${G_SERIAL_LOG}"
		)
	fi
}

qemu_start()
{
	local i

	qemu_assert_not_running
	qemu_prepare_args file
	log "starting QEMU; serial log: ${G_SERIAL_LOG}"
	G_QEMU_STARTED=1
	G_QEMU_PARENT_PID="${BASHPID}"
	qemu-system-x86_64 "${G_QEMU_ARGS[@]}" > "${G_QEMU_LOG}" 2>&1 &
	G_QEMU_PID=$!
	for ((i = 0; i < 50; i++)); do
		[ -r "${G_QEMU_PIDFILE}" ] && return 0
		kill -0 "${G_QEMU_PID}" 2>/dev/null ||
			die "QEMU exited during startup; see ${G_QEMU_LOG}"
		sleep 0.1
	done
	die "QEMU did not create its pidfile: ${G_QEMU_PIDFILE}"
}

qemu_run_foreground()
{
	SERIAL_MODE="${SERIAL_MODE:-stdio}"
	qemu_assert_not_running
	qemu_prepare_args "${SERIAL_MODE}"
	G_QEMU_STARTED=1
	if [ "${SERIAL_MODE}" = stdio ]; then
		log "starting QEMU with the serial console on stdio"
		qemu-system-x86_64 "${G_QEMU_ARGS[@]}" 2> "${G_QEMU_LOG}"
	else
		log "starting QEMU; serial log: ${G_SERIAL_LOG}"
		qemu-system-x86_64 "${G_QEMU_ARGS[@]}" > "${G_QEMU_LOG}" 2>&1
	fi
}

qemu_wait_exit()
{
	local wait_seconds="${1:-60}" i

	for ((i = 0; i < wait_seconds * 5; i++)); do
		qemu_is_running || return 0
		sleep 0.2
	done
	return 1
}

qemu_wait_process()
{
	local status

	[ -n "${G_QEMU_PID:-}" ] || return 0
	[ "${G_QEMU_PARENT_PID:-}" = "${BASHPID}" ] || return 0
	if wait "${G_QEMU_PID}"; then
		status=0
	else
		status=$?
	fi
	G_QEMU_PID=
	G_QEMU_PARENT_PID=
	return "${status}"
}

qemu_stop_process()
{
	local pid

	if pid="$(qemu_pid)"; then
		if kill -0 "${pid}" 2>/dev/null; then
			log "terminating QEMU pid ${pid}"
			kill -TERM "${pid}" 2>/dev/null || true
			if ! qemu_wait_exit 5; then
				kill -KILL "${pid}" 2>/dev/null || true
			fi
		fi
	fi
	qemu_wait_process 2>/dev/null || true
}

qemu_shutdown()
{
	local wait_seconds="${1:-60}" status=0

	qemu_is_started || return 0
	if qemu_is_running && ! qemu_wait_exit "${wait_seconds}"; then
		qemu_stop_process
		status=124
	else
		qemu_wait_process || status=$?
	fi
	qemu_runtime_cleanup
	return "${status}"
}

qemu_runtime_cleanup()
{
	case "${G_SSH_SOCKET}" in
		/tmp/openrc_qemu_*.socket) rm -f -- "${G_SSH_SOCKET}" ;;
	esac
	case "${G_QEMU_PIDFILE}" in
		"${G_RUN_DIR}/"*) rm -f -- "${G_QEMU_PIDFILE}" ;;
	esac
	G_QEMU_STARTED=0
}
