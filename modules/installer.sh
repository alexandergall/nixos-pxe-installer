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
informOk "...udev done"

export HOME=/root
cd ${HOME}

cat /proc/net/pnp | grep -v bootserver >/etc/resolv.conf

### Source optional configuration
## Defaults
rootDevice=/dev/sda

interface=$(ip route list match default | awk '{print $5}')
mac_address=$(ip link show $interface | grep ether | awk '{print $2}')
eval "$(dhcpcd -q -4 -G -p -c @dhcpcHook@ $interface)"
dnsServers_quoted=
for s in $dnsServers; do
    dnsServers_quoted="$dnsServers_quoted \"$s\""
done

informOk "Parsing custom configuration..."
try_config () {
    file=/installer/$1
    informOk "Trying $file..." -n
    if [ -f $file ]; then
        informOk "loading"
        . $file
    else
        informOk "not present"
    fi
}
try_config config-$ipv4Address
try_config config-$mac_address
try_config config
informOk "...custom configuration done"

dev=$rootDevice
part1=${rootDevice}${partitionSeparator}1
part2=${rootDevice}${partitionSeparator}2

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

informOk "Creating file systems..."
## Enable checking of mounted file systems
ln -s /proc/mounts /etc/mtab
mkfs.vfat ${part1}
mkfs.ext4 -q -F -L nixos ${part2}
informOk "...file systems done"

informOk "Installing NixOS"
mkdir /mnt
mount ${part2} /mnt
mkdir /mnt/boot
mount ${part1} /mnt/boot

informOk "Unpacking image $installImg..." -n
(cd /mnt && tar xapf $installImg)
chown -R 0:0 /mnt
informOk "done"
mkdir -m 1777 /mnt/tmp
## Make the resolver config available in the chroot
cp /etc/resolv.conf /mnt

## Generate hardware-specific configuration
nixos-generate-config --root /mnt

## NIX path to use in the chroot
export NIX_PATH=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix

informOk "generating system configuration..."
## FIXME: starting with 18.09, nix.useSandbox defaults to true, which breaks the execution of
## nix-env in a chroot when the builder needs to be invoked.  Disabling the sandbox
## is a workaround.
nixos-enter --root /mnt -c "/run/current-system/sw/bin/mv /resolv.conf /etc && \
  /run/current-system/sw/bin/nix-env --option sandbox false -p /nix/var/nix/profiles/system -f '<nixpkgs/nixos>' --set -A system"
informOk "...system configuration done"

informOk "activating final configuration..."
NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root /mnt \
  -c "/run/current-system/sw/bin/mount -t efivarfs none /sys/firmware/efi/efivars && \
  /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
informOk "...activation done"

chmod 755 /mnt

informOk "rebooting into the new system"
reboot --force

## not reached
