#!/bin/bash
# restart script from specific line:
#   > bash <(sed '/^#START/,/^#STOP/d' bootstrap.sh)
# for restarts you may need to clear the ZFS labels:
#   > zpool labelclear -f ${PART_ZFS}

RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
NOCOL=$(tput sgr0)

info() {
	echo "${CYAN}=== ${1}${NOCOL}"
}

prompt() {
	echo "${YELLOW}${1}${NOCOL}"
}

err() {
	echo "${RED}>> ${1}${NOCOL}"
}

set -euo pipefail

#LIVESYSTEM

fail() {
	err "Script failed. Please restart. Trying to destroy zpool..."
	umount /mnt/install/boot || true
	zpool import "${POOLNAME}" || true
	zpool destroy "${POOLNAME}" || true
}
trap fail ERR

source variables.env

if [ -z "${POOLNAME}" ]; then
	err "You need to set POOLNAME in variables.env !"; exit
elif [ -z "${HOSTNAME}" ]; then
	err "You need to set HOSTNAME in variables.env !"; exit
elif [ -z "${USERNAME}" ]; then
	err "You need to set USERNAME in variables.env !"; exit
fi

until ping 8.8.8.8 -c1 > /dev/null; do
	err "No internet connection. Setting up WiFi network..."
	info "Setting up network"
	iwctl device list
	read -erp "Select interface: " -i "wlan0" WIFI_DEVICE
	iwctl station "${WIFI_DEVICE}" scan
	iwctl station "${WIFI_DEVICE}" get-networks
	read -erp "Select SSID: " SSID
	iwctl station "${WIFI_DEVICE}" connect "${SSID}"
	sleep 1s
done

info "Updating package sources"
timedatectl
pacman -qSy

info "Partitioning disk"
sgdisk --zap-all "${DISK}"
sgdisk -a1 -n1:1M:+2G -t1:EF00 "${DISK}"
sgdisk -n2:0:0 -t2:BF00 "${DISK}"

info "Installing openZFS kernel module"
curl -s https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init | bash

info "Creating pool"
zpool create \
 -o ashift=12 -o autotrim=on -o cachefile=/etc/zfs/zpool.cache \
 -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
 -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
 -O mountpoint=none \
 -R /mnt/install "${POOLNAME}" "${PART_ZFS}"

info "Creating datasets"
bash create_datasets.sh "${USERNAME}" "${POOLNAME}"

info "Copy over ZFS cache"
zpool set cachefile=/etc/zfs/zpool.cache "${POOLNAME}"
mkdir -p /mnt/install/etc/zfs
cp /etc/zfs/zpool.cache /mnt/install/etc/zfs/

info "Export and re-import pool"
zpool export "${POOLNAME}"
zpool import -d /dev/disk/by-id -R /mnt/install -N "${POOLNAME}"
info "Load encryption key and mount datasets in correct order"
zfs mount -l "${POOLNAME}"/encr/system/ROOT
zfs mount -a

info "Prepare EFI partition"
mkfs.fat -F32 "${PART_EFI}"
mount --mkdir "${PART_EFI}" /mnt/install/boot
mkdir /mnt/install/etc
genfstab -U -p /mnt/install | grep "/boot" > /mnt/install/etc/fstab

info "Bootstrap base system"
pacman -qS --noconfirm arch-install-scripts
pacstrap /mnt/install base base-devel

info "Create 2nd part of script and run in chroot env"
cat ./variables.env > /mnt/install/chroot.sh
sed '/^#LIVESYSTEM/,/^#CHROOT/d' "$0" >> /mnt/install/chroot.sh
chmod +x /mnt/install/chroot.sh
arch-chroot /mnt/install ./chroot.sh
rm /mnt/install/chroot.sh

#---

info "Finalize"
umount /mnt/install/boot
zpool export "${POOLNAME}"

info "Finished. Rebooting in 5 seconds..."
sleep 5
reboot




#CHROOT
info "Installing basic packages"
pacman -qS --noconfirm neovim git wget curl zsh man-pages man-db bat eza broot ripgrep btop fd

prompt "Set root password"
until passwd; do
	err "Please try again"
done

info "Create regular user >${USERNAME}< and set password:"
useradd -m -G wheel -s /bin/zsh "${USERNAME}"
prompt "Set user password"
until passwd "${USERNAME}"; do
	err "Please try again"
done

info "Enable sudo for wheel group"
# https://stackoverflow.com/a/27355109
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

info "Fix ZFS dataset mountpoint permissions"
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"

info "Set up networking"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<- "EOF"
	127.0.0.1   localhost
	::1         localhost
EOF
pacman -qS --noconfirm networkmanager linux-firmware
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service

info "Configure locale and time"
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
locale-gen
ln -s /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc --utc

info "Install ZFS kernel module and enable services"
cat >> /etc/pacman.conf <<- "EOF"
	[archzfs]
	Server = http://archzfs.com/$repo/x86_64
EOF
if [ ! -z ${KERNEL_VERSION+x} ]; then
	info "Downgrading linux kernel"
	pacman --noconfirm -U https://archive.archlinux.org/packages/l/linux/linux-"${KERNEL_VERSION}"-x86_64.pkg.tar.zst
fi
pacman -qS --noconfirm zfs-linux zfs-utils
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target
systemctl enable zfs-zed.service

info "Build initial ramdisk"
HOOKS="(base udev autodetect modconf kms keyboard keymap block zfs filesystems)"
sed -i "s/^HOOKS=.*/HOOKS=${HOOKS}/" /etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(zfs)/' /etc/mkinitcpio.conf
zgenhostid "$(hostid)"
mkinitcpio -p linux

info "Install boot loader"
pacman -qS --noconfirm refind parted
if [ ! -z ${CPU+x} ]; then
	pacman -qS --noconfirm "${CPU}-ucode"
fi
refind-install
# for some reason refind-install mounts /boot again on top of the already
# mounted /mnt/install/boot, so unmount it again
umount /boot
parted "${DISK}" --script name 1 'arch'
PARTUUID=$(blkid | awk '/arch/{print $NF}' | tr -d \")
mkdir /boot/EFI/refind/themes/ || true
git -C /boot/EFI/refind/themes/ clone https://github.com/AliciaTransmuted/rEFInd-chalkboard

mkdir /etc/pacman.d/hooks/ || true
cat > /etc/pacman.d/hooks/refind.hook <<- "EOF"
	[Trigger]
	Operation=Upgrade
	Type=Package
	Target=refind

	[Action]
	Description = Updating rEFInd on ESP
	When=PostTransaction
	Exec=/usr/bin/refind-install
EOF
cat > /boot/refind_linux.conf <<- EOF
	"Boot using default options"     "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=initramfs-%v.img"
	"Boot using fallback initramfs"  "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=initramfs-%v-fallback.img"
	"Boot to terminal"               "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=initramfs-%v.img systemd.unit=multi-user.target"
	"Boot in single user mode"       "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=initramfs-%v.img single"
EOF
cat > /boot/EFI/refind/refind.conf <<- "EOF"
	timeout 10
	use_nvram false
	extra_kernel_version_strings linux-hardened,linux-zen,linux-lts,linux
	default_selection "+, vmlinuz-linux from arch, vmlinuz-linux-lts from arch"
	fold_linux_kernels false
	include themes/rEFInd-chalkboard/theme.conf
EOF

info "Configure ZRAM swap"
pacman -qS --noconfirm zram-generator
cat > /etc/systemd/zram-generator.conf <<- EOF
	[zram0]
	zram-size = ram / 2
	compression-algorithm = zstd
	swap-priority = 100
	fs-type = swap
EOF
cat > /etc/sysctl.d/99-vm-zram-parameters.conf <<- EOF
	# https://wiki.archlinux.org/title/Zram#Optimizing_swap_on_zram
	vm.swappiness = 180
	vm.watermark_boost_factor = 0
	vm.watermark_scale_factor = 125
	vm.page-cluster = 0
EOF

info "Configure cron jobs"
pacman -qS --noconfirm cronie
systemctl enable cronie.service
# don't use quotes for ${POOLNAME} here!
cat > /tmp/cronjobs <<- EOF
	00  7 * * 1,3,5 zpool scrub ${POOLNAME}
	00 12 * * 1,3,5 zpool trim  ${POOLNAME}
	00 14 * * 0,2,4 paccache -rk2
EOF
crontab /tmp/cronjobs

if [ ${SSHD+x} == "yes" ]; then
	info "Setting up SSH server and keys"
	mkdir ~/.ssh || true
	curl -s https://github.com/PandaScience.keys > ~/.ssh/authorized_keys
	pacman -qS --noconfirm openssh
	systemctl enable sshd.service
fi

info "Cloning arch install repo into user home"
runuser -l "${USERNAME}" -c "git clone -b test https://github.com/PandaScience/arch-on-zfs"

exit
