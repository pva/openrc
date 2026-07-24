#!/bin/sh
# unit test for the deptree cache parser (deptree_load_file)

if [ -z "${BUILD_ROOT}" ]; then
	printf "%s\n" "BUILD_ROOT must be defined" >&2
	exit 1
fi
PATH="${BUILD_ROOT}"/src/rc-depend:${PATH}

# rc-depend touches the runlevel otherwise; pin it so the test needs no svcdir.
RC_RUNLEVEL=default
export RC_RUNLEVEL

TMPDIR="${BUILD_ROOT}"/tmp-"$(basename "$0")"
retval=0

write_deptree()
{
	printf "%s\n" \
		"depinfo_0_service='app'" \
		"depinfo_0_ineed_0='db'" \
		"depinfo_0_ineed_1='fs'" \
		"depinfo_0_iwant_0='logger'" \
		"depinfo_1_service='db'" \
		"depinfo_1_ineed_0='net'" \
		"depinfo_2_service='fs'" \
		"depinfo_3_service='logger'" \
		"depinfo_4_service='net'"
}

check_output()
{
	local desc="$1" file="$2" type="$3" service="$4" expected="$5"
	local actual= code=

	actual="$(rc-depend -F "${file}" -t "${type}" "${service}" 2>&1)"
	code=$?
	if [ "${code}" -ne 0 ]; then
		printf "FAIL: %s: rc-depend exited with status %s\n" \
			"${desc}" "${code}" >&2
		printf "output: %s\n" "${actual}" >&2
		retval=1
	elif [ "${actual}" != "${expected}" ]; then
		printf "FAIL: %s\n" "${desc}" >&2
		printf "expected: %s\n" "${expected}" >&2
		printf "actual:   %s\n" "${actual}" >&2
		retval=1
	elif [ -n "${VERBOSE}" ]; then
		printf "ok: %s\n" "${desc}"
	fi
}

rm -rf "${TMPDIR}"
mkdir "${TMPDIR}"

write_deptree > "${TMPDIR}"/good

check_output "multiple and transitive dependencies" \
	"${TMPDIR}"/good ineed app "net db fs app"
check_output "dependency types remain separate" \
	"${TMPDIR}"/good iwant app "logger app"
check_output "dependencies belong to the current service" \
	"${TMPDIR}"/good ineed db "net db"
check_output "service without dependencies" \
	"${TMPDIR}"/good ineed fs "fs"

# A dependency before the first service has no owner. It must be ignored
# without preventing the valid part of the file from being loaded.
printf "%s\n" "depinfo_99_ineed_0='orphan'" > "${TMPDIR}"/orphan
write_deptree >> "${TMPDIR}"/orphan
check_output "dependency before the first service is ignored" \
	"${TMPDIR}"/orphan ineed app "net db fs app"

rm -rf "${TMPDIR}"
exit ${retval}
