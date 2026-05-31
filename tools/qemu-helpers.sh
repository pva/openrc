#!/usr/bin/env bash
#
# Shared helpers for host-side QEMU/libguestfs test scripts.

# shellcheck disable=SC2034,SC2154

qemu_helpers_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/tools-helper.sh
. "${qemu_helpers_dir}/tools-helper.sh"

[ -n "${outdir:-}" ] || die "outdir is not set before sourcing qemu-helpers.sh"

image="${IMAGE:-${image:-${outdir}/gentoo-test.qcow2}}"
if [ -n "${IMAGE:-}" ]; then
	outdir="$(dirname -- "${image}")"
fi

image_name="${image##*/}"
image_stem="${image_name%.*}"
[ -n "${image_stem}" ] || image_stem="${image_name}"

qga_socket="${outdir}/${image_stem}.socket"
host_share="${outdir}/shared-dir"
guest_share="/mnt/host"
qga_wait="${QGA_WAIT:-60}"
qga_timeout="${QGA_TIMEOUT:-30}"
guest_exec_timeout="${GUEST_EXEC_TIMEOUT:-300}"

qga_raw()
{
	local line qga_in qga_out qga_pid request="$1" result

	result=

	coproc QGA { socat - "UNIX-CONNECT:${qga_socket}"; }
	qga_pid="$!"
	qga_out="${QGA[0]}"
	qga_in="${QGA[1]}"

	printf '%s\n' "${request}" >&"${qga_in}" || {
		kill "${qga_pid}" 2>/dev/null || true
		wait "${qga_pid}" 2>/dev/null || true
		return 1
	}

	# QGA replies are newline-delimited JSON objects, one response per line.
	while IFS= read -r -t "${qga_timeout}" line <&"${qga_out}"; do
		if printf '%s\n' "${line}" |
			jq -e 'type == "object" and (has("return") or has("error"))' >/dev/null 2>&1; then
			result="${line}"
			break
		fi
	done

	exec {qga_in}>&-
	exec {qga_out}<&-
	kill "${qga_pid}" 2>/dev/null || true
	wait "${qga_pid}" 2>/dev/null || true

	[ -n "${result}" ] || return 1
	if printf '%s\n' "${result}" | jq -e '.error' >/dev/null; then
		printf '%s\n' "${result}" | jq -c '.error' >&2
		return 1
	fi
	printf '%s\n' "${result}"
}

qga_wait_ready()
{
	local i rc
	log "waiting for qemu guest agent at ${qga_socket}"
	for ((i = 0; i < qga_wait; i++)); do
		if [ -S "${qga_socket}" ]; then
			set +e
			qga_raw '{"execute":"guest-ping"}' >/dev/null 2>&1
			rc=$?
			set -e
			if [ "${rc}" -eq 0 ]; then
				log "qemu guest agent is ready"
				return 0
			fi
		fi
		sleep 1
	done
	die "qemu guest agent is not ready: ${qga_socket}"
}

qga_exec()
{
	local cmd="$1" request response pid status exited exitcode out_data err_data started
	log "guest exec: ${cmd}"
	request="$(jq -nc --arg cmd "${cmd}" \
		'{execute:"guest-exec",arguments:{path:"/bin/sh",arg:["-lc",$cmd],"capture-output":true}}')"
	response="$(qga_raw "${request}")" || return 1
	pid="$(printf '%s\n' "${response}" | jq -r '.return.pid')"

	started="${SECONDS}"
	while :; do
		request="$(jq -nc --argjson pid "${pid}" \
			'{execute:"guest-exec-status",arguments:{pid:$pid}}')"
		status="$(qga_raw "${request}")" || return 1
		exited="$(printf '%s\n' "${status}" | jq -r '.return.exited')"
		[ "${exited}" = true ] && break
		if [ $((SECONDS - started)) -ge "${guest_exec_timeout}" ]; then
			die "guest command timed out after ${guest_exec_timeout}s: ${cmd}"
		fi
		sleep 0.2
	done

	out_data="$(printf '%s\n' "${status}" | jq -r '.return["out-data"] // empty')"
	err_data="$(printf '%s\n' "${status}" | jq -r '.return["err-data"] // empty')"
	[ -z "${out_data}" ] || printf '%s' "${out_data}" | base64 -d
	[ -z "${err_data}" ] || printf '%s' "${err_data}" | base64 -d >&2
	exitcode="$(printf '%s\n' "${status}" | jq -r '.return.exitcode // 1')"
	return "${exitcode}"
}
