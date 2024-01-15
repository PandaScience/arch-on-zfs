#!/bin/bash
# $1 -> user name
# $2 -> pool name

set -e

if [ -z "$1" ]; then
	echo "ERROR: need to pass username as 1st argument!"
	exit 1
elif [ -z "$2" ]; then
	echo "ERROR: need to pass ZFS pool as 2nd argument!"
	exit 1
else
	user="$1"
	pool="$2"
	encr="${pool}/encr"
	system="${encr}/system"
	userdata="${encr}/userdata"
	nobackup="${encr}/nobackup"
fi

set -euo pipefail

# encrypted root dataset
until zfs create \
 -o mountpoint=none -o canmount=off \
 -o encryption=aes-256-gcm -o keyformat=passphrase \
 "${encr}"; do
	echo "Please choose another password"
done

# 2nd level datasets; should not be mountable
zfs create -o mountpoint=none -o canmount=off "${system}"
zfs create -o mountpoint=none -o canmount=off "${userdata}"
zfs create -o mountpoint=none -o canmount=off "${nobackup}"

# root system will go here
zfs create -o mountpoint=/ -o canmount=noauto "${system}"/ROOT
# setting this property will later be important for the boot loader
zpool set bootfs="${system}"/ROOT "${pool}"

# other package manager
zfs create -o mountpoint=/var/lib/flatpak "${system}"/FLATPAK

# user data
zfs create -o mountpoint=/root                     "${userdata}"/ROOTHOME
zfs create -o mountpoint=/home                     "${userdata}"/HOME
zfs create -o mountpoint=/home/"${user}"/Cello     "${userdata}"/CELLO
zfs create -o mountpoint=/home/"${user}"/Documents "${userdata}"/DOCUMENTS
zfs create -o mountpoint=/home/"${user}"/Downloads "${userdata}"/DOWNLOADS
zfs create -o mountpoint=/home/"${user}"/Music     "${userdata}"/MUSIC
zfs create -o mountpoint=/home/"${user}"/Pictures  "${userdata}"/PICTURES

# system caches and temp folders -> no need to backup those
zfs create -o mountpoint=/var/cache "${nobackup}"/VARCACHE
zfs create -o mountpoint=/var/tmp   "${nobackup}"/VARTMP
zfs create -o mountpoint=/var/log   "${nobackup}"/VARLOG

# user caches and other frequently changing application data without backup
zfs create -o mountpoint=/home/"${user}"/.cache             "${nobackup}"/DOTCACHE
zfs create -o mountpoint=/home/"${user}"/.config/slack      "${nobackup}"/SLACK
zfs create -o mountpoint=/home/"${user}"/.local/share/Steam "${nobackup}"/STEAM
zfs create -o mountpoint=/home/"${user}"/.config/chromium   "${nobackup}"/CHROMIUM
zfs create -o mountpoint=/home/"${user}"/.mozilla           "${nobackup}"/MOZILLA

# scratch directory
zfs create -o mountpoint=/scratch "${nobackup}"/SCRATCH

# dedicated dataset for VirtualBox VMs (use VB-native snapshotting if required)
zfs create -o mountpoint=/home/"${user}"/VirtualBox       "${nobackup}"/VIRTUALBOX
zfs create -o mountpoint=/home/"${user}"/VirtualBox/share "${userdata}"/VBOXSHARE

# podman/OCI container data paths
zfs create -o mountpoint=/var/lib/containers                     "${nobackup}"/OCI_ROOT
zfs create -o mountpoint=/home/"${user}"/.local/share/containers "${nobackup}"/OCI_USER

# local k8s clusters
zfs create -o mountpoint=/opt/k3d "${nobackup}"/K3D
