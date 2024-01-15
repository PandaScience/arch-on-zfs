# Bootstrap

For automation, simply fill in all required [config
variables](scripts/variables.env) and run [the script](scripts/bootstrap.sh).

## Live system

### VirtualBox

> [!NOTE]
> A vagrant box will not help in this case, since we want to boot from the iso
> instead of booting directly into an already installed system.

In case you don't have a spare disk or device and want to test the approach
first in a virtualized environment, I'd recommend
[VirtualBox](https://www.virtualbox.org/).

Download an [arch iso](https://archlinux.org/download/) and create a new VM
booting from it. Make sure

- Type is set to Linux -> Arch Linux (64-bit)
- Unattended install is disabled
- EFI is enabled
- Hard disk is sufficiently large sized (default 8GB should be safe)

**For convenience:**

After creating the VM go to
`Settings -> Network -> Advanced -> Port Forwarding`
and add an entry of the form

| Name | Protocol | Host IP   | Host Port | Guest IP  | Guest Port |
| ---- | -------- | --------- | --------- | --------- | ---------- |
| SSH  | TCP      | \<empty\> | 5222      | \<empty\> | 22         |

or via commandline:

```
VBoxManage modifyvm <VM_NAME> --natpf1 "SSH,tcp,,5222,,22"
VBoxManage showvminfo <VM_NAME> | grep NIC
```

For ssh access, either set a root password or deploy your keys, e.g.

```
mkdir -m 700 ~/.ssh; curl https://github.com/PandaScience.keys >> ~/.ssh/authorized_keys
```

and remote-login via

```
ssh root@127.0.0.1 -p 5222 -i /path/to/ssh-key \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
```

### Bare Metal

**Skip this when using VirtualBox.**

First we need either a running linux or a live-stick. Although in general you
have the option to install arch from _any_ linux
(see [here](https://wiki.archlinux.org/title/Install_Arch_Linux_from_existing_Linux#From_a_host_running_another_Linux_distribution)),
for our purpose we really need the arch iso because of the kernel-dependency of
the arch-zfs package!

> [!WARNING]
> Only in case you merely want to fix ZFS stuff on an already existing system you
> can also go for ubuntu, since Canonical already ships a ready-2-go openZFS and
> the `arch-chroot` script is available from standard repos:
>
> ```bash
> add-apt-repository universe
> apt install arch-install-scripts
> ```

In any case, simply download the iso file and copy it on a thumb drive

```
dd if=/path/to/archlinux-YYYY.MM.DD-x86_64.iso of=/dev/sdX bs=1M
```

or copy the iso to a [Ventoy](https://www.ventoy.net/en/index.html) drive.

Boot into the iso and make sure to have a working network connection. While
ethernet is usually not an issue, connecting to WiFi most certainly will give
you headaches on terminal-based live systems.

Arch:

```
# list wifi interfaces and available SSIDs
iwctl device list
iwctl station <INTERFACE> scan
iwctl station <INTERFACE> get-networks
iwctl station <INTERFACE> connect <SSID>

# or for ethernet
dhcpcd <INTERFACE>
```

Ubuntu:

```bash
vim /etc/netplan/00-installer-config.yaml
```

```
network:
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  version: 2
  wifis:
    wlp3s0:
      access-points:
        "<SSID>":
          password: "<PASSWORD>"
          dhcp4: true
```

```bash
netplan apply
```

## Disk partitioning

For NVMe M.2 disks the tool

```
pacman -S nvme-cli
nvme list
```

can be useful to find the identifier of the form

```
/dev/disk/by-id/nvme-MODEL_NAME
```

otherwise just go with standard tools like

```
lsblk
```

It's not absolutely essential at this point, but it's nevertheless best
practice to just always use `BY-ID` references when fiddling with ZFS.

For convenience:

```bash
export DISK=/dev/disk/by-id/....
```

Next, we'll create a GPT partition table. This is particularly important for
some server hardware when running on M.2 SSDs with a BIOS that does not support
booting from MBR on such disks!

We need two partitions: the EFI system partition (ESP), which may not be
encrypted, and the future ZFS volume:

```bash
# show type codes
sgdisk -L

# clear disk
sgdisk --zap-all $DISK

# create the two partitions
sgdisk -a1 -n1:1M:+512M -t1:EF00 $DISK
sgdisk -n2:0:0 -t2:BF00 $DISK

# check
parted -l
```

## ZFS Setup

### Install kernel module

For the arch iso there is a
[convenience script](https://github.com/eoli3n/archiso-zfs/) that helps you to
install the ZFS kernel module:

```bash
curl -s https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init | bash
```

### Pool creation

We start with creating a new pool `znew`. First check the blocksize of the disk. Use
the `ashift=12` option except your SSD has 8k sectors in which case you should use
`ashift=13`. Setting this number to 12 (2^12 = 4096) for 512 Byte sector
devices does no harm, though the other way around will result in performance
penalties caused by [write amplification](https://en.wikipedia.org/wiki/Write_amplification).

For any kind of SSD you also want to set the `autotrim` option.

**Note:** Some _file system_ properties should be apply globally and can be
passed via `-O` option already during pool creation. Regular _pool_ properties
must be set with `-o`.

```bash
zpool create -o ashift=12 -o autotrim=on -o cachefile=/etc/zfs/zpool.cache \
 -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
 -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
 -O mountpoint=none \
 -R /mnt/install \
 znew /dev/disk/by-id/<ID>
```

Pay attention to the `-R /mnt/install` option. All dataset mount points created
later will be prefixed with this path as long as the pool is imported!

> [!WARNING]
> Do not encrypt the pool root! See
> [here](https://www.reddit.com/r/zfs/comments/bnvdco/zol_080_encryption_dont_encrypt_the_pool_root/)
> for details.

### General layout

After working several years with ZFS I found the following structure
for my datasets to fit best for the intended purpose:

| dataset        | content / purpose                                  | backups/snapshots            |
| -------------- | -------------------------------------------------- | ---------------------------- |
| encr           | encrypted top level dataset                        | -                            |
| encr/system    | system data, packages, basically everything in `/` | dedicated policy             |
| encr/userdata  | as in "userdata"                                   | dedicated + recursive policy |
| encr/nobackup  | temporary files and caches                         | none                         |
| encr/\<other\> | virtualization technologies                        | depends                      |

This layout especially allows very simple configuration files for [sanoid and
syncoid](https://github.com/jimsalterjrs/sanoid), our tools of choice for
automated snapshots and remote backups.

A more detailed layout with some example mount points:

```
znew
|_encr
     |_system
     |    |_/
     |
     |_userdata
     |    |_/root
     |    |_/home
     |    |_/home/user/Documents
     |    |_/home/user/Downloads
     |    |_/home/user/Music
     |    |_/home/user/Pictures
     |
     |_nobackup
          |_/var/cache
          |_/var/tmp
          |_/var/log
          |_/home/user/.cache
          |_/home/user/.config/slack
          |_/home/user/.config/chromium/
          |_/home/user/.mozilla
          |
          |_/home/user/VirtualBox
          |_/var/lib/docker (ext4 zvol)

```

### Encryption

> [!TIP]
> Good reads on ZFS-native encryption:
>
> - https://blog.heckel.io/2017/01/08/zfs-encryption-openzfs-zfs-on-linux/
> - https://arstechnica.com/gadgets/2021/06/a-quick-start-guide-to-openzfs-native-encryption/
> - https://openzfs.github.io/openzfs-docs/Getting%20Started/Arch%20Linux/Arch%20Linux%20Root%20on%20ZFS.html

Let's create the encrypted top level dataset. Instead of `-o encrryption=on` we use a better/faster cipher. We also disable mounting explicitly.

```bash
zfs create \
 -o mountpoint=none -o canmount=off \
 -o encryption=aes-256-gcm -o keyformat=passphrase \
 znew/encr
```

**Note:**

- The default option `-o keylocation=prompt` does not need to be set explicitly.
- The aes-256-gcm cipher is default since openZFS >=0.8.4, so setting `-o
encryption=on` is sufficient for newer versions.

### Datasets

Next we create all 2nd level datasets together with their mountable "leaf" children:

**Note:** Mind the order!

```bash
# 2nd level datasets should not be mountable
zfs create -o mountpoint=none -o canmount=off znew/encr/system
zfs create -o mountpoint=none -o canmount=off znew/encr/userdata
zfs create -o mountpoint=none -o canmount=off znew/encr/nobackup

# root system will go here
zfs create -o mountpoint=/ -o canmount=noauto znew/encr/system/ROOT
# setting this property will later be important for the boot loader
zpool set bootfs=znew/encr/system/ROOT znew

# reasonable choices for separating user data with dedicated snapshot options
# and hence the ability to quickly transfer to other systems if required
zfs create -o mountpoint=/root                znew/encr/userdata/ROOTHOME
zfs create -o mountpoint=/home                znew/encr/userdata/HOME
zfs create -o mountpoint=/home/user/Documents znew/encr/userdata/DOCUMENTS
zfs create -o mountpoint=/home/user/Downloads znew/encr/userdata/DOWNLOADS
zfs create -o mountpoint=/home/user/Music     znew/encr/userdata/MUSIC
zfs create -o mountpoint=/home/user/Pictures  znew/encr/userdata/PICTURES

# system caches and temp folders -> no need to backup those
zfs create -o mountpoint=/var/cache znew/encr/nobackup/VARCACHE
zfs create -o mountpoint=/var/tmp   znew/encr/nobackup/VARTMP
zfs create -o mountpoint=/var/log   znew/encr/nobackup/VARLOG

# user caches and other frequently changing application data without backup
zfs create -o mountpoint=/home/user/.cache             znew/encr/nobackup/DOTCACHE
zfs create -o mountpoint=/home/user/.config/slack      znew/encr/nobackup/SLACK
zfs create -o mountpoint=/home/user/.local/share/Steam znew/encr/nobackup/STEAM
zfs create -o mountpoint=/home/user/.config/chromium   znew/encr/nobackup/CHROMIUM
zfs create -o mountpoint=/home/user/.mozilla           znew/encr/nobackup/MOZILLA

# dedicated dataset for VirtualBox VMs (use VB-native snapshotting if required)
zfs create -o mountpoint=/opt/VirtualBox znew/encr/nobackup/VIRTUALBOX

# ext4-formatted ZVOL to be able to utilize the overlay2 storage driver
zfs create -s -V 250G znew/encr/nobackup/DOCKER
```

For more information on how to identify potential dataset mount paths for
locations polluting other datasets, see [this section](#identifying-potential-datasets).

> [!NOTE]
>
> - mount points are always specified relative to the zpool's `-R` option (if set), here: `/mnt/install`
> - for better visual distinguishability I like to use CAPS for all mountable "leaf datasets"
> - datasets will inherit compression properties etc. from zpool - but apparently not mount options

Export and re-import the pool to check if everything works fine. Remember to
always use `BY-ID` references as they will be stored in the cachefile.

```bash
zpool export znew
# import w/o mounting
zpool import -d /dev/disk/by-id -R /mnt/install -N znew
# load encryption key and mount root
zfs mount -l znew/encr/system/ROOT
# mount remaining datasets
zfs mount -a
```

> [!IMPORTANT]
>
> - You cannot simply use `zpool import [...] -l znew` because of `canmount=noauto` on `/`
> - The `-N` option tells `zfs` to not mount anything on import
> - The `-l` option tells `zfs` to load a password-protected key.
> - The order is important here: First mount the encrypted root such that all
>   other mount points are created within the dataset instead of the live-system!

## EFI

From the live system, first create the mount point, format the previously
generated EFI partition and mount it:

> [!TIP]
> For non-zfs mounts, it's not essential to use a `/dev/disk/by-id/` path!

```bash
mkfs.fat -F32 /dev/sdxY
mount --mkdir /dev/sdX1 /mnt/install/boot
```

The EFI partition must be formatted as FAT32.

Also make sure to use
`<POOL-MOUNTPOINT>/boot` as mount point, since `mkinitcpio` will copy
generated kernels and initramfs there, which would otherwise reside on the ZFS
partition and not be available at boot time.

We need to create a fstab entry for the boot partition. Best practice is to use
the UUID here:

```bash
mkdir /mnt/install/etc
genfstab -U -p /mnt/install > /mnt/install/etc/fstab
```

This will also create entries for some ZFS datasets. If you do not intend to
use legacy mount points, **remove all entries** except the one for `/boot`.

> [!CAUTION]
> Make sure `znew/system/ROOT` is mounted at `/mnt/install` (check with
> `zfs mount`), otherwise the `genfstab` will fail.

## Install Arch Linux

### Base system

First extract a minimal arch linux operating system and chroot there:

```bash
pacman -S arch-install-scripts
pacstrap -i /mnt/install base base-devel
arch-chroot /mnt/install /bin/bash
```

As long as we have a working network connection install some basic stuff

```bash
pacman -S neovim btop git zsh zsh-completions man-pages man-db [...]
```

If, for convenience, you want to go for `zsh` at this point don't forget to
initialize its autocompletion

```bash
exit  # from current chroot
arch-chroot /mnt/install /bin/zsh
autoload -U compinit && compinit -u
```

### Hostname

Set hostname here (a mere `localhost` entry for the loop back addresses would be
sufficient in fact)

```
vim /etc/hosts
++ 127.0.0.1 <HOSTNAME>.<NETWORK> <HOSTNAME>
++ ::1       <HOSTNAME>.<NETWORK> <HOSTNAME>
```

and here

```
vim /etc/hostname
++ <HOSTNAME>
```

### Users

Set root pw

```
passwd
```

Create regular user, set their default shell and (if desired) grant the wheel
group sudo powers

```bash
# ignore possible warning about already existing home directory
useradd -m -G wheel -s /bin/zsh user
passwd user

EDITOR=vim visudo
-- #%wheel ALL=(ALL:ALL) ALL
++ %wheel ALL=(ALL:ALL) ALL
```

Automatically created mount points for datasets inherit owner and group of their
parent directory during first mount, so fix this for the user's home if
necessary:

```bash
chown -R user:user /home/user
```

### Networking

We use NetworkManager as an example here, which provides `nmtui` for
initial wifi setup later

```bash
pacman -S networkmanager
systemctl enable NetworkManager
```

If you want systemd to take over DNS resolving

```
systemctl enable systemd-resolved.service
```

Some more firmware for network cards etc.

```bash
pacman -S linux-firmware
```

### Locale and time

Generate and set locale

```bash
vim /etc/locale.gen
# -> uncomment all you want to use, e.g. "en_US.UTF-8 UTF-8"
locale-gen
```

**Note:** If the following is not set, Unicode characters will not work!

```bash
vim /etc/locale.conf # should be a new file
++ LANG=en_US.UTF-8
```

Set timezone and clock

```bash
ln -s /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc --utc
```

### ZFS kernel module

Configure openZFS repo

```bash
vim /etc/pacman.conf
++ [archzfs]
++ Server = http://archzfs.com/$repo/x86_64
```

and install kernel module

```bash
pacman -S archzfs-linux
```

```bash
# in case you want the LTS kernel as well
pacman -S linux-lts
pacman -S zfs-linux-lts
```

You can safely choose `mkinitcpio` as provider in the prompt.

---

**Note:** Depending on the build state of the archzfs package and the current
repo kernel version you cannot install the package because of dependency
mismatch `cannot resolve "linux=<version>", a dependency of "zfs-linux"`.
In that case you need to downgrade the kernel to the required version by
copying the matching link from the [archlinux archive](https://archive.archlinux.org/packages/l/linux/)
(see also [arch docs](https://wiki.archlinux.org/title/Downgrading_packages#Finding_Your_Older_Version))
and run

```
pacman -U https://archive.archlinux.org/packages/l/linux/linux-<version>-x86_64.pkg.tar.zst
```

---

We're ready to build the initial ramdisk. First check which hooks you want to
have included

```bash
mkinitcpio -L
mkinitcpio -H <MODULE>
```

then adapt the config file (adapt to your preference, but make sure `zfs` is
included)

```bash
vim /etc/mkinitcpio.conf
++ HOOKS="(base udev autodetect modconf kms keyboard keymap consolefont block zfs filesystems)"
```

For root on ZFS we also need to bake the hostid into the initial ramdisk

```bash
zgenhostid $(hostid)
```

and start the build

```bash
mkinitcpio -p linux
```

> [!TIP]
> Leave out the `fsck` hook to prevent this error during boot:
> `ERROR device ZFS=znew/encr/system/ROOT not found. Skipping fsck during boot`.

### ZFS services

Copy over the live system's cache into the arch installation (run this
from outside the chroot environment):

```bash
mkdir -p /mnt/install/etc/zfs
# regenerate cache file if empty or does not exist yet
zpool set cachefile=/etc/zfs/zpool.cache znew
cp /etc/zfs/zpool.cache /mnt/install/etc/zfs/
```

We want ZFS to auto-import our zpool and auto-mount all mountable datasets
during boot.

```bash
arch-chroot /mnt/install /bin/bash
```

```bash
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target
```

Regenerate the initial ramdisk

```
mkinitcpio -p linux
```

### Bootloader

We use [rEFInd](https://www.rodsbooks.com/refind/configfile.html) as bootloader.
It's quite minimal and looks gorgeous when themed :wink:.

```bash
pacman -S refind
refind-install # should auto-detect EFI partition mounted in /boot
```

> [!WARNING]
> Running `refind-install` from chroot will mount the EFI partition to `/boot`
> again. While it's not harmful, you need to keep it in mind for later and when
> automating things.

Depending on your CPU type, also install the proper microcode package

```bash
pacman -S intel-ucode
pacman -S amd-ucode
```

Unfortunately, rEFInd cannot recognize arch@zfs to use the correct icon, so
help out by giving the boot partition a name

```
pacman -S parted
parted
```

```
(parted) print list
(parted) name 1 'arch'
(parted) quit
```

Also create a pacman hook for proper upgrading
(see https://wiki.archlinux.org/title/REFInd#Upgrading):

```bash
mkdir /etc/pacman.d/hooks
vim /etc/pacman.d/hooks/refind.hook
```

```
[Trigger]
Operation=Upgrade
Type=Package
Target=refind

[Action]
Description = Updating rEFInd on ESP
When=PostTransaction
Exec=/usr/bin/refind-install
```

We utilize the kernel auto-detection and hence only put a minimal configuration
in `/boot/refind_linux.conf` instead of the full-blown stuff that goes into
`/boot/EFI/refind/refind.conf`. The `PARTUUID` can be found with `blkid` and
needs to be set to the one of EFI partition, not the ZFS one!

```
"Boot using default options"     "root=PARTUUID=<UUID-EFI-PARTITION> rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v.img"
"Boot using fallback initramfs"  "root=PARTUUID=<UUID-EFI-PARTITION> rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v-fallback.img"
"Boot to terminal"               "root=PARTUUID=<UUID-EFI-PARTITION> rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v.img systemd.unit=multi-user.target"
"Boot in single user mode"       "root=PARTUUID=<UUID-EFI-PARTITION> rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v.img single"
```

> [!NOTE]
> Microcode updates need to be activated manually since kernel 3.17, so
> don't miss the `initrd=*-ucode.img` part! (although it would not stop rEFInd
> from booting properly...)

When using multiple kernels you need to put at least the following in
the general configuration file in `/boot/EFI/refind/refind.conf`
(see https://wiki.archlinux.org/title/REFInd#Configuration)

```
# required for multiple arch kernels; keep the order!
extra_kernel_version_strings linux-hardened,linux-zen,linux-lts,linux
```

and optionally

```
timeout 10
use_nvram false
default_selection "+, vmlinuz-linux from arch, vmlinuz-linux-lts from arch"
fold_linux_kernels false
scanfor internal,external,biosexternal,optical,manual

include themes/<THEME>/theme.conf
```

## Finalize

That's it. Before rebooting, we need to manually unmount the boot partition
first

```bash
exit  # from chroot
umount /mnt/install/boot # possibly need to run this twice, check with `mount`
```

while all (non-legacy) ZFS datasets mount points will be automatically
taken care of when exporting the pool

```bash
zpool export znew
```

After rebooting, the ZFS hook will recognize the encrypted root dataset and
should prompt you for the password, then the systemd services will take care
of mounting all datasets.

If everything worked as expected, you should now have a running arch linux on
openZFS, congratulations!

## Misc

### Scrub and trim

Although we've already set the `autotrim` option for the pool, the recommended
approach is to also run a manual `trim` occasionally. Scrubbing always needs to
be run manually.

Let's set up a cronjob for each.

```bash
pacman -S cronie
systemctl enable cronie.service
```

```bash
EDITOR=nvim crontab -e
```

```bash
00  7 * * 1,3,5 zpool scrub znew
00 12 * * 1,3,5 zpool trim  znew
```

### Delete pacman cache periodically

Periodically clean pacman cache, defaults to `k=3` when only using `-r`

```
pacman -S pacman-contrib
systemctl enable paccache.timer

# check how much space is taken by cache
du -sh /var/cache/pacman/pkg

# test run
paccache -dk2

# remove all packages except latest 2 versions
paccache -vrk2

# remove all versions of already uninstalled packages
paccache -ruk0
```

Add cronjob

```
00 14 * * 0,2,4 paccache -rk2
```

### ZRAM Swap

Basically follow https://wiki.archlinux.org/title/Zram.

Disable ZSWAP feature in rEFInd via kernel parameter "zswap.enabled=0" like so:

```
"Boot using default options"     "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v.img"
"Boot using fallback initramfs"  "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v-fallback.img"
"Boot to terminal"               "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v.img systemd.unit=multi-user.target"
"Boot in single user mode"       "root=${PARTUUID} rw add_efi_memmap zfs=bootfs zswap.enabled=0 initrd=amd-ucode.img initrd=initramfs-%v.img single"
```

Install and configure ZRAM

```bash
pacman -S zram-generator
```

```bash
/etc/systemd/zram-generator.conf
---
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
```

```bash
/etc/sysctl.d/99-vm-zram-parameters.conf
---
# https://wiki.archlinux.org/title/Zram#Optimizing_swap_on_zram
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
```

Start (static) service (i.e. automatically enabled as long as file/symlink exists)

```bash
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service
```

Check statistics with

```bash
zramctl
```

### SWAP on ZFS

> [!CAUTION]
> There is an [unresolved issue](https://github.com/openzfs/zfs/issues/7734)
> with swap on ZFS which can potentially cause a deadlock, see
>
> - https://wiki.archlinux.org/title/ZFS#Swap_volume
> - https://github.com/zfsonlinux/pkg-zfs/wiki/HOWTO-use-a-zvol-as-a-swap-device
> - https://github.com/openzfs/zfs/issues/7734
>
> Personally, I've never run into this issue, but if you want to prevent it
> either disable swap altogether or follow [this guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html#step-2-disk-formatting) and create a third partition
> in this step.

Create swap under the encrypted parent dataset:

```
zfs create -V 8G -b $(getconf PAGESIZE) -o compression=zle \
 -o logbias=throughput -o sync=always \
 -o primarycache=metadata -o secondarycache=none \
 -o com.sun:auto-snapshot=false znew/encr/swap
```

enable it

```
mkswap -f /dev/zvol/znew/encr/swap
swapon /dev/zvol/znew/encr/swap
```

and create a persistent mount for it

```
vim /etc/fstab
++ /dev/zvol/znew/encr/swap none swap discard 0 0
```

### Identifying potential datasets

Generally speaking, you should give dedicated datasets to all locations with
frequently changing data to prevent polluting snapshots of more
important data. For instance, Slack data is cloud-stored anyways, but will
create huge caches during its use, so no need to have this in the same dataset
under version control as e.g. your home folder. Same goes for firefox or
chromium caches.

Given two snapshots of the same dataset, you can run

```
zfs diff <dataset>@<snapshot1> <dataset>@<snapshot2>
```

in order to analyze which files have changed. You can check how much space is
actually taken by each snapshot, run

```
zfs list -t snapshot <dataset>
```

and check the `USED` column.

## Troubleshooting

### Corrupted cachefile

If you receive a `invalid or corrupt cache file contents` during first boot,
something went wrong during bootstrap. Boot into the arch ISO again and
follow these steps precisely:

1. Prepare system

   ```
   curl -s https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init | bash
   pacman -S arch-install-scripts
   ```

2. Mount zpool, datasets and boot

   ```
   zpool import -d /dev/disk/by-id -R /mnt/install -N
   zfs mount -l znew/encr/system/ROOT
   zfs mount -a
   mount /dev/sda1 /mnt/install/boot
   ```

3. Recreate cache and copy over

   ```
   rm /etc/zfs/zpool.cache
   zpool set cachefile=/etc/zfs/zpool.cache znew
   cp /etc/zfs/zpool.cache /mnt/install/etc/zfs/zpool.cache
   ```

4. Chroot, regenerate hostid and rebuild initramfs

   ```
   arch-chroot /mnt/install /bin/bash
   rm /etc/hostid
   zgenhostid $(hostid)
   mkinitcpio -p linux
   ```

5. Reboot
   ```
   umount /dev/sda1
   zfs export -a
   reboot
   ```

If nothing helps, you can also disable the cache by removing the
`-c <cachefile>` part in
`/mnt/install/usr/lib/systemd/system/zfs-import-cache.service`.
