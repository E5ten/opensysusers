#!/bin/sh
# Copyright (c) 2018 Chris Cromer
# Copyright (c) 2012 Gentoo Foundation
# Released under the 2-clause BSD license.
#
# Common functions and variables needed by opensysusers

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

warninvalid() {
	[ -z "$1" ] && set -- 'ignoring invalid entry'
	printf "sysusers: %s on line %d of \`%s'\n" "$1" "${line}" "${file}"
	: "$((error += 1))"
} >&2

in_array() {
	needle="$1"
	shift
	for element in "$@"; do
		[ "${element}" = "${needle}" ] && return 0
	done
	return 1
}

add_group() {
	# add_group <name> <id>
	if ! getent group "$1" >/dev/null; then
		if [ "$2" = '-' ]; then
			groupadd -r "$1"
		elif ! grep -qiw "$2" /etc/group; then
			groupadd -g "$2" "$1"
		fi
	fi
}

add_user() {
	# add_user <name> <id> <gecos> <home>
	if getent passwd "$1" >/dev/null; then
		if [ "$2" = '-' ]; then
			useradd -rc "$3" -g "$1" -d "$4" -s '/sbin/nologin' "$1"
		else
			useradd -rc "$3" -u "$2" -g "$1" -d "$4" -s '/sbin/nologin' "$1"
		fi
		passwd -l "$1" >/dev/null 2>&1
	fi
}

update_login_defs() {
	# update_login_defs <name> <id>
	[ "$1" != '-' ] && warninvalid && return
	i=1
	_IFS="${IFS}" IFS='-'
	for part in $2; do
		case "${i}" in
			1) min="${part}" ;;
			2) max="${part}" ;;
			3) warninvalid && continue ;;
		esac
		: "$((i += 1))"
	done
	IFS="${_IFS}"
	[ "${min}" -ge "${max}" ] && warninvalid "invalid range" && return

	while read -r NAME VALUE; do
		[ "${NAME}" = 'SYS_UID_MAX' ] && suid_max=${VALUE}
		[ "${NAME}" = 'SYS_GID_MAX' ] && sgid_max=${VALUE}
	done < /etc/login.defs
	[ "${min}" -lt "${suid_max}" ] && warninvalid "invalid range" && return
	[ "${min}" -lt "${sgid_max}" ] && warninvalid "invalid range" && return

	sed -e "s/^\([GU]ID_MIN\)\([[:space:]]\+\)\(.*\)/\1\2${min}/" \
		-e "s/^\([GU]ID_MAX\)\([[:space:]]\+\)\(.*\)/\1\2${max}/" \
		-i /etc/login.defs
}

parse_file() {
	if [ -f "$1" ]; then
		while read -r cline; do
			[ "${cline#\#}" = "${cline}" ] || continue
			parse_string "${cline}"
		done < "$1"
	fi
}

parse_string() {
	line=0
	[ "${1#\#}" = "$1" ] || continue
	set -f
	set -- $1
	set +f
	i=0
	for part in "$@"; do
		case "${i}" in
			0) type="${part}" ;;
			1) name="${part}" ;;
			2) id="${part}" ;;
			3) gecos="${part}" ;;
			4) home="${part}" ;;
		esac
		: "$((i += 1))"
	done
	: "$((line += 1))"

	case "${type}" in
		u)
			case "${id}" in 65535|4294967295) warninvalid; continue ;; esac
			[ "${home:--}" = - ] && home='/'
			add_group "${name}" "${id}"
			[ "${id}" = '-' ] && id="$(getent group "${name}")" id="${id#*:*:}" id="${id%%:*}"
			add_user "${name}" "${id}" "${gecos}" "${home}"
		;;
		g)
			case "${id}" in 65535|4294967295) warninvalid; continue ;; esac
			[ "${home:--}" = '-' ] && home='/'
			add_group "${name}" "${id}"
		;;
		m)
			add_group "${name}" '-'
			if ! getent passwd "${name}" >/dev/null; then
				useradd -r -g "${id}" -s '/sbin/nologin' "${name}"
				passwd -l "${name}" >/dev/null 2>&1
			else
				usermod -a -G "${id}" "${name}"
			fi
		;;
		r)
			update_login_defs "${name}" "${id}"
		;;
		*) warninvalid; continue;;
	esac
}

# this part is based on OpenRC's opentmpfiles
# Build a list of sorted unique basenames
# directories declared later in the sysusers_d array will override earlier
# directories, on a per file basename basis.
# `/etc/sysusers.d/foo.conf' supersedes `/usr/lib/sysusers.d/foo.conf'.
# `/run/sysusers.d/foo.conf' will always be read after `/etc/sysusers.d/bar.conf'

get_conf_files() {
	for dir in ${sysusers_dirs}; do
		[ -d "${dir}" ] && for file in "${dir}"/*.conf; do
			[ -n "${replace}" ] &&
				[ "${dir}" = "$(dirname ${replace})" ] &&
				[ "${file##*/}" = "${replace##*/}" ] &&
				continue
			[ -f "${file}" ] && sysusers_basenames="${sysusers_basenames}
${file##*/}"
		done
	done
	FILES="$(printf '%s\n' "${sysusers_basenames}" | sort -u)"
}

get_conf_paths() {
	for b in ${FILES}; do
		real_f=''
		for d in ${sysusers_dirs}; do
			[ -n "${replace}" ] &&
				[ "${d}" = "$(dirname ${replace})" ] &&
				[ "${b}" = "${replace##*/}" ] && continue
			[ -f "${d}/${b}" ] && real_f="${d}/${b}"
		done
		[ -f "${real_f}" ] && sysusers_d="${sysusers_d}:${real_f}"
	done
}

error=0
FILES=''
sysusers_basenames=''
sysusers_d=''
replace=''

sysusers_dirs="${root}/usr/lib/sysusers.d:${root}/run/sysusers.d:${root}/etc/sysusers.d"
