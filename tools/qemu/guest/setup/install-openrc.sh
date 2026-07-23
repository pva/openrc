#!/usr/bin/env bash
# Install an OpenRC revision from a repository mounted under /mnt/host.
# Usage: install-openrc.sh REPOSITORY REVISION EXPECTED_VERSION [LABEL]

set -euo pipefail

REPOSITORY="${1:?missing repository path}"
REVISION="${2:?missing revision}"
EXPECTED_VERSION="${3:?missing expected version}"
LABEL="${4:-openrc}"
case "${LABEL}" in
	*[!A-Za-z0-9._-]*) echo "invalid install label: ${LABEL}" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "install-openrc.sh must run as root" >&2; exit 1; }
[ -e "${REPOSITORY}" ] || { echo "repository not found: ${REPOSITORY}" >&2; exit 1; }
EBUILD=
for CANDIDATE in \
	/usr/portage/sys-apps/openrc/openrc-9999.ebuild \
	/var/db/repos/gentoo/sys-apps/openrc/openrc-9999.ebuild; do
	if [ -f "${CANDIDATE}" ]; then
		EBUILD="${CANDIDATE}"
		break
	fi
done
[ -n "${EBUILD}" ] || { echo "sys-apps/openrc-9999 ebuild is missing" >&2; exit 1; }

TEMP_DIR="$(mktemp -d "/var/tmp/openrc-qemu-${LABEL}.XXXXXX")"
WORK_DIR="${TEMP_DIR}/source"
GIT_STORE="${TEMP_DIR}/git3-src"
GIT_MIRROR="${GIT_STORE}/OpenRC_openrc.git"
EMERGE_LOG="/var/log/openrc-qemu-emerge-${LABEL}.log"
EBUILD_BACKUP="${TEMP_DIR}/openrc-9999.ebuild"
cleanup()
{
	if [ -f "${EBUILD_BACKUP}" ]; then
		cp -a -- "${EBUILD_BACKUP}" "${EBUILD}"
		ebuild "${EBUILD}" digest
	fi
	rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

mkdir -- "${WORK_DIR}" "${GIT_STORE}"
cp -a --no-preserve=ownership -- "${REPOSITORY}/." "${WORK_DIR}/"
git -C "${WORK_DIR}" rev-parse --verify "${REVISION}^{commit}" >/dev/null
git clone -q --mirror --no-local "${WORK_DIR}" "${GIT_MIRROR}"

# The current live ebuild may pass Meson options added after the revision under
# test. Keep the installed source pristine and adapt only the disposable
# guest's ebuild while building such an older revision.
if ! git -C "${WORK_DIR}" show "${REVISION}:meson_options.txt" |
	grep -q "^option('pam_libdir'"; then
	echo "building a revision without the pam_libdir Meson option"
	cp -a -- "${EBUILD}" "${EBUILD_BACKUP}"
	sed -i '/-Dpam_libdir=/d' "${EBUILD}"
	ebuild "${EBUILD}" digest
fi

# git-r3 derives this cache name from the ebuild's canonical GitHub URI.
# Seed it locally and make it writable by Portage so unpack never needs the
# network, which is intentionally unavailable in the test VM.
chown -R portage:portage "${GIT_STORE}"
chmod 755 "${TEMP_DIR}"

echo "installing OpenRC ${REVISION} from ${REPOSITORY}"
if ! EGIT3_STORE_DIR="${GIT_STORE}" \
	EVCS_OFFLINE=1 \
	EGIT_OVERRIDE_COMMIT_OPENRC_OPENRC="${REVISION}" \
	ACCEPT_KEYWORDS='**' \
	emerge --ask=n --oneshot --verbose --buildpkg=y \
		--usepkg-exclude sys-apps/openrc --autounmask=n \
		=sys-apps/openrc-9999 > "${EMERGE_LOG}" 2>&1; then
	tail -200 "${EMERGE_LOG}" >&2
	exit 1
fi

sync
openrc --version
openrc --version | grep -F -- "${EXPECTED_VERSION}" >/dev/null || {
	echo "installed OpenRC version does not contain: ${EXPECTED_VERSION}" >&2
	exit 1
}
