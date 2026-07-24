#!/usr/bin/env bash

# Shared helpers for guest-side tests.

RC_LIBEXECDIR="${RC_LIBEXECDIR:-}"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

setup_openrc_path()
{
	local rc_libexecdir

	for rc_libexecdir in /usr/libexec/rc /lib/rc; do
		if [ -x "${rc_libexecdir}/bin/mountinfo" ]; then
			RC_LIBEXECDIR="${rc_libexecdir}"
			PATH="${rc_libexecdir}/bin:${PATH}"
			export RC_LIBEXECDIR PATH
			return
		fi
	done
	fail "cannot find installed OpenRC helpers"
}
