#!/usr/bin/env bash
# Image creating script

set -eo pipefail

mount_image_tmp_devices() {
  mount -t ext4 "${IMG_PART}" "${VOLMNT}"/images
  mount -t vfat "${BOOT_PART}" "${ROOTFSMNT}"/boot
}

unmount_image_tmp_devices() {
  umount -l "${VOLMNT}"/images || log "umount ${VOLMNT}/images failed" "wrn"
  umount -l "${ROOTFSMNT}"/boot || log "umount ${ROOTFSMNT}/boot failed" "wrn"
}

clean_loop_devices() {
  log "Cleaning loop device $LOOP_DEV" "$(losetup -j "${IMG_FILE}")"
  dmsetup remove_all
  losetup -d "${LOOP_DEV}" || {
    log "Checking loop devices associations" "dbg"
    losetup
  }
}

exit_error() {
  log "Imagebuilder script failed!!" "err"
  # Check if there are any mounts that need cleaning up
  if isMounted "${ROOTFSMNT}"/boot; then
    log "Cleaning up image_tmp mounts"
    unmount_image_tmp_devices
  fi
  # If dev is mounted, the rest should also be mounted (right?)
  if isMounted "$ROOTFSMNT/dev"; then
    unmount_chroot "${ROOTFSMNT}"
  fi
  # Overkill, INT will call exit_error twice
  # So check if we need to cleanup our LOOP_DEV
  # if losetup | grep -q "${LOOP_DEV}"; then
  clean_loop_devices
  # fi
  if [[ -f ${IMG_FILE} ]]; then
    log "Deleting image file"
    rm "${IMG_FILE}"
  fi
}

trap exit_error INT ERR

log "Stage [2]: Creating Image" "info"
log "Image file: ${IMG_FILE}"
log "Using DEBUG_IMAGE: ${DEBUG_IMAGE:-no}"
VOLMNT=/mnt/volumio
dd if=/dev/zero of="${IMG_FILE}" bs=1M count=2800
LOOP_DEV=$(losetup -f --show "${IMG_FILE}")

# Note: leave the first 20Mb free for the firmware
parted -s "${LOOP_DEV}" mklabel "${BOOT_TYPE}"
parted -s "${LOOP_DEV}" mkpart primary fat32 "${BOOT_START:-0}" "${BOOT_END}"
parted -s "${LOOP_DEV}" mkpart primary ext3 "${BOOT_END}" 2500
parted -s "${LOOP_DEV}" mkpart primary ext3 2500 100%
parted -s "${LOOP_DEV}" set 1 boot on
[[ "${BOOT_TYPE}" == gpt ]] && parted -s "${LOOP_DEV}" set 1 legacy_boot on # for non UEFI systems
parted -s "${LOOP_DEV}" print
partprobe "${LOOP_DEV}"
kpartx -a "${LOOP_DEV}" -s

BOOT_PART=/dev/mapper/"$(awk -F'/' '{print $NF}' <<<"${LOOP_DEV}")"p1
IMG_PART=/dev/mapper/"$(awk -F'/' '{print $NF}' <<<"$LOOP_DEV")"p2
DATA_PART=/dev/mapper/"$(awk -F'/' '{print $NF}' <<<"$LOOP_DEV")"p3

if [[ ! -b "$BOOT_PART" ]]; then
  log "$BOOT_PART doesn't exist" "err"
  exit 1
fi

log "Creating filesystem" "info"
mkfs -t vfat -n boot "${BOOT_PART}"
mkfs -F -t ext4 -L volumio "${IMG_PART}"
mkfs -F -t ext4 -L volumio_data "${DATA_PART}"
#sync

log "Copying Volumio rootfs" "info"

if [[ -d ${VOLMNT} ]]; then
  log "Volumio Temp Directory Exists - Cleaning it"
  rm -rf ${VOLMNT:?}/*
else
  log "Creating Volumio Temp Directory"
  mkdir -p ${VOLMNT}
fi

# Create mount point for image partitions
log "Creating mount point for the images partition"
ROOTFSMNT=${VOLMNT}/rootfs
mkdir ${VOLMNT}/images
mkdir -p ${ROOTFSMNT}/boot
# Boot is vfat

mount_image_tmp_devices

#TODO -pPR?
log "Copying Volumio RootFs" "info"
cp -pdR "${ROOTFS}"/* ${ROOTFSMNT}

# Refactor this to support more binaries
if [[ $VOLINITUPDATER == yes ]]; then
  log "Fetching volumio-init-updater"
  wget -P ${ROOTFSMNT}/usr/local/sbin \
    -nv "${VOLBINSREPO}/${BUILD}/${VOLBINS[init - updater]}"
  # initramfs doesn't know about v2
  mv ${ROOTFSMNT}/usr/local/sbin/volumio-init-updater-v2 \
    ${ROOTFSMNT}/usr/local/sbin/volumio-init-updater
fi

log "Getting device specific files for ${DEVICE} from platform-${DEVICEBASE}" "info"
PLTDIR="${SRC}/platform-${DEVICEBASE}"
if [[ -d $PLTDIR ]]; then
  log "Platform folder exists, keeping it" "" "platform-${DEVICEBASE}"
  HAS_PLTDIR=yes
elif [[ -n $DEVICEREPO ]]; then
  log "Cloning platform-${DEVICEBASE} from ${DEVICEREPO}"
  git clone --depth 1 "${DEVICEREPO}" "platform-${DEVICEBASE}"
  log "Unpacking $DEVICE files"
  log "This isn't really consistent across platforms right now!" "dbg"
  # mkdir -p ${PLTDIR}/${DEVICE}
  tar xfJ "platform-${DEVICEBASE}/${DEVICE}.tar.xz" -C "${PLTDIR}" || log "No archive found, assuming you know what you are doing!" "wrn"
  HAS_PLTDIR=yes
else
  log "No platfrom-${DEVICE} found, skipping this step"
  HAS_PLTDIR=no
fi

if [[ $HAS_PLTDIR == yes ]]; then
  # This is pulled in from each device's config script
  log "Copying ${DEVICE} boot files from platform-${DEVICEBASE}" "info"
  log "Entering write_device_files" "cfg"
  write_device_files
  log "Entering write_device_bootloader" "cfg"
  write_device_bootloader
fi

# Device specific tweaks
log "Performing ${DEVICE} specific tweaks" "info"
log "Entering device_image_tweaks" "cfg"
device_image_tweaks

# Grab the UUIDS for boards that use it
UUID_BOOT="$(blkid -s UUID -o value "${BOOT_PART}")"
UUID_IMG="$(blkid -s UUID -o value "${IMG_PART}")"
UUID_DATA="$(blkid -s UUID -o value "${DATA_PART}")"

log "Adding board pretty name to os-release"
echo "VOLUMIO_DEVICENAME=\"${DEVICENAME}\"" >>${ROOTFSMNT}/etc/os-release
# Ensure all file systems operations are completed before entering chroot again
sync

#### Build stage 2 - Device specific chroot config
log "Preparing to run chroot for more ${DEVICE} configuration" "info"
start_chroot_final=$(date +%s)
cp "${SRC}/scripts/initramfs/${INIT_TYPE}" ${ROOTFSMNT}/root/init
cp "${SRC}"/scripts/initramfs/mkinitramfs-buster.sh ${ROOTFSMNT}/usr/local/sbin
cp "${SRC}"/scripts/volumio/chrootconfig.sh ${ROOTFSMNT}

if [[ "$KIOSKMODE" == yes ]]; then
  log "Copying kiosk scripts to rootfs"
  cp "${SRC}/scripts/volumio/install-kiosk.sh" ${ROOTFSMNT}/install-kiosk.sh
fi

echo "$PATCH" >${ROOTFSMNT}/patch
if [[ -f "${ROOTFSMNT}/${PATCH}/patch.sh" ]] && [[ -f "${SDK_PATH}"/config.js ]]; then
  log "Starting ${SDK_PATH}/config.js" "ext" "${PATCH}"
  node "${SDK_PATH}"/config.js "${PATCH}"
  status=$?
  [[ ${status} -ne 0 ]] && log "config.js failed with ${status}" "err" "${PATCH}" && exit 10
  log "Completed config.js" "ext" "${PATCH}"
fi

# Copy across custom bits and bobs from device config
# This is in the hope that <./recipes/devices/${DEVICE}>
# doesn't grow back into the old <xxxxconfig.sh>
BOOT_FS_SPEC="/dev/mmcblk0p1"
[[ ${BOOT_USE_UUID} == yes ]] && BOOT_FS_SPEC="UUID=${UUID_BOOT}"
log "Setting /boot fs_sepc to ${BOOT_FS_SPEC}"
#TODO: Should we just copy the
# whole thing into the chroot to make life easier?
cat <<-EOF >$ROOTFSMNT/chroot_device_config.sh
DEVICENAME="${DEVICENAME}"
ARCH="${ARCH}"
BUILD="${BUILD}"
DEBUG_IMAGE="${DEBUG_IMAGE:-no}"
KIOSKMODE="${KIOSKMODE:-no}"
KIOSKINSTALL="${KIOSKMODE:-install-kiosk.sh}"
VOLVARIANT="${VOLVARIANT:-volumio}"
BOOT_FS_SPEC=${BOOT_FS_SPEC}
UUID_BOOT=${UUID_BOOT}
UUID_IMG=${UUID_IMG}
UUID_DATA=${UUID_DATA}
BOOT_PART=${BOOT_PART}
LOOP_DEV=${LOOP_DEV}
MODULES=($(printf '\"%s\" ' "${MODULES[@]}"))
PACKAGES=($(printf '\"%s\" ' "${PACKAGES[@]}"))
$(declare -f device_chroot_tweaks)
$(declare -f device_chroot_tweaks_pre)
$(declare -f device_chroot_tweaks_post)
EOF

mount_chroot "${ROOTFSMNT}"

log "Calling final chroot config script"
chroot "$ROOTFSMNT" /chrootconfig.sh

log "Finished chroot config for ${DEVICE}" "okay"
# Clean up chroot stuff
rm ${ROOTFSMNT:?}/*.sh ${ROOTFSMNT}/root/init

unmount_chroot ${ROOTFSMNT}
end_chroot_final=$(date +%s)
time_it "$end_chroot_final" "$start_chroot_final"
log "Finished chroot image configuration" "okay" "$TIME_STR"

log "Finalizing Rootfs (Cleaning, Stripping, Hashing)" "info"
# shellcheck source=./scripts/volumio/finalize.sh
source "${SRC}/scripts/volumio/finalize.sh"

log "Rootfs created" "okay"

#### Build stage 3 - Prepare squashfs
log "Preparing rootfs base for SquashFS" "info"

SQSHMNT="$VOLMNT/squash"
if [[ -d $SQSHMNT ]]; then
  log "Volumio SquashFS Temp Dir Exists - Cleaning it"
  rm -rf ${SQSHMNT:?}/*
else
  log "Creating Volumio SquashFS Temp Dir at $SQSHMNT"
  mkdir $SQSHMNT
fi
log "Copying Volumio rootfs to SquashFS Dir"
cp -rp $ROOTFSMNT/* $SQSHMNT

log "Creating Kernel Partition Archive" "info"
if [ -e $VOLMNT/kernel_current.tar ]; then
  log "Volumio Kernel Partition Archive exists - Cleaning it"
  rm -rf $VOLMNT/kernel_current.tar
fi

log "Creating Kernel archive"
tar cf "${VOLMNT}/kernel_current.tar" --exclude='resize-volumio-datapart' \
  -C $SQSHMNT/boot/ .

log "Removing the Kernel from SquashFS"
rm -rf ${SQSHMNT:?}/boot/*

log "Creating SquashFS, removing any previous one" "info"
[[ -f "${SRC}/Volumio.sqsh" ]] && rm "${SRC}/Volumio.sqsh"
mksquashfs ${SQSHMNT}/* "${SRC}/Volumio.sqsh"

log "Squash filesystem created" "okay"
rm -rf --one-file-system $SQSHMNT

log "Preparing boot partition" "info"
#copy the squash image inside the boot partition
cp "${SRC}"/Volumio.sqsh ${VOLMNT}/images/volumio_current.sqsh
sync

log "Cleaning up" "info"
log "Unmounting temp devices"
unmount_image_tmp_devices

log "Cleaning up loop devices"
clean_loop_devices
sync

log "Removing Volumio.sqsh"
[[ -f "${SRC}"/Volumio.sqsh ]] && rm "${SRC}"/Volumio.sqsh

log "Hashing image" "info"
md5sum "$IMG_FILE" >"${IMG_FILE}.md5"
