#!/usr/bin/env bash

# Host-side archive and generated-file helpers.

tar_extract()
{
	[ "$#" -eq 4 ] ||
		die "usage: tar_extract {require|optional} ARCHIVE MEMBER DESTINATION"

	local mode="$1" archive="$2" path="$3" dest="$4"
	local archive_index member="" entry normalized_path

	case "${mode}" in
		require|optional) ;;
		*) die "tar_extract mode must be require or optional, got: ${mode}" ;;
	esac

	normalized_path="${path#/}"
	normalized_path="${normalized_path#./}"
	[ -n "${normalized_path}" ] || die "empty archive member path"

	archive_index="$(mktemp)" || die "cannot create a temporary archive index"
	if ! tar -tf "${archive}" > "${archive_index}"; then
		rm -f -- "${archive_index}"
		die "cannot read tar archive: ${archive}"
	fi

	while IFS= read -r entry; do
		case "${entry}" in
			"${normalized_path}"|"./${normalized_path}")
				member="${entry}"
				break
				;;
		esac
	done < "${archive_index}"
	rm -f -- "${archive_index}"

	mkdir -p -- "$(dirname -- "${dest}")"
	if [ -z "${member}" ]; then
		case "${mode}" in
			require) die "archive member not found: ${path} in ${archive}" ;;
			optional) : > "${dest}" ;;
		esac
		return 0
	fi

	if ! tar -xOf "${archive}" "${member}" > "${dest}"; then
		die "cannot extract archive member: ${path} from ${archive}"
	fi
}

write_configs()
{
	[ "$#" -eq 1 ] || die "usage: write_configs ROOT"

	local root="$1"
	local current_file="" line="" relative_path=""

	while IFS= read -r line; do
		case "${line}" in
			"FILE: "*|"APPEND: "*)
				relative_path="${line#*: }"
				case "${relative_path}" in
					''|/*|../*|*/../*|*/..)
						die "invalid generated config path: ${relative_path}"
						;;
				esac
				current_file="${root}/${relative_path}"
				mkdir -p -- "$(dirname -- "${current_file}")"
				if [[ "${line}" == "FILE: "* ]]; then
					: > "${current_file}"
				else
					: >> "${current_file}"
				fi
				;;
			*)
				[ -n "${current_file}" ] ||
					die "configuration content appears before a FILE or APPEND marker"
				printf '%s\n' "${line}" >> "${current_file}"
				;;
		esac
	done
}
