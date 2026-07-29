#!/usr/bin/env bash
# Install one OpenRC revision into a new or existing per-run image overlay.
# Usage: image-update-openrc.sh [QEMU_TEST_ROOT] [SOURCE_DIR] [REVISION]

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

usage()
{
	cat <<-EOF
		Usage: ${PROG} [QEMU_TEST_ROOT] [SOURCE_DIR] [REVISION]

		Environment:
		  RUN_ID                    create or update this persistent run
		  OPENRC_REVISION           revision when the third argument is omitted
		  OPENRC_USE                additional per-build USE settings
		  OPENRC_EXPECTED_VERSION   text expected in openrc --version
		  NET                       NAT by default; ISOLATED when dependencies are cached
	EOF
}

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
esac
[ "$#" -le 3 ] || { usage >&2; exit 2; }

need_cmd git
need_cmd install
need_cmd qemu-img
need_cmd qemu-system-x86_64
need_cmd realpath
need_cmd sha256sum
need_cmd socat
need_cmd ssh
need_cmd tee

qemu_root_init "${1:-qemu-tests}"
SOURCE_DIR="$(realpath_m "${2:-${REPO_ROOT}}")"
REVISION="${3:-${OPENRC_REVISION:-HEAD}}"
OPENRC_USE="${OPENRC_USE:-}"
RUN_ID="${RUN_ID:-$(run_id_default)}"
QEMU_EXIT_WAIT="${QEMU_EXIT_WAIT:-60}"
NET="${NET:-NAT}"

[ "$(git -C "${SOURCE_DIR}" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
	die "source directory is not a Git checkout: ${SOURCE_DIR}"
[ -f "${SOURCE_DIR}/meson.build" ] || die "source directory has no meson.build: ${SOURCE_DIR}"
validate_name run-id "${RUN_ID}"

COMMIT="$(git -C "${SOURCE_DIR}" rev-parse --verify "${REVISION}^{commit}")" ||
	die "OpenRC revision does not exist: ${REVISION}"
PROJECT_VERSION="$(
	git -C "${SOURCE_DIR}" show "${COMMIT}:meson.build" |
		sed -n "s/^[[:space:]]*version : '\([^']*\)'.*/\1/p" |
		sed -n '1p'
)"
[ -n "${PROJECT_VERSION}" ] ||
	die "cannot read the OpenRC project version at ${COMMIT}"
OPENRC_EXPECTED_VERSION="${OPENRC_EXPECTED_VERSION:-${PROJECT_VERSION}}"
SHORT_COMMIT="${COMMIT:0:12}"
INSTALL_LABEL="update-${SHORT_COMMIT}"

if [ -d "${G_RUNS_DIR}/${RUN_ID}" ]; then
	qemu_run_load "${G_RUNS_DIR}/${RUN_ID}"
	[ -f "${G_OVERLAY_IMAGE}" ] ||
		die "run overlay does not exist: ${G_OVERLAY_IMAGE}"
	log "updating existing run: ${RUN_ID}"
else
	qemu_run_create "${RUN_ID}"
	qemu_overlay_create
	log "created run: ${RUN_ID}"
fi

cleanup()
{
	local status=$?

	trap - EXIT INT TERM
	set +e
	if qemu_is_started; then
		guest_shutdown "${QEMU_EXIT_WAIT}" >/dev/null 2>&1 || true
	fi
	if [ "${status}" -ne 0 ]; then
		log "OpenRC update failed; run state is preserved in ${G_RUN_DIR}"
		if [ -s "${G_QEMU_LOG}" ]; then
			log "last QEMU messages:"
			tail -100 "${G_QEMU_LOG}" >&2
		fi
		if [ -s "${G_SERIAL_LOG}" ]; then
			log "last serial-console messages:"
			tail -100 "${G_SERIAL_LOG}" >&2
		fi
	fi
	log "RUN_ID=${RUN_ID}"
	printf '%s: interactive command: RUN_ID=%q %q %q\n' \
		"${PROG}" "${RUN_ID}" "${SCRIPT_DIR}/image-run.sh" "${G_QEMU_ROOT}" >&2
	exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGED_REPO="${G_SHARE_DIR}/source/openrc-${SHORT_COMMIT}.git"
GUEST_REPO="/mnt/host/source/${STAGED_REPO##*/}"
if [ -e "${STAGED_REPO}" ]; then
	[ -d "${STAGED_REPO}" ] ||
		die "staged repository path is not a directory: ${STAGED_REPO}"
	git -C "${STAGED_REPO}" rev-parse --is-bare-repository >/dev/null 2>&1 ||
		die "staged repository is invalid: ${STAGED_REPO}"
else
	log "staging OpenRC ${COMMIT} in ${STAGED_REPO}"
	git clone -q --bare --no-local "${SOURCE_DIR}" "${STAGED_REPO}"
fi
git -C "${STAGED_REPO}" cat-file -e "${COMMIT}^{commit}" ||
	die "staged repository does not contain ${COMMIT}: ${STAGED_REPO}"
install -D -m 0755 "${SCRIPT_DIR}/guest/setup/install-openrc.sh" \
	"${G_SHARE_DIR}/tests/setup/install-openrc.sh"

log "run directory: ${G_RUN_DIR}"
log "revision: ${COMMIT}"
log "expected version: ${OPENRC_EXPECTED_VERSION}"
log "additional USE flags: ${OPENRC_USE:-none}"
guest_start
guest_install_openrc "${GUEST_REPO}" "${COMMIT}" \
	"${OPENRC_EXPECTED_VERSION}" "${INSTALL_LABEL}" "${OPENRC_USE}"
guest_reboot

VERIFY_LOG="${G_RESULTS_DIR}/verify-${INSTALL_LABEL}.log"
ssh_exec '
	set -e
	openrc --version
	printf "PID 1 executable: "
	readlink /proc/1/exe
	printf "Installed OpenRC USE: "
	cat /var/db/pkg/sys-apps/openrc-*/USE
' | tee "${VERIFY_LOG}"

guest_shutdown "${QEMU_EXIT_WAIT}" ||
	die "guest did not shut down cleanly; see ${G_QEMU_LOG}"
log "OpenRC ${COMMIT} installed and reboot-tested; verification: ${VERIFY_LOG}"
