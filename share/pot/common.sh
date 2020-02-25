#!/bin/sh

: "${EXIT:=exit}"
: "${ECHO:=echo}"
: "${SED:=sed}"

_POT_RW_ATTRIBUTES="start-at-boot persistent no-rc-script procfs fdescfs prunable localhost-tunnel"
_POT_RO_ATTRIBUTES="to-be-pruned"
_POT_NETWORK_TYPES="inherit alias public-bridge private-bridge"

__POT_MSG_ERR=0
__POT_MSG_INFO=1
__POT_MSG_DBG=2
# $1 severity
_msg()
{
	local _sev
	_sev=$1
	shift
	if [ "$_sev" -gt "${_POT_VERBOSITY:-0}" ]; then
		return
	fi
	case $_sev in
		$__POT_MSG_ERR)
			echo "###> " $*
			;;
		$__POT_MSG_INFO)
			echo "===> " $*
			;;
		$__POT_MSG_DBG)
			echo "=====> " $*
			;;
		*)
			;;
	esac
}

_error()
{
	_msg $__POT_MSG_ERR $*
}

_info()
{
	_msg $__POT_MSG_INFO $*
}

_debug()
{
	_msg $__POT_MSG_DBG $*
}

# $1 quiet / no _error message is emitted
_qerror()
{
	if [ "$1" != "quiet" ]; then
		_error $*
	fi
}

# tested
_is_verbose()
{
	if [ "$_POT_VERBOSITY" -gt $__POT_MSG_INFO ]; then
		return 0 # true
	else
		return 1 # false
	fi
}

# $1 quiet / no _error messages are emitted (sometimes useful)
_is_uid0()
{
	if [ "$(id -u)" = "0" ]; then
		return 0 # true
	else
		_qerror "$1" "This operation needs 'root' privilegies"
		return 1 # false
	fi
}

# tested
# check if the argument is an absolute pathname
_is_absolute_path()
{
	if [ "$1" = "${1#/}" ]; then
		return 1 # false
	else
		return 0 # true
	fi
}

# validate some values of the configuration files
# $1 quiet / no _error messages are emitted
_conf_check()
{
	if [ -z "${POT_ZFS_ROOT}" ]; then
		_qerror $1 "POT_ZFS_ROOT is mandatory"
		return 1 # false
	fi
	if [ -z "${POT_FS_ROOT}" ]; then
		_qerror $1 "POT_FS_ROOT is mandatory"
		return 1 # false
	fi
	return 0 # true
}

# it checkes that the pot environment is initialized
# $1 quiet / no _error messages are emitted
_is_init()
{
	if ! _conf_check $1 ; then
		_qerror $1 "Configuration not valid, please verify it"
		return 1 # false
	fi
	if ! _zfs_exist "${POT_ZFS_ROOT}" "${POT_FS_ROOT}" ; then
		_qerror $1 "Your system is not initialized, please run pot init"
		return 1 # false
	fi
	if ! _zfs_dataset_valid "${POT_ZFS_ROOT}/bases" || \
	   ! _zfs_dataset_valid "${POT_ZFS_ROOT}/jails" || \
	   ! _zfs_dataset_valid "${POT_ZFS_ROOT}/fscomp" ; then
		_qerror $1 "Your system is not propery initialized, please run pot init to fix it"
	fi
}

# checks if the flavour dir is set up and exist
_is_flavourdir()
{
	if [ -z "${_POT_FLAVOUR_DIR}" ] || [ ! -d "${_POT_FLAVOUR_DIR}" ]; then
		return 1 # false
	fi
	return 0 # true
}

# check if the dataset is a dataset name
# $1 the dataset NAME
# tested
_zfs_dataset_valid()
{
	[ -z "$1" ] && return 1 # return false
	if [ "$1" = "$( zfs list -o name -H $1 2> /dev/null)" ]; then
		return 0 # true
	else
		return 1 # false
	fi
}

# check if the dataset $1 with the mountpoint $2 exists
# $1 the dataset NAME
# $2 the mountpoint
# tested
_zfs_exist()
{
	local _mnt_
	[ -z "$2" ] && return 1 # false
	if ! _zfs_dataset_valid $1 ; then
		return 1 # false
	fi
	_mnt_="$(zfs list -H -o mountpoint $1 2> /dev/null )"
	if [ "$_mnt_" != "$2" ]; then
		return 1 # false
	fi
	return 0 # true
}

# given a dataset, look for the corresponding mountpoint
# $1 the dataset
_get_zfs_mountpoint()
{
	local _mnt_p _dset
	_dset=$1
	_mnt_p="$( zfs list -o mountpoint -H $_dset 2> /dev/null )"
	echo $_mnt_p
}

# given a mountpoint, look for the corresponding dataset
# $1 the mountpoint
_get_zfs_dataset()
{
	# shellcheck disable=SC2039
	local _mnt_p _dset
	_mnt_p=$1
	_dset=$(zfs list -o name,mountpoint -H 2>/dev/null | awk -v "mntp=${_mnt_p}" '{ if ($2 == mntp) print $1 }')
	echo "$_dset"
}

# take a zfs recursive snapshot of a pot
# $1 pot name
_pot_zfs_snap()
{
	# shellcheck disable=SC2039
	local _pname _snaptag _dset
	_pname=$1
	_snaptag="$(date +%s)"
	_debug "Take snapshot of $_pname"
	zfs snapshot -r "${POT_ZFS_ROOT}/jails/${_pname}@${_snaptag}"
}

# recursively remove the oldest snapshot of a pot
# $1 pot name
_remove_oldest_pot_snap()
{
	# shellcheck disable=SC2039
	local _pname _snap _pdset
	_pname=$1
	_pdset="${POT_ZFS_ROOT}/jails/${_pname}"
	_snap="$( _zfs_oldest_snap "$_pdset" )"
	if [ -n "$_snap" ]; then
		zfs destroy -r "$_pdset@${_snap}"
	fi
}

# take a zfs snapshot of all rw dataset found in the fscomp.conf of a pot
# $1 pot name
# DEPRECATED
_pot_zfs_snap_full()
{
	# shellcheck disable=SC2039
	local _pname _node _opt _snaptag _dset
	_pname=$1
	_snaptag="$(date +%s)"
	_debug "Take snapshot of the full $_pname"
	while read -r line ; do
		_dset=$( echo "$line" | awk '{print $1}' )
		_opt=$( echo "$line" | awk '{print $3}' )
		if [ "$_opt" = "ro" ]; then
			continue
		fi
		if _is_absolute_path "$_dset" ; then
			_debug "Skip $_dset, it's not a dataset"
		else
			_debug "snapshot of $_dset"
			zfs snapshot "${_dset}@${_snaptag}"
		fi
	done < "${POT_FS_ROOT}/jails/$_pname/conf/fscomp.conf"
}

# recursively remove the oldest snapshot of a pot
# $1 pot name
_remove_oldest_fscomp_snap()
{
	# shellcheck disable=SC2039
	local _fscomp _snap _fdset
	_fscomp=$1
	_fdset="${POT_ZFS_ROOT}/fscomp/${_fscomp}"
	_snap="$( _zfs_oldest_snap "$_fdset" )"
	if [ -n "$_snap" ]; then
		zfs destroy -r "$_fdset@${_snap}"
	fi
}
# take a zfs snapshot of a fscomp
# $1 fscomp name
# $2 optional name
_fscomp_zfs_snap()
{
	# shellcheck disable=SC2039
	local _fscomp _snaptag _dset
	_fscomp=$1
	if [ -z "$2" ]; then
		_snaptag="$(date +%s)"
	else
		_snaptag="$2"
	fi
	_debug "Take snapshot of $_fscomp"
	zfs snapshot "${POT_ZFS_ROOT}/fscomp/${_fscomp}@${_snaptag}"
}

# get the last available snapshot of a given dataset
# $1 the dataset name
_zfs_last_snap()
{
	# shellcheck disable=SC2039
	local _dset _output
	_dset="$1"
	if [ -z "$_dset" ]; then
		return 1 # false
	fi
	_output="$(zfs list -d 1 -H -t snapshot "$_dset" | sort -r | cut -d'@' -f2 | cut -f1 | head -n1)"
	if [ -z "$_output" ]; then
		return 1 # false
	fi
	echo "${_output}"
	return 0 # true
}

# get the oldest available snapshot of a given dataset
# $1 the dataset name
_zfs_oldest_snap()
{
	# shellcheck disable=SC2039
	local _dset _output
	_dset="$1"
	if [ -z "$_dset" ]; then
		return 1 # false
	fi
	_output="$(zfs list -d 1 -H -t snapshot "$_dset" | sort -r | cut -d'@' -f2 | cut -f1 | tail -n1)"
	if [ -z "$_output" ]; then
		return 1 # false
	fi
	echo "${_output}"
	return 0 # true
}

# get the amount of available snapshots of a given dataset
# $1 the dataset name
_zfs_count_snap()
{
	# shellcheck disable=SC2039
	local _dset _output
	_dset="$1"
	if [ -z "$_dset" ]; then
		return 1 # false
	fi
	_output="$(zfs list -d 1 -H -t snapshot "$_dset" | grep -c . )"
	if [ -z "$_output" ]; then
		 echo 0
	fi
	echo "${_output}"
}

# check if the snapshot of the pot does exist
# $1 pot name
# $2 snapshot name
_is_zfs_pot_snap()
{
	# shellcheck disable=SC2039
	local _pname _snap _dset
	_pname=$1
	_snap=$2
	if zfs list -t snap "${POT_ZFS_ROOT}/jails/${_pname}@${_snap}" 2>/dev/null ; then
		return 0 # true
	else
		return 1 # false
	fi
}

# tested
_pot_bridge()
{
	local _bridges
	_bridges=$( ifconfig | grep ^bridge | cut -f1 -d':' )
	if [ -z "$_bridges" ]; then
		return
	fi
	for _b in $_bridges ; do
		_ip=$( ifconfig $_b inet | awk '/inet/ { print $2 }' )
		if [ "$_ip" = $POT_GATEWAY ]; then
			echo $_b
			return
		fi
	done
}

# $1 bridge name
_private_bridge()
{
	# shellcheck disable=SC2039
	local _bridges _bridge _bridge_ip
	_bridge="$1"
	_bridges=$( ifconfig | grep ^bridge | cut -f1 -d':' )
	if [ -z "$_bridges" ]; then
		return
	fi
	_bridge_ip="$(_get_bridge_var "$_bridge" gateway)"
	for _b in $_bridges ; do
		_ip=$( ifconfig "$_b" inet | awk '/inet/ { print $2 }' )
		if [ "$_ip" = "$_bridge_ip" ]; then
			echo "$_b"
			return
		fi
	done
}

# $1 bridge name
# $2 var name
_get_bridge_var()
{
	# shellcheck disable=SC2039
	local _Bname _cfile _var _value
	_Bname="$1"
	_cfile="${POT_FS_ROOT}/bridges/$_Bname"
	_var="$2"
	_value="$( grep "^$_var=" "$_cfile" | tr -d ' \t"' | cut -f2 -d'=' )"
	echo "$_value"
}

# $1 pot name
# $2 var name
_get_conf_var()
{
	# shellcheck disable=SC2039
	local _pname _cdir _var _value
	_pname="$1"
	_cdir="${POT_FS_ROOT}/jails/$_pname/conf"
	_var="$2"
	_value="$( grep "^$_var=" "$_cdir/pot.conf" | tr -d ' \t"' | cut -f2 -d'=' )"
	echo "$_value"
}

_get_pot_export_ports()
{
	# shellcheck disable=SC2039
	local _pname _cdir _var _value
	_pname="$1"
	_cdir="${POT_FS_ROOT}/jails/$_pname/conf"
	_value="$(awk '/pot.export.ports/ { n=split($0,array,"="); if (n==2) { print array[2]; } }' $_cdir/pot.conf )"
	echo "$_value"
}

# $1 pot name
_get_pot_base()
{
	_get_conf_var "$1" pot.base
}

# $1 pot name
_get_pot_lvl()
{
	_get_conf_var "$1" pot.level
}

# $1 pot name
_get_pot_type()
{
	# shellcheck disable=SC2039
	local _type
	_type="$( _get_conf_var "$1" pot.type )"
	if [ -z "$_type" ]; then
		_type="multi"
	fi
	echo "$_type"
}

# $1 pot name
_get_pot_network_type()
{
	_get_conf_var "$1" network_type
}

# $1 pot name
_get_pot_rdr_anchor_name()
{
	# shellcheck disable=SC2039
	local _pname
	_pname=$1
	if [ "${#_pname}" -gt "55" ]; then
		echo "$_pname" | awk '{ truncated = substr($1, length($1)-54); printf("%s", truncated);}' | sed 's/^__*//'
	else
		echo "$_pname"
	fi
}

# $1 pot name
_is_ip_inherit()
{
	local _pname _val
	_pname="$1"
	if [ "$(_get_pot_network_type $_pname )" = "inherit" ]; then
		return 0 # true
	else
		return 1 # false
	fi
}

# $1 pot name
_is_pot_vnet()
{
	local _pname _val
	_pname="$1"
	_val="$( _get_conf_var $_pname vnet )"
	if [ "$_val" = "true" ]; then
		return 0 # true
	else
		return 1 # false
	fi
}

# $1 pot name
_is_pot_prunable()
{
	# shellcheck disable=SC2039
	local _pname
	_pname="$1"
	if [ "$( _get_conf_var "$_pname" "pot.attr.prunable" )" = "YES" ]; then
		return 0 # true
	else
		return 1
	fi
}

# $1 bridge name (optional)
_is_vnet_up()
{
	# shellcheck disable=SC2039
	local _bridge
	if [ -z "$1" ]; then
		_bridge=$(_pot_bridge)
	else
		_bridge="$( _private_bridge "$1" )"
	fi
	if [ -z "$_bridge" ]; then
		return 1 # false
	elif [ ! -c /dev/pf ]; then
		return 1 # false
	elif ! pfctl -s Anchors | grep -q '^[ \t]*pot-nat$' ; then
		return 1 # false
	elif ! pfctl -s Anchors | grep -q '^[ \t]*pot-rdr$' ; then
		return 1 # false
	elif [ -z "$(pfctl -s nat -a pot-nat)" ]; then
		return 1 # false
	else
		return 0 # true
	fi
}

# $1 bridge name
# $2 quiet / no _error messages are emitted (sometimes useful)
_is_bridge()
{
	# shellcheck disable=SC2039
	local _bname _bconf
	_bname="$1"
	_bconf="${POT_FS_ROOT}/bridges/$_bname"
	if [ ! -e "$_bconf" ]; then
		_qerror "$2" "bridge $_bridge not found"
		return 1 # false
	fi
	return 0 # true
}

# $1 fscomp name
# $2 quiet / no _error messages are emitted (sometimes useful)
# tested
_is_fscomp()
{
	local _fscomp _fdir _fdset
	_fscomp="$1"
	_fdir="${POT_FS_ROOT}/fscomp/$_fscomp"
	_fdset="${POT_ZFS_ROOT}/fscomp/$_fscomp"
	if [ ! -d "$_fdir" ]; then
		_qerror "$2" "fscomp $_fscomp not found"
		return 1
	fi
	if ! _zfs_dataset_valid "$_fdset" ; then
		_qerror "$2" "dataset $_fdset for fscomp $_fscomp not found"
		return 2
	fi
	return 0
}

# $1 base name
# $2 quiet / no _error messages are emitted (sometimes useful)
# tested
_is_base()
{
	local _base _bdir _bdset
	_base="$1"
	_bdir="${POT_FS_ROOT}/bases/$_base"
	_bdset="${POT_ZFS_ROOT}/bases/$_base"
	if [ ! -d "$_bdir" ]; then
		if [ "$2" != "quiet" ]; then
			_error "Base $_base not found"
		fi
		return 1 # false
	fi
	if ! _zfs_dataset_valid $_bdset ; then
		if [ "$2" != "quiet" ]; then
			_error "zfs dataset $_bdset not found"
		fi
		return 2 #false
	fi
	return 0 # true
}

# $1 pot name
# $2 quiet / no _error messages are emitted (sometimes useful)
# tested
_is_pot()
{
	local _pname _pdir
	_pname="$1"
	_pdir="${POT_FS_ROOT}/jails/$_pname"
	if [ ! -d "$_pdir" ]; then
		_qerror "$2" "Pot $_pname not found"
		return 1 # false
	fi
	if ! _zfs_dataset_valid "${POT_ZFS_ROOT}/jails/$_pname" ; then
		_qerror "$2" "zfs dataset $_pname not found"
		return 2 # false
	fi

	if [ ! -d "$_pdir/m" ] || [ ! -r "$_pdir/conf/pot.conf" ] ; then
		_qerror "$2" "Some component of the pot $_pname is missing"
		return 3 # false
	fi
	if [ "$( _get_pot_type $_pname )" = "multi" ] && [ ! -r "$_pdir/conf/fscomp.conf" ]; then
		_qerror "$2" "Some component of the pot $_pname is missing"
		return 4 # false
	fi
	return 0 # true
}

# $1 pot name
# tested
_is_pot_running()
{
	if [ -z "$1" ]; then
		return 1 ## false
	fi
	jls -j "$1" >/dev/null 2>/dev/null
	return $?
}

# $1 flavour name
_is_flavour()
{
	if [ -r "${_POT_FLAVOUR_DIR}/$1" ] || [ -x "${_POT_FLAVOUR_DIR}/$1.sh" ]; then
		return 0 # true
	fi
	return 1 # false
}


# $1 the number to test
_is_port_number()
{
	# shellcheck disable=SC2039
	local _port
	_port=$1
	if [ -z "$_port" ]; then
		return 1
	fi
	# check if it's a number
	if [ -n "$( echo "$_port" | sed 's/[0-9][0-9]*//' )" ]; then
		return 1
	fi
	# check if it's a 16 bit number
	if [ "$_port" -le 0 ] || [ "$_port" -gt 65535 ]; then
		return 1 # false
	fi
	return 0
}

# $1: the -e option argument
_is_export_port_valid()
{
	# shellcheck disable=SC2039
	local _pot_port _host_port
	_pot_port="$( echo "${1}" | cut -d':' -f 1)"
	if [ "$1" = "${_pot_port}" ]; then
		if ! _is_port_number "$OPTARG" ; then
			return 1 # false
		fi
	else
		_host_port="$( echo "${1}" | cut -d':' -f 2)"
		if ! _is_port_number "$_pot_port" ; then
			return 1 # false
		fi
		if ! _is_port_number "$_host_port" ; then
			return 1 # false
		fi
	fi
}

# $1 the element to search
# $2.. the list
# tested
_is_in_list()
{
	local _e
	if [ $# -lt 2 ]; then
		return 1 # false
	fi
	_e="$1"
	shift
	for e in $@ ; do
		if [ "$_e" = "$e" ]; then
			return 0 # true
		fi
	done
	return 1 # false
}

# $1 the number to test
# tested ( common8 )
_is_natural_number()
{
	case "$1" in
		''|*[!0-9]*)
			return 1 # false
			;;
		*)
			return 0 # true
			;;
	esac
}

# $1 mountpoint
# tested
_is_mounted()
{
	local _mnt_p _mounted
	_mnt_p=$1
	if [ -z "$_mnt_p" ]; then
		return 1 # false
	fi
	_mounted=$( mount | grep -F $_mnt_p | awk '{print $3}')
	for m in $_mounted ; do
		if [ "$m" = "$_mnt_p" ]; then
			return 0 # true
		fi
	done
	return 1 # false
}

# $1 mountpoint
# tested
_umount()
{
	# shellcheck disable=SC2039
	local _mnt_p
	_mnt_p=$1
	if _is_mounted "$_mnt_p" ; then
		_debug "unmount $_mnt_p"
		umount -f $_mnt_p
	else
		_debug "$_mnt_p is already unmounted"
	fi
}

# $1 pot
# $2 cmd
_set_command()
{
	# shellcheck disable=SC2039
	local _pname _cmd _cdir _cmd1 _cmd2
	_pname="$1"
	_cmd="$2"
	_cdir=$POT_FS_ROOT/jails/$_pname/conf
	sed -i '' -e "/^pot.cmd=.*/d" "$_cdir/pot.conf"
	_cmd1="$( echo "$_cmd" | sed 's/^"//' )"
	if [ "$_cmd" = "$_cmd1" ]; then
		echo "pot.cmd=$_cmd" >> "$_cdir"/pot.conf
	else
		_cmd2="$( echo "$_cmd1" | sed 's/"$//' )"
		echo "pot.cmd=$_cmd2" >> "$_cdir/pot.conf"
	fi
}

# $1 the cmd
# all other parameter will be ignored
# tested
_is_cmd_flavorable()
{
	# shellcheck disable=SC2039
	local _cmd
	_cmd=$1
	case $_cmd in
		add-dep|set-attribute|\
		copy-in|mount-in|\
		set-rss|export-ports|\
		set-cmd|set-env)
			return 0
			;;
	esac
	return 1 # false
}

# tested
_is_rctl_available()
{
	# shellcheck disable=SC2039
	local _racct
	_racct="$(sysctl -qn kern.racct.enable)"
	if [ "$_racct" = "1" ]; then
		return 0 # true
	fi
	return 1 # false
}

_is_vnet_available()
{
	# shellcheck disable=SC2039
	local _vimage
	_vimage="$(sysctl kern.conftxt | grep -c VIMAGE)"
	if [ "$_vimage" = "0" ]; then
		return 1 # false
	else
		return 0 # true
	fi
}

_is_potnet_available()
{
	if which potnet 2> /dev/null > /dev/null ; then
		return 0 # true
	else
		return 1 # false
	fi
}

# tested (common7)
_map_archs()
{
	if [ -z "$1" ]; then
		return
	fi
	case "$1" in
		amd64)
			echo amd64-amd64
			;;
		i386)
			echo i386-i386
			;;
		*)
			# TODO Add more arhitectures
			;;
	esac
}

# tested (common7)
_get_valid_releases()
{
	local _arch _file_prefix
	_arch="$( sysctl -n hw.machine_arch )"
	_file_prefix="$(_map_archs "$_arch" )"
	if [ -z "$_file_prefix" ]; then
		echo
	fi
	releases="$( find /usr/local/share/freebsd/MANIFESTS -type f -name "${_file_prefix}-*" | sed s%/usr/local/share/freebsd/MANIFESTS/"${_file_prefix}"-%% | sort -V | sed 's/-RELEASE//' | tr '\n' ' ' )"
	echo "$releases"
}

# tested (common7)
_is_valid_release()
{
	# shellcheck disable=SC2039
	local _rel _releases
	if [ -z "$1" ]; then
		return 1 # false
	fi
	_rel="$1"
	_releases="$( _get_valid_releases )"
	if _is_in_list "$_rel" $_releases ; then
		return 0 # true
	else
		return 1 # false
	fi
}

# $1 potname
# it's required to have all the file-system mounted to access /bin/freebsd-version
_get_os_release()
{
	local _pname
	_pname="$1"
	if [ -r "${POT_FS_ROOT}/jails/$_pname/m/bin/freebsd-version" ]; then
		grep ^USERLAND "${POT_FS_ROOT}/jails/$_pname/m/bin/freebsd-version" | cut -f 2 -d"=" | tr -d \"
	else
		_get_conf_var "$_pname" osrelease
	fi
}

# $1 name of the network interface
_is_valid_netif()
{
	local _netif
	_netif="$1"
	if ifconfig "$_netif" > /dev/null 2> /dev/null ; then
		return 0 # true
	else
		return 1 # false
	fi
}

# $1 FreeBSD release.
# for instance 12.0 or 13.0-RC1
_get_freebsd_release_name()
{
	if echo "$1" | grep -q "RC" ; then
		echo "$1"
	else
		echo "$1-RELEASE"
	fi
}

_fetch_freebsd()
{
	local _rel
	if ! _fetch_freebsd_internal "$1" ; then
		# remove artifact and retry only once
		_rel="$( _get_freebsd_release_name "$1" )"
		rm -f /tmp/"${_rel}"_base.txz
		if ! _fetch_freebsd_internal "$1" ; then
			return 1 # false
		fi
		return 0 # true
	fi
	return 0 # true
}

# $1 release, in short format, major.minor or major.minor-RC#
_fetch_freebsd_internal()
{
	# shellcheck disable=SC2039
	local _rel _sha _sha_m
	_rel="$( _get_freebsd_release_name "$1" )"

	if [ ! -r /tmp/"${_rel}"_base.txz ]; then
		fetch -m http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/"${_rel}"/base.txz -o /tmp/"${_rel}"_base.txz
	fi

	if [ ! -r /tmp/"${_rel}"_base.txz ]; then
		return 1 # false
	fi
	if [ -r /usr/local/share/freebsd/MANIFESTS/amd64-amd64-"${_rel}" ]; then
		_sha=$( sha256 -q /tmp/"${_rel}"_base.txz )
		_sha_m=$( cat /usr/local/share/freebsd/MANIFESTS/amd64-amd64-"${_rel}" | awk '/^base.txz/ { print $2 }' )
		if [ "$_sha" != "$_sha_m" ]; then
			_error "sha256 doesn't match! Aborting"
			return 1 # false
		fi
	else
		_error "No manifests found - please install the package freebsd-release-manifests"
		return 1 # false
	fi
	return 0 # true
}

# $1 fscomp.conf absolute pathname
_print_pot_fscomp()
{
	# shellcheck disable=SC2039
	local _dset _mnt_p
	while read -r line ; do
		_dset=$( echo "$line" | awk '{print $1}' )
		_mnt_p=$( echo "$line" | awk '{print $2}' )
		printf "\\t\\t%s => %s\\n" "${_mnt_p##${POT_FS_ROOT}/jails/}" "${_dset##${POT_ZFS_ROOT}/}"
	done < "$1"
}

# $1 pot name
_print_pot_snaps()
{
	if [ -z "$( zfs list -t snapshot -o name -Hr "${POT_ZFS_ROOT}/jails/$1")" ]; then
		printf "\t\tno snapshots\n"
	else
		for _s in $( zfs list -t snapshot -o name -Hr "${POT_ZFS_ROOT}/jails/$1" | tr '\n' ' ' ) ; do
			printf "\\t\\t%s\\n" "$_s"
		done
	fi
}

# $1 pot name
_pot_mount()
{
	local _pname _dset _mnt_p _opt _node
	_pname="$1"
	if ! _is_pot "$_pname" ; then
		return 1 # false
	fi
	while read -r line ; do
		_dset=$( echo "$line" | awk '{print $1}' )
		_mnt_p=$( echo "$line" | awk '{print $2}' )
		_opt=$( echo "$line" | awk '{print $3}' )
		if [ "$_opt" = "zfs-remount" ]; then
			# if the mountpoint doesn't exist, zfs will create it
			zfs set mountpoint="$_mnt_p" "$_dset"
			_node=$( _get_zfs_mountpoint "$_dset" )
			if _zfs_exist "$_dset" "$_node" ; then
				# the information are correct - move the mountpoint
				_debug "_pot_mount: the dataset $_dset is mounted at $_node"
			else
				# mountpoint already moved ?
				_error "_pot_mount: Dataset $_dset not mounted at $_mnt_p! Aborting"
				return 1 # false
			fi
		else
			if _is_absolute_path "$_dset" ; then
				if ! mount_nullfs -o "${_opt:-rw}" "$_dset" "$_mnt_p" ; then
					_error "Error mounting $_dset on $_mnt_p"
					return 1 # false
				else
					_debug "mount $_mnt_p"
				fi
			else
				_node=$( _get_zfs_mountpoint "$_dset" )
				if [ ! -d "$_mnt_p" ]; then
					_debug "start: creating the missing mountpoint $_mnt_p"
					if ! mkdir "$_mnt_p" ; then
						_error "Error creating the missing mountpoint $_mnt_p"
						return 1
					fi
				fi
				if ! mount_nullfs -o "${_opt:-rw}" "$_node" "$_mnt_p" ; then
					_error "Error mounting $_node"
					return 1 # false
				else
					_debug "mount $_mnt_p"
				fi
			fi
		fi
	done < "${POT_FS_ROOT}/jails/$_pname/conf/fscomp.conf"
	if ! mount -t tmpfs tmpfs "${POT_FS_ROOT}/jails/$_pname/m/tmp" ; then
		_error "Error mounting tmpfs"
		return 1
	else
		_debug "mount ${POT_FS_ROOT}/jails/$_pname/m/tmp"
	fi
	return 0 # true
}

# $1 pot name
_pot_umount()
{
	local _pname _tmpfile _jdir _node _mnt_p _opt _dset
	_pname="$1"
	if ! _tmpfile=$(mktemp -t "${_pname}.XXXXXX") ; then
		_error "not able to create temporary file - umount failed"
		return 1 # false
	fi
	_jdir="${POT_FS_ROOT}/jails/$_pname"

	_umount "$_jdir/m/tmp"
	if [ "$(_get_conf_var "$_pname" "pot.attr.fdescfs")" = "YES" ]; then
		_umount "$_jdir/m/dev/fs"
	fi
	_umount "$_jdir/m/dev"
	if [ "$(_get_conf_var "$_pname" "pot.attr.procfs")" = "YES" ]; then
		_umount "$_jdir/m/proc"
	fi
	if [ -e "$_jdir/conf/fscomp.conf" ]; then
		tail -r "$_jdir/conf/fscomp.conf" > "$_tmpfile"
		while read -r line ; do
			_dset=$( echo "$line" | awk '{print $1}' )
			_mnt_p=$( echo "$line" | awk '{print $2}' )
			_opt=$( echo "$line" | awk '{print $3}' )
			if [ "$_opt" = "zfs-remount" ]; then
				_node=${POT_FS_ROOT}/jails/$_pname/$(basename "$_dset")
				zfs set mountpoint="$_node" "$_dset"
				if _zfs_exist "$_dset" "$_node" ; then
					# the information are correct - move the mountpoint
					_debug "stop: the dataset $_dset is mounted at $_node"
				else
					# mountpoint not moved
					_error "Dataset $_dset moved to $_node (Fix it manually)"
				fi
			else
				_umount "$_mnt_p"
			fi
		done < "$_tmpfile"
		rm "$_tmpfile"
	fi
}

_get_pot_list()
{
	ls -d "${POT_FS_ROOT}/jails/"*/ 2>/dev/null | xargs -I {} basename {} | tr '\n' ' '
}

_get_bridge_list()
{
	find "${POT_FS_ROOT}/bridges" -type f 2>/dev/null | xargs -I {} basename {} | tr '\n' ' '
}

pot-cmd()
{
	local _cmd _func
	_cmd=$1
	shift
	if [ ! -r "${_POT_INCLUDE}/${_cmd}.sh" ]; then
		_error "Fatal error! $_cmd implementation not found!"
		exit 1
	fi
	. "${_POT_INCLUDE}/${_cmd}.sh"
	_func=pot-${_cmd}
	case "$_cmd" in
		create|import|clone|create-private-bridge|prepare)
			if [ "$_POT_RECURSIVE" = "1" ]; then
				logger -p "${POT_LOG_FACILITY}".info -t pot "$_func $*"
				$_func "$@"
			else
				export _POT_RECURSIVE=1
				lockf -k /tmp/pot-lock-file $_POT_PATHNAME $_cmd "$@"
			fi
			;;
		*)
			logger -p "${POT_LOG_FACILITY}".info -t pot "$_func $*"
			$_func "$@"
			;;
	esac
}
