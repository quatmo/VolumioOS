#!/bin/sh

umask 0022
export PATH='/usr/bin:/sbin:/bin'

# Defaults
keep="n"
CONFDIR="/etc/initramfs-tools"
verbose="n"
test -e /bin/busybox && BUSYBOXDIR=/bin
test -e /usr/lib/initramfs-tools/bin/busybox && BUSYBOXDIR=/usr/lib/initramfs-tools/bin
export BUSYBOXDIR

OPTIONS=`getopt -o c:d:ko:r:v -n "$0" -- "$@"`

# Check for non-GNU getopt
if [ $? != 0 ] ; then echo "W: non-GNU getopt" >&2 ; exit 1 ; fi

eval set -- "$OPTIONS"

while true; do
	case "$1" in
	-c)
		compress="$2"
		shift 2
		;;
	-d)
		CONFDIR="$2"
		shift 2
		if [ ! -d "${CONFDIR}" ]; then
			echo "${0}: ${CONFDIR}: Not a directory" >&2
			exit 1
		fi
		;;
	-o)
		outfile="$2"
		shift 2
		;;
	-k)
		keep="y"
		shift
		;;
	-r)
		ROOT="$2"
		shift 2
		;;
	-v)
		verbose="y"
		shift
		;;
	--)
		shift
		break
		;;
	*)
		echo "Internal error!" >&2
		exit 1
		;;
	esac
done

# For dependency ordered mkinitramfs hook scripts.
. /usr/share/initramfs-tools/scripts/functions
. /usr/share/initramfs-tools/hook-functions

. "${CONFDIR}/initramfs.conf"
EXTRA_CONF=''
for i in /usr/share/initramfs-tools/conf.d/* ${CONFDIR}/conf.d/*; do
	[ -e $i ] && EXTRA_CONF="${EXTRA_CONF} $(basename $i \
		| grep '^[[:alnum:]][[:alnum:]\._-]*$' | grep -v '\.dpkg-.*$')";
done
# FIXME: deprecated those settings on mkinitramfs run
# 	 these conf dirs are for boot scripts and land on initramfs
for i in ${EXTRA_CONF}; do
	if [ -d  ${CONFDIR}/conf.d/${i} ]; then
		echo "Warning: ${CONFDIR}/conf.d/${i} is a directory instead of file, ignoring."
	elif [ -e  ${CONFDIR}/conf.d/${i} ]; then
		. ${CONFDIR}/conf.d/${i}
	elif [ -e  /usr/share/initramfs-tools/conf.d/${i} ]; then
		. /usr/share/initramfs-tools/conf.d/${i}
	fi
done

# source package confs
for i in /usr/share/initramfs-tools/conf-hooks.d/*; do
	if [ -d "${i}" ]; then
		echo "Warning: ${i} is a directory instead of file, ignoring."
	elif [ -e "${i}" ]; then
		. "${i}"
	fi
done

if [ -n "${UMASK:-}" ]; then
	umask "${UMASK}"
fi

if [ -z "${outfile}" ]; then
	usage
fi
















touch "$outfile"
outfile="$(readlink -f "$outfile")"
version="$(ls -t /lib/modules | cat | head -n1)"
echo "Version: ${version}"

case "${version}" in
/lib/modules/*/[!/]*)
	;;
/lib/modules/[!/]*)
	version="${version#/lib/modules/}"
	version="${version%%/*}"
	;;
esac

case "${version}" in
*/*)
	echo "$PROG: ${version} is not a valid kernel version" >&2
	exit 1
	;;
esac

# Check userspace and kernel support for compressed initramfs images
if [ -z "${compress:-}" ]; then
	compress=${COMPRESS}
else
	COMPRESS=${compress}
fi

if ! command -v "${compress}" >/dev/null 2>&1; then
	compress=gzip
	[ "${verbose}" = y ] && \
		echo "No ${COMPRESS} in ${PATH}, using gzip"
	COMPRESS=gzip
fi

if dpkg --compare-versions "${version}" lt "2.6.38" 2>/dev/null; then
	compress=gzip
	[ "${verbose}" = y ] && \
		echo "linux-2.6 likely misses ${COMPRESS} support, using gzip"
fi

[ "${compress}" = lzop ] && compress="lzop -9"
[ "${compress}" = xz ] && compress="xz --check=crc32"

if [ -d "${outfile}" ]; then
	echo "${outfile} is a directory" >&2
	exit 1
fi

MODULESDIR="/lib/modules/${version}"

if [ ! -e "${MODULESDIR}" ]; then
	echo "WARNING: missing ${MODULESDIR}"
	echo "Ensure all necessary drivers are built into the linux image!"
fi
if [ ! -e "${MODULESDIR}/modules.dep" ]; then
	depmod ${version}
fi

[ -n "${TMPDIR}" ] && [ ! -w "${TMPDIR}" ] && unset TMPDIR
DESTDIR="$(mktemp -d ${TMPDIR:-/var/tmp}/mkinitramfs_XXXXXX)" || exit 1
chmod 755 "${DESTDIR}"

__TMPCPIOGZ="$(mktemp ${TMPDIR:-/var/tmp}/mkinitramfs-OL_XXXXXX)" || exit 1
__TMPEARLYCPIO="$(mktemp ${TMPDIR:-/var/tmp}/mkinitramfs-FW_XXXXXX)" || exit 1

DPKG_ARCH=`dpkg --print-architecture`

# Export environment for hook scripts.
#
export MODULESDIR
export version
export CONFDIR
export DESTDIR
export DPKG_ARCH
export verbose
export KEYMAP
export MODULES
export BUSYBOX

# Private, used by 'catenate_cpiogz'.
export __TMPCPIOGZ

# Private, used by 'prepend_earlyinitramfs'.
export __TMPEARLYCPIO

for d in bin conf/conf.d etc lib/modules run sbin scripts ${MODULESDIR}; do
	mkdir -p "${DESTDIR}/${d}"
done

# Copy in modules.builtin and modules.order (not generated by depmod)
for x in modules.builtin modules.order; do
	if [ -f "${MODULESDIR}/${x}" ]; then
		cp -p "${MODULESDIR}/${x}" "${DESTDIR}${MODULESDIR}/${x}"
	fi
done

# MODULES=list case.  Always honour.
for x in "${CONFDIR}/modules" /usr/share/initramfs-tools/modules.d/*; do
	if [ -f "${x}" ]; then
		add_modules_from_file "${x}"
	fi
done

# MODULES=most is default
case "${MODULES}" in
dep)
	dep_add_modules
	;;
most)
	auto_add_modules
	;;
netboot)
	auto_add_modules base
	auto_add_modules net
	;;
list)
	# nothing to add
	;;
*)
	echo "W: mkinitramfs: unsupported MODULES setting: ${MODULES}."
	echo "W: mkinitramfs: Falling back to MODULES=most."
	auto_add_modules
	;;
esac

# Resolve hidden dependencies
hidden_dep_add_modules



















# First file executed by linux
cp -p /usr/share/initramfs-tools/init ${DESTDIR}/init

# add existant boot scripts
#for b in $(cd /usr/share/initramfs-tools/scripts/ && find . \
#	-regextype posix-extended -regex '.*/[[:alnum:]\._-]+$' -type f); do
#	[ -d "${DESTDIR}/scripts/$(dirname "${b}")" ] \
#		|| mkdir -p "${DESTDIR}/scripts/$(dirname "${b}")"
#	cp -p "/usr/share/initramfs-tools/scripts/${b}" \
#		"${DESTDIR}/scripts/$(dirname "${b}")/"
#done
#for b in $(cd "${CONFDIR}/scripts" && find . \
#	-regextype posix-extended -regex '.*/[[:alnum:]\._-]+$' -type f); do
#	[ -d "${DESTDIR}/scripts/$(dirname "${b}")" ] \
#		|| mkdir -p "${DESTDIR}/scripts/$(dirname "${b}")"
#	cp -p "${CONFDIR}/scripts/${b}" "${DESTDIR}/scripts/$(dirname "${b}")/"
#done

echo "DPKG_ARCH=${DPKG_ARCH}" > ${DESTDIR}/conf/arch.conf
cp -p "${CONFDIR}/initramfs.conf" ${DESTDIR}/conf
for i in ${EXTRA_CONF}; do
	if [ -e "${CONFDIR}/conf.d/${i}" ]; then
		copy_exec "${CONFDIR}/conf.d/${i}" /conf/conf.d
	elif [ -e "/usr/share/initramfs-tools/conf.d/${i}" ]; then
		copy_exec "/usr/share/initramfs-tools/conf.d/${i}" /conf/conf.d
	fi
done

# ROOT hardcoding
if [ -n "${ROOT:-}" ]; then
	echo "ROOT=${ROOT}" > ${DESTDIR}/conf/conf.d/root
fi

if ! command -v ldd >/dev/null 2>&1 ; then
	echo "WARNING: no ldd around - install libc-bin" >&2
	exit 1
fi

# fstab and mtab
touch "${DESTDIR}/etc/fstab"
ln -s /proc/mounts "${DESTDIR}/etc/mtab"

# module-init-tools
copy_exec /sbin/modprobe /sbin
copy_exec /sbin/rmmod /sbin
mkdir -p "${DESTDIR}/etc/modprobe.d"
cp -a /etc/modprobe.d/* "${DESTDIR}/etc/modprobe.d/"

# workaround: libgcc always needed on old-abi arm
if [ "$DPKG_ARCH" = arm ] || [ "$DPKG_ARCH" = armeb ]; then
	cp -a /lib/libgcc_s.so.1 "${DESTDIR}/lib/"
fi

run_scripts /usr/share/initramfs-tools/hooks
run_scripts "${CONFDIR}"/hooks

# cache boot run order
for b in $(cd "${DESTDIR}/scripts" && find . -mindepth 1 -type d); do
	cache_run_scripts "${DESTDIR}" "/scripts/${b#./}"
done

# generate module deps
depmod -a -b "${DESTDIR}" ${version}
rm -f "${DESTDIR}/lib/modules/${version}"/modules.*map

# make sure that library search path is up to date
cp -ar /etc/ld.so.conf* "$DESTDIR"/etc/
if ! ldconfig -r "$DESTDIR" ; then
	[ $(id -u) != "0" ] \
	&& echo "ldconfig might need uid=0 (root) for chroot()" >&2
fi

# Apply DSDT to initramfs
if [ -e "${CONFDIR}/DSDT.aml" ]; then
	copy_exec "${CONFDIR}/DSDT.aml" /
fi

# Make sure there is a final sh in initramfs
if [ ! -e "${DESTDIR}/bin/sh" ]; then
	copy_exec /bin/sh "${DESTDIR}/bin/"
fi

# Remove any looping or broken symbolic links, since they break cpio.
[ "${verbose}" = y ] && xargs_verbose="-t"
(cd "${DESTDIR}" && find . -type l -printf '%p %Y\n' | sed -n 's/ [LN]$//p' \
	| xargs ${xargs_verbose:-} -rL1 rm -f)

# dirty hack for armhf's double-linker situation; if we have one of
# the two known eglibc linkers, nuke both and re-create sanity
if [ "$DPKG_ARCH" = armhf ]; then
	if [ -e "${DESTDIR}/lib/arm-linux-gnueabihf/ld-linux.so.3" ] || \
	   [ -e "${DESTDIR}/lib/ld-linux-armhf.so.3" ]; then
		rm -f "${DESTDIR}/lib/arm-linux-gnueabihf/ld-linux.so.3"
		rm -f "${DESTDIR}/lib/ld-linux-armhf.so.3"
		cp -aL /lib/ld-linux-armhf.so.3 "${DESTDIR}/lib/"
		ln -sf /lib/ld-linux-armhf.so.3 "${DESTDIR}/lib/arm-linux-gnueabihf/ld-linux.so.3"
	fi
fi

[ "${verbose}" = y ] && echo "Building cpio ${outfile} initramfs"

if [ -s "${__TMPEARLYCPIO}" ]; then
	cat "${__TMPEARLYCPIO}" >"${outfile}" || exit 1
else
	# truncate
	> "${outfile}"
fi

#(
# preserve permissions if root builds the image, see #633582
#[ "$UID" != 0 ] && cpio_owner_root="-R 0:0"

#adding parted to the initramfs
echo "Adding parted to initramfs"
cp /sbin/parted "${DESTDIR}/sbin"
cp /sbin/partprobe "${DESTDIR}/sbin"
cp /lib/arm-linux-gnueabihf/libparted.so.2 "${DESTDIR}/lib/arm-linux-gnueabihf"
cp /lib/arm-linux-gnueabihf/libreadline.so.6 "${DESTDIR}/lib/arm-linux-gnueabihf"
cp /lib/arm-linux-gnueabihf/libtinfo.so.5 "${DESTDIR}/lib/arm-linux-gnueabihf"

echo "Adding mkfs.ext4 to initramfs"
cp /sbin/mkfs.ext4 "${DESTDIR}/sbin"
cp /lib/arm-linux-gnueabihf/libext2fs.so.2 "${DESTDIR}/lib/arm-linux-gnueabihf"
cp /lib/arm-linux-gnueabihf/libcom_err.so.2 "${DESTDIR}/lib/arm-linux-gnueabihf"
cp /lib/arm-linux-gnueabihf/libe2p.so.2 "${DESTDIR}/lib/arm-linux-gnueabihf"

echo "Adding volumio-init-updater to initramfs"
cp /usr/local/sbin/volumio-init-updater "${DESTDIR}/sbin"

#Manage the destdir folder removing the auto-generated scripts
rm -rf "${DESTDIR}/scripts"
cp /root/init "${DESTDIR}"

#Creation of the initrd image
cd ${DESTDIR}
find . -print0 | cpio -ov -0 --format=newc | gzip -9 > /boot/volumio.initrd

echo "initramfs volumio.initrd" >> /boot/config.txt

if [ -e /boot/cmdline.txt ]; then
	mv /boot/cmdline.txt /boot/cmdline.txt.bak
fi
echo "Writing cmdline file"
touch /boot/cmdline.txt
echo "imgpart=/dev/mmcblk0p2 imgfile=/volumio_current.sqsh" >> /boot/cmdline.txt