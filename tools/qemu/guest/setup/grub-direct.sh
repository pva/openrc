#!/usr/bin/env bash
# grub-mkconfig fragment which boots the newest kernel without opening a menu.

set -euo pipefail

readonly PROG="${0##*/}"
readonly BOOT_DIR="${OPENRC_QEMU_BOOT_DIR:-/boot}"
readonly CMDLINE_FILE="${OPENRC_QEMU_CMDLINE_FILE:-/etc/cmdline}"
readonly ROOT_LABEL="${OPENRC_QEMU_ROOT_LABEL:-openrc-root}"

die() {
	echo "${PROG}: $*" >&2
	exit 1
}

get_cmdline() {
	[[ -r "$CMDLINE_FILE" ]] || die "kernel command line is not readable: $CMDLINE_FILE"

	local cmdline=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" ]] && continue
		[[ -n "$cmdline" ]] && die "kernel command line file contains multiple nonempty lines: $CMDLINE_FILE"
		cmdline="$line"
	done < "$CMDLINE_FILE"

	[[ -n "$cmdline" ]] || die "kernel command line is empty: $CMDLINE_FILE"
	echo "$cmdline"
}

get_newest_kernel() {
	local newest=""

	for candidate in "${BOOT_DIR}"/vmlinuz-* "${BOOT_DIR}"/kernel-*; do
		[[ -f "$candidate" && "$candidate" != *.old ]] || continue

		if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
			newest="$candidate"
		fi
	done

	[[ -n "$newest" ]] || die "no versioned kernel found in $BOOT_DIR"
	echo "$newest"
}

main() {
	local cmdline
	cmdline=$(get_cmdline)

	local kernel_path
	kernel_path=$(get_newest_kernel)

	local kernel_name="${kernel_path##*/}"
	local kernel_version="${kernel_name#*-}"

	local initramfs_name="initramfs-${kernel_version}.img"
	local initramfs_path="${BOOT_DIR}/${initramfs_name}"

	[[ -f "$initramfs_path" ]] || die "matching initramfs does not exist: $initramfs_path"

	cat <<-EOF
		terminfo -g 160x24 serial vt100-color
		set color_normal=white/black
		set color_highlight=white/black
		set menu_color_normal=white/black
		set menu_color_highlight=white/black
		search --no-floppy --label --set=root ${ROOT_LABEL}
		echo Starting Linux /boot/${kernel_name}
		echo Kernel command line: ${cmdline}
		linux /boot/${kernel_name} ${cmdline}
		initrd /boot/${initramfs_name}
		boot
	EOF
}

main
