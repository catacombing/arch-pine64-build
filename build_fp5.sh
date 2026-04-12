#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2023 Dang Huynh <danct12@disroot.org>
# Ruined 2025 by Christian Duerr <alarm@christianduerr.com>

set -e

SUPPORTED_ARCHES=(aarch64 armv7)
NOCONFIRM=0
NO_BOOTLOADER=0
use_pipewire=0
output_folder="build"
mkdir -p "$output_folder"
cachedir="$output_folder/pkgcache"
temp=$(mktemp -p $output_folder -d)
date=$(date +%Y%m%d)

error() { echo -e "\e[41m\e[5mERROR:\e[49m\e[25m $1" && exit 1; }
check_dependency() { [ $(which $1) ] || error "$1 not found. Please make sure it is installed and on your PATH."; }
usage() { error "$0 <-a ARCHITECTURE> <-d DEVICE> <-p PACKAGES> [-h HOSTNAME] [--noconfirm] [--cachedir directory] [--no-cachedir]"; }
cleanup() {
    trap '' EXIT
    trap '' INT
    if [ -d "$temp" ]; then
        unmount_chroot
        rm -r "$temp"
    fi
}

trap cleanup EXIT
trap cleanup INT

pre_check() {
    check_dependency curl
    check_dependency bsdtar
    check_dependency fallocate
    check_dependency fdisk
    check_dependency losetup
    check_dependency mkfs.vfat
    check_dependency mkfs.ext4
    check_dependency genfstab
    check_dependency lsof
    check_dependency parted
    chmod 755 "$temp"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -a|--arch) arch=$2; shift ;;
            -d|--device) device=$2; shift ;;
            -p|--packages) packages=$2; shift ;;
            -h|--hostname) hostname=$2; shift ;;
            --noconfirm) NOCONFIRM=1;;
            --cachedir) cachedir=$2; shift ;;
            --no-cachedir) cachedir= ;;
            *) usage ;;
        esac
        shift
    done
}

parse_presets() {
    [ ! -e "devices/$device" ] && error "Device \"$device\" is unknown!"

    [ ! -e "devices/$device/config" ] && error "\"$device\" doesn't have a config file!" \
        || source "devices/$device/config"

    # Add device-specific packages.
    for i in $(cat "devices/$device/packages"); do
        packages_device+=( $i )
    done

    # Add postinstall steps for DE package groups.
    if [[ "$packages" =~ " danctnix-phosh-ui-meta " ]]; then
        postinstall+=("systemctl enable bluetooth\n")
        postinstall+=("systemctl enable cups\n")
        postinstall+=("systemctl enable ModemManager\n")
        postinstall+=("systemctl enable phosh\n")
    fi
    if [[ "$packages" =~ " danctnix-pm-ui-meta " ]]; then
        postinstall+=("groupadd -r autologin\n")
        postinstall+=("gpasswd -a alarm autologin\n")
        postinstall+=("systemctl enable bluetooth\n")
        postinstall+=("systemctl enable cups\n")
        postinstall+=("systemctl enable ModemManager\n")
        postinstall+=("systemctl enable lightdm\n")
    fi
}

check_arch() {
    echo ${SUPPORTED_ARCHES[@]} | grep -q $arch || { echo "$arch is not supported. Supported architecture are: ${SUPPORTED_ARCHES[@]}" && exit 1; }
}

download_rootfs() {
    alarm_filename="ArchLinuxARM-$arch-latest.tar.gz"
    alarm_url="http://os.archlinuxarm.org/os/$alarm_filename"

    # Get latest ALARM checksum.
    alarm_md5sum_file=$(curl -L "$alarm_url.md5")
    rootfs_md5=$(printf "$alarm_md5sum_file" | awk '{print $1}')

    alarm_rootfs="ArchLinuxARM-$arch-$rootfs_md5.tar.gz"

    # Short-circuit if rootfs already exists.
    if [ -f "$output_folder/$alarm_rootfs" ]; then
        echo "Using cached ALARM rootfs $output_folder/$alarm_rootfs"
        return
    fi

    # Delete old ALARM rootfs tarballs.
    rm -f $output_folder/ArchLinuxARM*

    # Download ALARM rootfs.
    curl -L "$alarm_url" -o "$output_folder/$alarm_filename"

    # Verify rootfs checksum.
    pushd .
    cd $output_folder && { printf "$alarm_md5sum_file" | md5sum -c \
        || { rm "$alarm_rootfs" && error "ALARM rootfs checksum failed!"; } }
    popd

    # Move to filename with md5sum.
    mv "$output_folder/$alarm_filename" "$output_folder/$alarm_rootfs"
}

extract_rootfs() {
    [ -f "$output_folder/$alarm_rootfs" ] || error "ALARM rootfs not found"
    bsdtar -xpf "$output_folder/$alarm_rootfs" -C "$temp"
}

mount_chroot() {
    mount -o bind /dev "$temp/dev"
    mount -t proc proc "$temp/proc"
    mount -t sysfs sys "$temp/sys"
    mount -t tmpfs tmpfs "$temp/tmp"
}

unmount_chroot() {
    for i in $(lsof +D "$temp" | tail -n+2 | tr -s ' ' | cut -d ' ' -f 2 | sort -nu); do
        kill -9 $i
    done

    for i in $(cat /proc/mounts | awk '{print $2}' | grep "^$(readlink -f $temp)"); do
        [ $i ] && umount -l $i
    done
}

mount_cache() {
    if [ -n "$cachedir" ]; then
        mkdir -p "$cachedir"
        mount --bind "$cachedir" "$temp/var/cache/pacman/pkg" || error "Failed to mount pkg cache!";
    fi
}

unmount_cache() {
    if [[ $(findmnt "$temp/var/cache/pacman/pkg") ]]; then
        umount -l "$temp/var/cache/pacman/pkg" || error "Failed to unmount pkg cache!";
    fi
}

do_chroot() {
    chroot "$temp" "$@"
}

cleanup_cache() {
    # Expire cached images after 13 days.
    #
    # We use just under 2 weeks to ensure when Isotopia prompts a rebuild clock
    # differences aren't going to cause any issues.
    max_age=$((60 * 60 * 24 * 13))

    now=$(date +%s)

    for file in $output_folder/{alarm-,base-,packaged-}*; do
        if [ ! -f "$file" ]; then
            continue;
        fi

        creation_time=$(stat -c %W "$file")
        delta=$((now - creation_time))

        if [ $delta -ge $max_age ]; then
            echo "Removing $file from cache"
            rm "$file"
        fi
    done
}

init_rootfs() {
    download_rootfs

    rootfs_tarball="base-$device-$rootfs_md5.tar.gz"

    # Short-circuit if danctnix rootfs already exists.
    if [ -f "$output_folder/$rootfs_tarball" ]; then
        echo "Using cached Danctnix rootfs $output_folder/$rootfs_tarball"
        return
    fi

    extract_rootfs
    mount_chroot
    mount_cache

    # Some ALARM tarballs omit this file, breaking mkinitcpio.
    touch "$temp/etc/vconsole.conf"

    rm "$temp/etc/resolv.conf"
    cat /etc/resolv.conf > "$temp/etc/resolv.conf"

    cp "overlays/base/etc/pacman.conf" "$temp/etc/pacman.conf"

    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' "$temp/etc/locale.gen"

    echo "${hostname:-danctnix}" > "$temp/etc/hostname"

    # Download our gpg key and install it first, this however will be overwritten with our package later.
    curl https://raw.githubusercontent.com/dreemurrs-embedded/danctnix-packages/master/danctnix/danctnix-keyring/danctnix.gpg \
        -o "$temp/usr/share/pacman/keyrings/danctnix.gpg"
    curl https://raw.githubusercontent.com/dreemurrs-embedded/danctnix-packages/master/danctnix/danctnix-keyring/danctnix-trusted \
        -o "$temp/usr/share/pacman/keyrings/danctnix-trusted"
    curl https://raw.githubusercontent.com/catacombing/packaging/master/arch/catacomb-keyring/catacomb.gpg \
        -o "$temp/usr/share/pacman/keyrings/catacomb.gpg"
    curl https://raw.githubusercontent.com/catacombing/packaging/master/arch/catacomb-keyring/catacomb-trusted \
        -o "$temp/usr/share/pacman/keyrings/catacomb-trusted"

    cat > "$temp/second-phase" <<EOF
#!/bin/bash
set -e
pacman-key --init
pacman-key --populate archlinuxarm danctnix catacomb
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
pacman-key --lsign-key 733163AA31950B7F4BE7EC4082CE6C29C7797E04
pacman -Rsn --noconfirm linux-$arch
pacman -Syu --noconfirm --overwrite=*
pacman -S --noconfirm --overwrite=* --needed ${packages_device[@]}


systemctl disable sshd
systemctl disable systemd-networkd
systemctl disable systemd-resolved
systemctl enable zramswap
systemctl enable NetworkManager

groupadd catacomb
useradd -m -G network,video,audio,rfkill,wheel,catacomb alarm

cp -rv /etc/skel/. /home/alarm
chown -R alarm:alarm /home/alarm

if [ -e /etc/sudoers ]; then
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

cat << FOE | passwd alarm
123456
123456

FOE

locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -s ../usr/share/zoneinfo/Europe/London /etc/localtime

# remove pacman gnupg keys post generation
rm -rf /etc/pacman.d/gnupg
rm /second-phase
EOF

    chmod +x "$temp/second-phase"
    do_chroot /second-phase || error "Failed to run the second phase rootfs build!"

    cp -r overlays/base/* "$temp/"

    sed -i "s/REPLACEDATE/$date/g" "$temp/usr/local/sbin/first_time_setup.sh"

    do_chroot passwd -dl root

    [ -d "$temp/usr/share/glib-2.0/schemas" ] && do_chroot /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
    do_chroot mkinitcpio -P

    unmount_cache
    yes | do_chroot pacman -Scc

    unmount_chroot

    echo "Creating base image tarball: $rootfs_tarball ..."
    pushd .
    cd $temp && bsdtar -czpf ../$rootfs_tarball .
    popd
}

add_packages() {
    packages_md5=$(printf "$packages" | md5sum | awk '{print $1}')
    danctnix_tarball="packaged-$device-$rootfs_md5-$packages_md5.tar.gz"
    sizefile="$danctnix_tarball.size"

    # Short-circuit if image tarball is up to date.
    if [ -f "$output_folder/$danctnix_tarball" ]; then
        echo "Using cached packages rootfs $output_folder/$danctnix_tarball"
        return;
    fi

    # Ensure tempdir is clean.
    rm -rf $temp
    mkdir -p $temp

    # Recover existing rootfs.
    echo "Extracting base image tarball…"
    bsdtar -xpf "$output_folder/$rootfs_tarball" -C "$temp"

    echo "Installing additional packages…"

    mount_chroot
    mount_cache

    cat > "$temp/add_packages" <<EOF
#!/bin/bash
set -e
pacman-key --init
pacman-key --populate archlinuxarm danctnix catacomb
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
pacman-key --lsign-key 733163AA31950B7F4BE7EC4082CE6C29C7797E04
pacman -Syu --noconfirm --overwrite=*
pacman -S --noconfirm --overwrite=* --needed ${packages[@]}

$(echo -e "${postinstall[@]}")

# remove pacman gnupg keys post generation
rm -rf /etc/pacman.d/gnupg
rm /add_packages
EOF

    chmod +x "$temp/add_packages"
    do_chroot /add_packages || error "Failed to add packages to rootfs!"

    unmount_cache
    yes | do_chroot pacman -Scc

    unmount_chroot

    # Cache rootfs size with 20% margin for future image creation.
    imgsize=$(( $(du -bs $temp | awk '{print $1}') * 12 / 10 ))
    printf "$imgsize" > "$output_folder/$sizefile"
    echo "Cached uncompressed image size: $imgsize"

    echo "Creating image tarball: $danctnix_tarball ..."
    pushd .
    cd $temp && bsdtar -czpf ../$danctnix_tarball .
    popd
}

make_image() {
    [ ! -e "$output_folder/$danctnix_tarball" ] && \
        error "Image tarball not found! (how did you get here?)"

    tar_file_path="$output_folder/alarm-$device-$rootfs_md5-$packages_md5.tar"
    boot_image="alarm-$device-$rootfs_md5-boot.img"
    root_image="alarm-$device-$rootfs_md5-$packages_md5-root.img"

    # Short-circuit if image is up to date.
    if [ -f "$tar_file_path" ]; then
        echo "Using cached image $tar_file_path"
        return;
    fi

    # Ensure tempdir is clean.
    rm -rf $temp
    mkdir -p $temp

    boot_partition_path=$(mktemp)
    boot_image_path="$output_folder/$boot_image"
    root_image_path="$output_folder/$root_image"

    boot_size="1G"
    root_size=$(cat "$output_folder/$sizefile")

    echo "Creating boot disk image ($boot_size)"
    fallocate -l $boot_size $boot_partition_path
    parted -s $boot_partition_path mktable gpt
    parted -s $boot_partition_path mkpart boot fat32 '0%' '100%'
    parted -s $boot_partition_path set 1 esp on
    boot_loop_device=$(losetup -f)
    losetup -P $boot_loop_device "$boot_partition_path"
    mkfs.vfat -S 4096 -g "4/32" -n "ALARM_BOOT" ${boot_loop_device}p1

    echo "Generating root disk image ($root_size)"
    fallocate -l $root_size $root_image_path
    # TODO: Still getting errors when flashing due to block size
    # error: write_sparse_skip_chunk: don't care size 1350120726 is not a multiple of the block size 4096
    mkfs.ext4 -L "ALARM_ROOT" $root_image_path

    echo "Mounting disk images"
    mount ${root_image_path} $temp
    mkdir -p $temp/boot
    mount ${boot_loop_device}p1 $temp/boot

    echo "Extracting rootfs to mount"
    bsdtar -xpf "$output_folder/$danctnix_tarball" -C "$temp" \
        || error "Failed to extract rootfs to image"

    echo "Generating fstab"
    genfstab -L $temp | grep LABEL | grep -v "swap" | tee -a $temp/etc/fstab

    echo "Updating boot partition"
    mount_chroot
    cat > "$temp/setup_boot" <<EOF
#!/bin/bash
set -e

bootctl install --variables=no

rm /setup_boot
EOF
    chmod +x "$temp/setup_boot"
    do_chroot /setup_boot || error "Failed to update boot partition"

    # Write systemd-boot loader entry.
    cat > "$temp/boot/loader/entries/alarm.conf" << EOF
title ALARM
sort-key ALARM
linux /vmlinuz-linux
initrd /initramfs-linux.img

options quiet root=LABEL=ALARM_ROOT rw
devicetree /dtbs/qcom/qcm6490-fairphone-fp5.dtb
EOF

    # Convert boot partition to non-partitioned boot image.
    # This is necessary since systemd-boot wants a partition.

    echo "Copying boot partition to boot image"

    fallocate -l $boot_size $boot_image_path
    parted -s $boot_image_path mktable gpt
    mkfs.vfat -S 4096 -g "4/32" -n "ALARM_BOOT" ${boot_image_path}

    umount -R $temp
    mkdir $temp/boot_part
    mkdir $temp/boot_file
    mount ${boot_loop_device}p1 $temp/boot_part
    mount ${boot_image_path} $temp/boot_file

    cp -r $temp/boot_part/* $temp/boot_file/

    echo "Unmounting disk image"
    umount $temp/boot_part
    umount $temp/boot_file
    rm -rf $temp
    losetup -d $boot_loop_device
    rm -rf $boot_partition_path

    echo "Compressing images"
    xz -zf "$boot_image_path"
    xz -zf "$root_image_path"

    echo "Taring images"
    tar -cvf "$tar_file_path" -C "$output_folder" "$boot_image.xz" "$root_image.xz"
    rm "$boot_image_path.xz"
    rm "$root_image_path.xz"
}

pre_check
parse_args "$@"
[[ "$arch" && "$device" && "$packages" ]] || usage
check_arch
parse_presets
cleanup_cache
init_rootfs
add_packages
make_image
