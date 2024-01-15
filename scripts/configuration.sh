#!/bin/bash
set -euo pipefail

RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
NOCOL=$(tput sgr0)


info() {
	echo "${CYAN}=== ${1}${NOCOL}"
}

note() {
	echo "${YELLOW}=== ${1}${NOCOL}"
}

err() {
	echo "${RED}>> ${1}${NOCOL}"
}

if [ "$(id -u)" -eq 0 ]; then
	echo "Run this script as user, not as root!"
	exit 0
fi

until ping 8.8.8.8 -c1 > /dev/null; do
	err "No internet connection. Setting up WiFi network..."
	info "Setting up network"
	nmcli radio wifi on
	nmcli dev wifi list
	read -erp "Select SSID: " SSID
	nmcli --ask dev wifi connect "${SSID}"
	sleep 1s
done

info "Installing AUR helper"
if pacman -Qi yay > /dev/null 2>&1; then
	note "...yay already installed, skipping..."
else
	sudo pacman -qS --noconfirm --needed git base-devel
	git clone https://aur.archlinux.org/yay.git
	cd yay
	makepkg -si --noconfirm
	cd "${HOME}" && rm -f yay
	yay --editmenu --diffmenu --save
fi

printf "\n\n"
info "Preparing system configuration tool"
if [ -d "${HOME}/.config/aconfmgr" ]; then
	note "...aconfmgr already installed, skipping..."
else
	yay -S --noconfirm aconfmgr-git
	git -C ~/.config clone -b test https://github.com/PandaScience/aconfmgr.git
	aconfmgr save
fi

printf "\n\n"
info "Installing dotfiles"
if pacman -Qi yadm > /dev/null; then
	note "...yadm already installed, skipping..."
else
	sudo pacman -qS --noconfirm yadm
	yadm clone -b test https://github.com/PandaScience/dotfiles.git
	# BUG: yadm stages all files as deleted after initial cloning, so reset HEAD
	yadm reset --hard HEAD
fi

info "Installing neovim config"
if [ -d "${HOME}/.config/nvim" ]; then
	note "...neovim config already installed, skipping..."
else
	sudo pacman -qS --noconfirm --needed neovim
	git -C ~/.config clone -b test https://github.com/PandaScience/nvim.git
fi

printf "\n\n"
note "You probably want to further configure yadm using these commands"
cat << EOF
    # set class
    yadm config local.class "work"

    # override ~/.gitconfig values for yadm
    yadm gitconfig user.name "René Wirnata"
    yadm gitconfig user.email "rene.wirnata@pandascience.net"
    yadm gitconfig user.signingkey 'EA3F95ACC23878850B7A4BAC3CED6B58A364B115!'
EOF

printf "\n"
note "You want to check ~/.conf/aconfmgr/99-unsorted.sh now and subsequently run:"
echo "    > aconfmgr apply"
