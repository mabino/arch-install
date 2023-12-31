#!/bin/bash

# Set the default configuration file.
CONFIG_FILE="arch-config.conf"
# Set the post-installation script file.
POST_INST="/tmp/post-install.sh"
# Set the post-installation script location.
POST_INST_SRV="/etc/systemd/system/post-install.service"
# Set the CPU vendor.
CPU_VENDOR=$(lscpu 2>/dev/null | awk '/^Vendor ID:/ {print $3}' | tr '[:upper:]' '[:lower:]' | sed 's/^genuine//')

remove_bootentries() {
	entries=$(efibootmgr)
	while IFS= read -r line; do
	if [[ $line == Boot*Linux\ Boot\ Manager* ]]; then
		entry_num=$(echo $line | awk '{print $1}' | sed 's/Boot//' | sed 's/\*//')
		efibootmgr -b $entry_num -B >/dev/null
		echo "Removed Linux Boot Manager entry $entry_num"
	fi
	done <<< "$entries"
}

write_postinst(){
	if [ -e "$POST_INST" ] || [ -e "$POST_INST_SRV" ] ; then
		return 1
	else
		cat > "$root_mount" << EOL
		#!/bin/bash
		touch /tmp/script_ran_once
		# Remove systemd service
		systemctl --no-pager disable post-install.service
		rm /etc/systemd/system/post-install.service
		# Remove script
		rm /tmp/post-install.sh
EOL
		cat > "$root_mount""$POST_INST_SRV" << EOL
		[Unit]
		Description=Run post-install at the next reboot

		[Service]
		Type=oneshot
		ExecStart=/post-install.sh

		[Install]
		WantedBy=default.target
EOL
		arch-chroot "$root_mount" systemctl enable post-install.service
	fi
}

is_root() {
	[ "$(id -u)" -eq 0 ]
	}

ok_net() {
	return 0
	ping -q -c 1 -W 1 archlinux.org > /dev/null 2>&1
	}

ok_cpu() {
	vendor_id=$(lscpu 2>/dev/null | awk '/^Vendor ID:/ {print $3}' | tr '[:upper:]' '[:lower:]' | sed 's/^genuine//')
	case "$vendor_id" in
		"intel" | "amd") return 0 ;;
		*) return 1 ;;
	esac
	}

ok_secureboot() {
	pacman -Sy --noconfirm sbctl
	[[ $(sbctl status) == *"Setup Mode"* && $(sbctl status) == *"Enabled"* ]] 
	}

write_config() {
	if [ -e "$CONFIG_FILE" ] || [ -z "$CPU_VENDOR" ] ; then
		return 1
	fi
	cat > "$CONFIG_FILE" << EOL
	# arch-config.conf
	# Written by the arch-install.sh script.
	target_device="/dev/sda"
	root_mount="/mnt"
	locale="en_US.UTF-8"
	keymap="us"
	timezone="America/New_York"
	hostname="archlinux"
	username="archuser"
	# The user_password was created via 'mkpasswd -m sha-512'.
	# user_password='\$6\$/VBa6GuBiFiBmi6Q\$yNALrCViVtDDNjyGBsDG7IbnNR0Y/Tda5Uz8ToyxXXpw86XuCVAlhXlIvzy1M8O.DWFB6TRCia0hMuAJiXOZy/'
	user_password="changeme"
	crypt_password="password"
	pacstrap_packages=(
		base
		linux
		linux-firmware
		${CPU_VENDOR}-ucode
		vim
		cryptsetup
		util-linux
		e2fsprogs
		dosfstools
		sudo
		networkmanager
		sbctl
	)	
EOL
	}

partition_drive() {
	local partitioning_target=$1
	if [ -z "$partitioning_target" ] || [ ! -b "$partitioning_target" ] ; then
		return 1
	fi
	sgdisk -Z "$partitioning_target"
	sgdisk -n1:0:+512M -t1:ef00 -c1:EFISYSTEM -N2 -t2:8304 -c2:linux "$partitioning_target"
	sleep 5 ; partprobe -s "$partitioning_target" ; sleep 5
	PARTITIONED=0
}

format_partitions() {
	if [ $PARTITIONED ]; then
		sleep 5
		#mkfs.vfat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
		mkfs.vfat -F32 -n EFISYSTEM ${target_device}1
		sleep 5
		#mkfs.btrfs -f -L linux /dev/disk/by-partlabel/linux
		mkfs.btrfs -f -L linux /dev/mapper/linux
	else
		return 1
	fi
}

encrypt_drive() {
	#works
	#cryptsetup luksFormat --type luks2 ${target_device}2
	#testing
	echo -n $crypt_password | cryptsetup luksFormat --batch-mode --type luks2 ${target_device}2
	sleep 5
	#works
	#cryptsetup luksOpen ${target_device}2 linux
	#testing
	echo -n $crypt_password | cryptsetup luksOpen ${target_device}2 linux 
}

mount_partitions() {
	if [ ! -e /mnt/efi ]; then
		#mount /dev/disk/by-partlabel/linux /mnt
		mount /dev/mapper/linux /mnt
		mkdir -p /mnt/efi
		#mount /dev/disk/by-partlabel/EFISYSTEM /mnt/efi
		mount ${target_device}1 /mnt/efi
	else
		return 1
	fi
}

source_config() {
	if [ -e "$CONFIG_FILE" ] ; then
		source "$CONFIG_FILE"
	else
		return 1
	fi
}

update_and_install() {
	if [ ! -z "$root_mount" ] && [ -e "$root_mount" ]; then
		pacstrap -K $root_mount "${pacstrap_packages[@]}"
	else
		return 1
	fi
}

setup_environment() {
	sed -i -e "/^#"locale"/s/^#//" "$root_mount"/etc/locale.gen
	rm "$root_mount"/etc/{machine-id,localtime,hostname,shadow,locale.conf} ||
	systemd-firstboot --root "$root_mount" --keymap="$keymap" --locale="$locale" --locale-messages="$locale" --timezone="$timezone" --hostname="$hostname" --setup-machine-id --welcome=false
	arch-chroot "$root_mount" locale-gen
	echo "quiet rw" > "$root_mount"/etc/kernel/cmdline
	sed -i -e '/^#ALL_config/s/^#//' -e '/^#default_uki/s/^#//' -e '/^#default_options/s/^#//' -e 's/default_image=/#default_image=/g' "$root_mount"/etc/mkinitcpio.d/linux.preset
	sed -i -e 's/base udev/base systemd/g' -e 's/keymap consolefont/sd-vconsole sd-encrypt/g' "$root_mount"/etc/mkinitcpio.conf
	$(grep default_uki "$root_mount"/etc/mkinitcpio.d/linux.preset)
	arch-root "$root_mount" mkdir -p "$(dirname "${default_uki//\"}")"
	systemctl --root "$root_mount" enable systemd-resolved systemd-timesyncd NetworkManager
	systemctl --root "$root_mount" mask systemd-networkd
}

build_uki() {
	mkdir -p /mnt/efi/EFI/Linux
	arch-chroot "$root_mount" mkinitcpio -p linux
	return 0
}

setup_secureboot() {
	echo "Create keys"
	arch-chroot "$root_mount" sbctl create-keys
	echo "Enroll keys"
	chattr -i /sys/firmware/efi/efivars/db-*
	chattr -i /sys/firmware/efi/efivars/KEK-*
	arch-chroot "$root_mount" sbctl enroll-keys -m
	echo "Sign bootloader"
	arch-chroot "$root_mount" sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
	cat > $root_mount/etc/pacman.d/90-sbctl.hook << EOL
	[Trigger]
	Type = Path
	Operation = Install
	Operation = Upgrade
	Operation = Remove
	Target = boot/*
	Target = efi/*
	Target = usr/lib/modules/*/vmlinuz
	Target = usr/lib/initcpio/*
	Target = usr/lib/**/efi/*.efi*
	[Action]
	Description = Signing EFI binaries...
	When = PostTransaction
	Exec = /usr/bin/sbctl sign-all -g
EOL
	
	arch-chroot "$root_mount" sbctl sign -s "${default_uki//\"}"
	#arch-chroot "$root_mount" sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
	arch-chroot "$root_mount" sbctl sign -s /efi/EFI/Linux/arch-linux.efi
	#arch-chroot "$root_mount" sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi
	return 0
}

setup_bootloader() {
	echo "Removing previous bootloader entries."
	remove_bootentries
	echo "Install bootloader"
	arch-chroot "$root_mount" bootctl install --esp-path=/efi
}

create_accounts() {
	arch-chroot "$root_mount" touch /etc/shadow
	arch-chroot "$root_mount" useradd -G wheel -m -p $(openssl passwd -6 -salt $(openssl rand -base64 6) $user_password) $username
	sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' "$root_mount"/etc/sudoers
}

start_install() {
	if ok_net; then
		echo "Network connection is good."
	else
		echo "No network connectivity."
		exit 1
	fi
	if is_root; then
		echo "Running as root."
	else
		echo "This script must be run as root."
		exit 1
	fi
	if ok_secureboot; then
		echo "Secure Boot is in setup mode."
	else
		echo "Secure Boot is not in setup mode.  Restart into firmware to reconfigure Secure Boot (y/n)? "
		read sb_answer
		    if [ "$sb_answer" == "y" ]; then
			echo "Rebooting into firmware."
			systemctl reboot --firmware-setup
		    else
			exit 1
		    fi
	fi
	if write_config; then
		echo "Configuration file $CONFIG_FILE written.  Examine the contents and re-run this script."
		exit 1
	else
		if [ -z "$CPU_VENDOR" ]; then
			echo "Not a supported CPU."
			exit 1
		elif [ -e "$CONFIG_FILE" ]; then
			echo "Configuration file $CONFIG_FILE exists.  Use it for the install (y/n)? "
			read config_answer
			if [ "$config_answer" == "y" ] ; then
				source_config
			else
				echo "Exiting..."
				exit 1
			fi
		fi
	fi
	if partition_drive $target_device; then
		echo "Partitioning drive."
	else
		echo "No valid, specified device targeted for partitioning."
		exit 1
	fi
	if encrypt_drive; then
		echo "Encrypting drive."
	fi	
	if format_partitions; then
		echo "Formatting partitions."
	else
		echo "Error formatting the specified partitions."
		exit 1
	fi
	if mount_partitions; then
		echo "Partitions mounted and ready for installation."
	else
		echo "Error mounting partitions."
		exit 1
	fi
	if update_and_install; then
		echo "Installing base system..."
	else
		echo "Error downloading and installing base system."
		exit 1
	fi
	if setup_environment; then
		echo "Setting up environment..."
	else
		echo "Failed to set up the environment."
		exit 1
	fi
	if build_uki; then
		echo "Building the unified kernel."
	else
		echo "Failed to build the unified kernel."
	fi
	if setup_secureboot; then
		echo "Setting up Secure Boot."
	else
		echo "Failed setting up Secure Boot."
	fi
	if setup_bootloader; then
		echo "Setting up boot loader."
	else
		echo "Failed to set up boot loader."
	fi
	if write_postinst; then
		echo "Writing post-installation script and service."
	else
		echo "Error writing post-installation script and service."
	fi
	if create_accounts; then
		echo "Creating system acccounts and permissions."
	else
		echo "Error creating accounts and setting permissions."
	fi
}

start_install
