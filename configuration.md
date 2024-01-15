# Configuration

For automation, the following tools are used:

| Purpose              | Tool                                                |
| -------------------- | --------------------------------------------------- |
| system configuration | [aconfmgr](https://github.com/CyberShadow/aconfmgr) |
| dotfiles             | [yadm](https://yadm.io/)                            |
| neovim               | [git repo](https://github.com/PandaScience/nvim)    |

Installing these tools should leave you with a fully working system incl. the
backup configuration explained in the [backup walk-through](backup.md).

## Preparation

### NetworkManager CLI

If required to connect to a WiFi w/o UI:

```
# https://www.makeuseof.com/connect-to-wifi-with-nmcli/
nmcli radio wifi
nmcli dev wifi list
nmcli --ask dev wifi connect <SSID>
```

### Firmware updates

In case some hardware supports firmware updates through the [Linux Vendor
firmware Service (LVFS)](https://fwupd.org/):

```bash
# for details check https://wiki.archlinux.org/title/fwupd
pacman -S fwupd
pacman -S udisks2  # required for correct EFI detection
fwupdmgr refresh
fwupdmgr get-updates
fwupdmgr update
```

### AUR helper

Install [yay](https://github.com/Jguer/yay)

```
pacman -S --needed git base-devel
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si
cd ../ && rm -r yay
```

Configuration:

```
yay --editmenu --diffmenu --save --aur
```

Periodically clear cache

```
00 14 * * 0,2,4 yay -Sc --aur --noconfirm
```

## Configuration Tools

### System configuration

Install [aconfmgr](https://github.com/CyberShadow/aconfmgr)

```
yay -S aconfmgr-git
git -C ~/.config clone https://github.com/PandaScience/aconfmgr.git
```

Run

```
aconfmgr save
```

and check differences between current system and repo in
`~/.conf/aconfmgr/99-unsorted.sh`, remove lines as necessary and subsequently
apply the configuration with

```
aconfmgr apply
```

It might make sense to clean the `99-unsorted.sh` file in multiple iterations.

### Dotfiles

Install and setup [yadm](https://yadm.io/)

```
sudo pacman -S yadm
yadm clone -b test git@github.com:PandaScience/dotfiles.git
yadm config local.class work
```

Optionally override `~/.gitconfig` values for yadm

```
yadm gitconfig user.name "<name>"
yadm gitconfig user.email "<email>"
yadm gitconfig user.signingkey '<key>!' # use single quotes in zsh
```

When using a subkey for signing, make sure to add a trailing exclamation mark
and in zsh use single quotes or escape the exclamation mark in double quotes.

### Neovim

Simply clone the repo into the correct path

```
sudo pacman -S neovim
git -C ~/.config -b test clone https://github.com/PandaScience/nvim.git
```

## Manual steps

Some settings cannot be saved in form of configuration as code.

### Hyprland plugins

```bash
hyprpm update
hyprpm add https://github.com/VortexCoyote/hyprfocus
hyprpm add https://github.com/outfoxxed/hy3
hyprpm enable hyprfocus
hyprpm enable hy3
```

### Brillo

```bash
sudo usermod -aG video <user>
```

### Slack

Log into workspaces

### Music Player Daemon

```
systemctl --user enable mpd.service
```

### Docker

> [!IMPORTANT]
> This workaround is not required for podman, which by default uses the
> `podman overlay` storage driver.
> See also here: https://docs.oracle.com/en/operating-systems/oracle-linux/podman/podman-ConfiguringStorageforPodman.html#configuring-podman-storage

> [!NOTE]
> Docker runs most performant on the `overlay2` storage driver, which is
> incompatible with a ZFS filesystem. Running it on the ZFS backend can be
> quite slow, see https://github.com/k3s-io/k3s/issues/66#issuecomment-520183720 .

Workaround for running docker with `overlay2` on openZFS:

1. Create a sparse ZFS volume and format it to ext4

   ```
   zfs create -s -V 250G zroot/encr/DOCKER
   mkfs.ext4 /dev/zvol/zroot/encr/DOCKER
   ```

2. Automount it to the docker root directory

   ```
   # add in fstab
   /dev/zvol/zroot/encr/nobackup/DOCKER /var/lib/docker ext4 defaults 0 0
   ```

3. Install docker, start the service and check which storage driver is in use

   ```
   sudo pacman -S docker
   sudo systemctl enable --now docker.service
   sudo docker info | grep Storage
   ```

If docker was already installed and ZFS is used as storage driver, adapt or
create `/etc/docker/daemon.json` and add:

```json
{
  "storage-driver": "overlay2"
}
```
