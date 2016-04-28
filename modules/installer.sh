#! @shell@
set -e

# Set the PATH.
setPath() {
    local dirs="$1"
    export PATH=/empty
    for i in $dirs; do
        PATH=$PATH:$i/bin
        if test -e $i/sbin; then
            PATH=$PATH:$i/sbin
        fi
    done
}

setPath "@path@"

writeColor() {
  echo -e $3 "\e[40;1;$1m$2\e[0m"
}

informNotOk() {
  writeColor 31 "$1" "$2"
}

informOk() {
  writeColor 32 "$1" "$2"
}

fail() {
    informNotOk "Something went wrong, starting interactive shell..."
    exec setsid @shell@
}

trap 'fail' 0 ERR TERM INT

echo
informOk "<<< NixOS fully automated install >>>"
echo

## Bail out early if /installer is incomplete
if [ ! -d /installer ]; then
    informNotOk "Directory /installer missing"
    exit 1
fi

installImg=/installer/nixos-image
if [ ! -f $installImg ]; then
    informNotOk "$installImg missing"
    exit 1
fi
## Defaults
rootDevice=/dev/sda
useDHCP=yes
if [ -f /installer/config ]; then
    . /installer/config
fi

## At this point, the root fs is mounted r/w and contains
## /dev, /proc, /sys as well as a Nix store with all
## utilities needed to execute this script.
mkdir -m 0755 /dev/shm
mount -t tmpfs -o "rw,nosuid,nodev,size=50%" tmpfs /dev/shm
mkdir -m 0755 -p /dev/pts
mkdir -m 01777 -p /tmp
mkdir -m 0755 -p /var /var/log /var/lib /var/db
mkdir -m 0700 -p /root
chmod 0700 /root

# Create a tmpfs on /run to hold runtime state for programs such as
# udev
mkdir -m 0755 -p /run
mount -t tmpfs -o "mode=0755,size=25%" tmpfs /run
mkdir -m 0755 -p /run/lock


# For backwards compatibility, symlink /var/run to /run, and /var/lock
# to /run/lock.
ln -s /run /var/run
ln -s /run/lock /var/lock

# Load the required kernel modules.
mkdir -p /lib
ln -s @kernel@/lib/modules /lib/modules
for i in @kernelModules@; do
    informOk "loading module $(basename $i)..."
    modprobe $i || true
done


# Create device nodes in /dev.
informOk "running udev..."
mkdir -p /etc/udev
touch /etc/udev/hwdb.bin
ln -sfn @systemd@/lib/udev/rules.d /etc/udev/rules.d
@systemd@/lib/systemd/systemd-udevd --daemon
udevadm trigger --action=add
udevadm settle || true

export HOME=/root
cd ${HOME}

cat /proc/net/pnp | grep -v bootserver >/etc/resolv.conf

dev=$rootDevice

informOk "Installing NixOS on device $dev"

## FIXME: make partitioning configurable and more robust, maybe
## support RAID.
informOk "Creating disk label..." -n
parted --align optimal --script $dev mklabel gpt
informOk "done"

informOk "Partitioning disk..." -n
parted --align optimal --script $dev mkpart primary fat32 0% 512MiB set 1 boot on
parted --align optimal --script $dev "mkpart primary ext4 512MiB -4GiB"
informOk "done"

informOk "Creating file systems..." -n
mkfs.vfat ${dev}1
mkfs.ext4 -q -F -L nixos ${dev}2
informOk "done"

informOk "Installing NixOS"
mkdir /mnt
mount ${dev}2 /mnt
mkdir /mnt/boot
mount ${dev}1 /mnt/boot

informOk "Unpacking image $installImg"
(cd /mnt && tar xapf $installImg)
mkdir -m 0755 -p /mnt/run /mnt/home
mkdir -m 0755 -p /mnt/tmp/root
mkdir -m 0755 -p /mnt/var/setuid-wrappers

mount -o bind /proc /mnt/proc
mount -o bind /dev /mnt/dev
mount -o bind /sys /mnt/sys
mount -t efivarfs none /mnt/sys/firmware/efi/efivars
mount -t tmpfs -o "mode=0755" none /mnt/dev/shm
mount -t tmpfs -o "mode=0755" none /mnt/run
mount -t tmpfs -o "mode=0755" none /mnt/var/setuid-wrappers
rm -rf /mnt/var/run
ln -s /run /mnt/var/run
cp /etc/resolv.conf /mnt/etc

## Generate hardware-specific configuration
nixos-generate-config --root /mnt

for o in $(cat /proc/cmdline); do
    case $o in
        ip=*)
	    set -- $(IFS=:; for arg in $o; do if [ -n "$arg" ]; then echo $arg; else echo '""'; fi; done)
            interface=$6
            ;;
    esac
done

eval "$(dhcpcd -q -4 -G -p -c @dhcpcHook@ $interface)"
dnsServers_quoted=
for s in $dnsServers; do
    dnsServers_quoted="$dnsServers_quoted \"$s\""
done

## This will be imported by /mnt/etc/nixos/networking.nix
interfaces=/mnt/etc/nixos/networking/interfaces.nix
if [ -n "$useDHCP" ]; then
        cat <<EOF >$interfaces
{ config, lib, pkgs, ... }:

{
  networking = {
    hostName = "$hostname";
    useDHCP = true;
  };
}
EOF
else
    if [ -z "$staticInterfaceFromDHCP" ]; then
	informNotOk "Static interface configuration requested but " -n
	informnNotOk "staticInterfaceFromDHCP missing"
	exit 1
    fi
    informOk "Creating static network configuration for interface " -n
    informOk "$staticInterfaceFromDHCP from DHCP"
    cat <<EOF >$interfaces
{ config, lib, pkgs, ... }:

{
  networking = {
    hostName = "$hostname";
    interfaces.$staticInterfaceFromDHCP.ip4 = [ {
      address = "$ipv4Address";
      prefixLength = $ipv4Plen;
    } ];

    useDHCP = false;
    defaultGateway = "$ipv4Gateway";
    nameservers = [ $dnsServers_quoted ];
  };
}
EOF
fi

## Make perl shut up
export LANG=
export LC_ALL=
export LC_TIME=

## NIX path to use in the chroot
export NIX_PATH=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix

informOk "generating system configuration"
## We use nix-env from the "native" nix package on the target to
## de-couple the target completely from the installer.  For this
## purpose, the tarball contains a symlink to nix-env in a well-known
## location.
NIX_REMOTE= NIX_SUBSTITUTERS= chroot /mnt /nix-env -p /nix/var/nix/profiles/system -f '<nixpkgs/nixos>' --set -A system
## The symlink is no longer needed, clean it up.
rm /mnt/nix-env

informOk "activating final configuration"
NIXOS_INSTALL_GRUB=1 chroot /mnt /nix/var/nix/profiles/system/bin/switch-to-configuration boot
rm /mnt/etc/resolv.conf
chroot /mnt /nix/var/nix/profiles/system/activate
chmod 655 /mnt
umount /mnt/proc /mnt/dev/shm /mnt/dev /mnt/sys/firmware/efi/efivars /mnt/sys
umount /mnt/run /mnt/var/setuid-wrappers /mnt/boot /mnt

informOk "rebooting into the new system"
reboot --force

## not reached
