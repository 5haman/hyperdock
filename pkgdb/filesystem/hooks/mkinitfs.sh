#!/bin/sh

sysconfdir=@sysconfdir@
datadir=@datadir@

config="$sysconfdir"/mkinitfs.conf
init="$datadir"/initramfs-init
fstab="$datadir"/fstab
passwd="$datadir"/passwd
group="$datadir"/group

startdir=$PWD

feature_files() {
	local dir="$1"
	local suffix="$2"
	local glob file
	for f in $features; do
		if [ ! -f "$features_dir/$f.$suffix" ]; then
			continue
		fi
		for glob in $(sed -e '/^$/d' -e '/^#/d' -e "s|^/*|$dir|" "$features_dir/$f.$suffix"); do
			for file in $glob; do
				if [ -d $file ]; then
					find $file -type f
				elif [ -e "$file" ]; then
					echo $file
				fi
			done
		done
	done
}

initfs_base() {
	local i= dirs= glob= file=
	for i in dev proc sys sbin bin run lib/modules \
	    etc/apk newroot; do
		dirs="$dirs $tmpdir/$i"
	done
	mkdir -p $dirs

	local oldpwd="$PWD"
	cd "${basedir}"
	lddtree -R "$basedir" -l --no-auto-root \
		$(feature_files "$basedir" files) \
		| sed -e "s|^$basedir||" | sort -u \
		| cpio --quiet -pdm "$tmpdir" || return 1

	# copy init
	cd "$startdir"
	install -m755 "$init" "$tmpdir"/init || return 1
	for i in "$fstab" "$passwd" "$group"; do
		install -Dm644 "$i" "$tmpdir"/etc/${i##*/} || return 1
	done
	cd "$oldpwd"
}

find_kmod_deps() {
	awk -v prepend="/lib/modules/$kernel/" -v modulesdep="${basedir}lib/modules/$kernel/modules.dep" '
function recursedeps(k,		j, dep) {
	if (k in visited)
		return;
	visited[k] = 1;
	split(deps[k], dep, " ");
	for (j in dep)
		recursedeps(dep[j]);
	print(prepend k);
}

BEGIN {
	if (modulesdep == "")
		modulesdep="modules.dep";
	FS = ": ";
	while ( (getline < modulesdep) > 0) {
		if (substr($0,1,1) == "/") {
			gsub(prepend, "", $1);
			gsub(prepend, "", $2);
		}
		deps[$1] = $2;
	}
}

{
	mod[$0] = 1;
}

END {
	for (i in mod)
		recursedeps(i);
}'
}

find_kmods() {
	local oldpwd="$PWD"
	cd "$kerneldir" || return 1
	for file in $(feature_files "${kerneldir}/" modules); do
		echo ${file#${kerneldir%/}/}
	done | find_kmod_deps
	cd "$oldpwd"
}

initfs_kmods() {
	[ -z "$nokernel" ] || return
	local glob= file= files= dirs=
	rm -rf "$tmpdir"/lib/modules
	# make sure we have modules.dep
	if ! [ -f "$kerneldir"/modules.dep ]; then
		depmod -b "${basedir}" $kernel
	fi
	local oldpwd="$PWD"
	cd "${basedir}"
	for file in $(find_kmods); do
		echo "${file#/}"
	done | sort -u | cpio --quiet -pdm "$tmpdir" || return 1
	for file in modules.order modules.builtin; do
		if [ -f "$kerneldir"/$file ]; then
			cp "$kerneldir"/$file "$tmpdir"/lib/modules/$kernel/
		fi
	done
	depmod $kernel -b "$tmpdir"
	cd "$oldpwd"
}

initfs_apk_keys() {
	mkdir -p "$tmpdir"/etc/apk/keys
	[ "$hostkeys" ] && cp "/etc/apk/keys/"* "$tmpdir"/etc/apk/keys/
	cp "${basedir}etc/apk/keys/"* "$tmpdir"/etc/apk/keys/
}

initfs_cpio() {
	if [ -n "$list_sources" ]; then
		(cd "$tmpdir" && find . | sort)
		return
	fi
	rm -f $outfile
	umask 0022
	(chown -R root "$tmpdir" && cd "$tmpdir" && find . | sort | cpio --quiet -o -H newc | xz -e -9) > $outfile
}

usage() {
	cat <<EOF
usage: mkinitfs [-hkKLln] [-b basedir] [-c configfile] [-F features] [-f fstab]
		[-i initfile ] [-o outfile] [-t tempdir] [kernelversion]"
options:
	-b  prefix files and kernel modules with basedir
	-c  use configfile instead of $config
	-f  use fstab instead of $fstab
	-F  use specified features
	-h  print this help
	-i  use initfile as init instead of $init
	-k  keep tempdir
	-K  copy also host keys to initramfs
	-l  only list files that would have been used
	-L  list available features
	-n  don't include kernel modules or firmware
	-o  set another outfile
	-q  Quiet mode
	-t  use tempdir when creating initramfs image

EOF
	exit 1
}

# main

while getopts "b:c:f:F:hi:kKLlno:qt:" opt; do
	case "$opt" in
		b) basedir="$OPTARG";;
		c) config="$OPTARG";;
		F) myfeatures="$OPTARG";;
		f) fstab="$OPTARG";;
		h) usage;;
		i) init=$OPTARG;;
		k) keeptmp=1;;
		K) hostkeys=1;;
		L) list_features=1;;
		l) list_sources=1;;
		n) nokernel=1;;
		o) outfile="$OPTARG";;
		q) quiet=1;;
		t) tmpdir="$OPTARG";;
		*) usage;;
	esac
done
shift $(( $OPTIND - 1 ))

. $(readlink -f "$config")
features_dir=${features_dir:-"${basedir%/:-}/${sysconfdir#/}/features.d"}
[ -n "$myfeatures" ] && features="$myfeatures"

if [ -n "$list_features" ]; then
	for i in $features_dir/*.files $features_dir/*.modules; do
		[ -e "$i" ] || continue
		local file=${i##*/}
		echo ${file%.*}
	done | sort -u
	exit 0
fi

basedir="${basedir%/}/"
[ "${basedir}" = "${basedir#/}" ] && basedir="${PWD}/${basedir}"


if [ -z "$nokernel" ]; then
	[ -n "$1" ] && kernel="$1"
	[ -z "$kernel" ] && kernel=$(uname -r)
	kerneldir="${basedir}lib/modules/$kernel"
fi

if [ -z "$outfile" ]; then
	outfile="${basedir}boot/ramdisk.img"
fi

if [ -z "$nokernel"] && [ ! -d "$kerneldir" ]; then
	echo "$kerneldir does not exist or is not a directory"
	exit 1
fi

if [ -z "$tmpdir" ]; then
	tmpdir=$(mktemp -d /tmp/mkinitfs.XXXXXX)
else
	mkdir -p "$tmpdir"
fi

if [ -z "$keeptmp" ]; then
	[ -d "$tmpdir" ] && rm -rf "$tmpdir"/*
fi

if [ -z "$list_sources" ] && [ -z "$quiet" ]; then
	echo "==> initramfs: creating DockerVM ramdisk '$outfile'"
fi

initfs_base \
&& initfs_kmods \
&& initfs_apk_keys \
&& initfs_cpio
rc=$?

# cleanup
if [ -z "$keeptmp" ]; then
	[ -d "$tmpdir" ] && rm -rf "$tmpdir"
fi

exit $rc
