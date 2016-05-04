# nixos-pxe-installer

A set of modules to perform a fully automated installation of a
customised NixOS system over the network via PXE using an NFS-mounted
root file system.

## Overview

The system is composed of two components: the module
`modules/install-image.nix`, which creates an *install image* of a
NixOS system and the module `modules/installer-nfsroot.nix`, which
creates a generic installer for such an image.

An install image is a `tar` archive of a complete NixOS system created
from a given `nixpkgs` source tree and an arbitrary NixOS
configuration.  The image contains the closure of the corresponding
top-level system configuration.

The installer provides the files required for a PXE-based network boot
of the client system on which the install image is going to be
installed.  The client mounts a generic root file system over NFS
which contains a copy of the install image and some client-specific
configuration parameters.  The installer then partitions and formats
the local disk, unpacks the install image onto it, performs the final
activation of the NixOS configuration and reboots the client into the
new system.

The install image is completely self-contained: no contents is
transferred from the installer and all components that are being
created during the final acitvation are derived from the install image
within a `chroot` environment.  In particular, the NixOS versions from
which the installer and install image are derived are completely
independent.

## Quickstart

### Setting up the installer

#### <a name="buildingInstaller"></a>Building

To create an installer with default settings, clone into the
`nixos-pxe-installer` repository and put the following Nix expression
in the file `default.nix` in the top-level directory

```
{ system ? "x86_64-linux" }:

with import <nixpkgs> { inherit system; };
with lib;

let

  nfsroot = (import <nixpkgs/nixos/lib/eval-config.nix> {
    inherit system;
    modules = [ modules/installer-nfsroot.nix ];
  }).config.system.build.nfsroot;

in
  with nfsroot;
  [ nfsRootTarball bootLoader kernel ]
```

Then execute `nix-build` in the top-level directory.  This will create
three derivations containing the components of the installer (in this
example, all derivations have already been built in a previous
invocation)

```
$ nix-build
/nix/store/kx60qw6065x246c4jmmmqh24qxr5sb1a-nfsroot
/nix/store/xl4lr843c0m30vhraxpncn02jnhm6l5b-grub-efi-bootloader
/nix/store/b3rld51kcz1kb5c97xk0kl1dmfp04m5s-linux-3.18.29

$ ls -l result*
lrwxrwxrwx 1 gall users 51 May  4 09:57 result -> /nix/store/kx60qw6065x246c4jmmmqh24qxr5sb1a-nfsroot
lrwxrwxrwx 1 gall users 63 May  4 09:57 result-2 -> /nix/store/xl4lr843c0m30vhraxpncn02jnhm6l5b-grub-efi-bootloader
lrwxrwxrwx 1 gall users 57 May  4 09:57 result-3 -> /nix/store/b3rld51kcz1kb5c97xk0kl1dmfp04m5s-linux-3.18.29
```

Make a copy of the following files

   * `result/nfsroot.tar.xz`
   * `result-2/bootx64.efi`
   * `result-3/bzImage`

#### Configuring

In this example, we use the following assignments

   * IP subnet where the install client resides
    * Subnet 192.0.2.0/24
    * Gateway 192.0.2.1
   * Install client
    * MAC address `01:02:03:04:05:06`
    * Fixed IP address 192.0.2.2
   * TFTP server address 198.51.100.1
   * NFS server address 198.51.100.2
   * 1st DNS server address 198.51.100.3
   * 2nd DNS server address 198.51.100.4
   * DNS domain `example.org`

##### DHCP Server


The following configuration is for a stock ISC DHCP server.

```
option domain-name "example.org";
option domain-name-servers 198.51.100.3, 198.51.100.4;
## Generate a hostname option (#12) from a host declaration
use-host-decl-names on;

## The current grub2 networking stack does not set the DHCP magic
## cookie vendor class, i.e. it creates a pure BOOTP requests.  It
## still expects a DHCP response with particular options, which is
## totally broken.  This option forces the server to reply with DHCP,
## also see "dhcp-parameter-request-list" below.
always-reply-rfc1048 on;

## Only the EFI x64 client system architecture is currently supported
option arch code 93 = unsigned integer 16;
if option arch = 00:07 {
   filename "nixos/bootx64.efi";
} else {
   ## This suppresses the "boot file name" BOOTP option
   ## in the reply, which causes non-EFIx64 systems to stall
   filename "";
} 

subnet 192.0.2.0 netmask 255.255.255.255 {
       next-server 198.51.100.1;
       option routers 192.0.2.1;
       option tftp-server-name "198.51.100.1"; # This could also be a domain name
       option root-path "192.51.100.2:/srv/nixos/nfsroot,vers=3,tcp,rsize=32768,wsize=32768,actimeo=600"; # Option 17

       ## Required for the borked grub2 bootp mechanism.  We need to
       ## include all required options, since options not on this list
       ## are suppressed, even when the client asks for them.
       option dhcp-parameter-request-list 1,3,6,12,15,17,66; # subnet mask, router, DNS server, hostname, domain, root-path, tftp-server
}

host install-client { hardware ethernet 01:02:03:04:05:06; 
                      fixed-address 192.0.2.2; }
```

##### TFTP Server

A TFTP server is needed to serve the boot loader and Linux kernel.  In
this example, we use
[`tftp-hpa`](https://www.kernel.org/pub/software/network/tftp/) and
assume that the path `/srv/tftp/nixos` exists and is readable by user
`nobody`.

Copy the files `bootx64.efi` and `bzImage` (see section
[Building](#buildingInstaller)) to `/srv/tftp/nixos` and start the
deamon as

```
in.tftpd --listen --address 198.51.100.1:69 --secure /srv/tftp
```

##### NFS Server

Create the path `/srv/nixos/nfsroot` and unpack `nfsroot.tar.xz` (see
section [Building](#buildingInstaller)) in it

```
# mkdir -p /srv/nixos/nfsroot
# cd /srv/nixos/nfsroot
# tar xaf /path-to/nfsroot.tar.xz
```

Export `/srv/nixos/nfsroot` read-only via NFS by adding the following
line to `/etc/exports` (or the equivalent on your system)

```
/srv/nixos/nfsroot 192.0.2.0/24(async,ro,no_subtree_check,no_root_squash)
```

### Preparing an Install Image

#### Building

Create a file `default.nix` in the top-level directory containing the
configuration for the install image as described in the [section about
install image examples](#imageExamples), then execute

```
$ nix-build
```

#### Staging

Copy the tarball to `/srv/nixos/nfsroot/installer` and create a
symbolic link to it from `/srv/nixos/nfsroot/installer/nixos-image`

```
# cp /path-to/nixos.tar.gz /srv/nixos/nfsroot/installer
# ln -s ./nixos.tar.gz /srv/nixos/nfsroot/installer/nixos-image
```

### Installing the Client

Configure the client's EFI boot loader to perform a PXE boot on the
desired interface and initiate a system boot.  With all previous steps
completed, the client should be installed and rebooted into the new
system automatically.

## Install Image

The main ingredients to the creation of an install image are a copy of
a `nixpkgs` source tree and a NixOS configuration directory structured
like `/etc/nixos`.

The `nixpkgs` source tree can either be a NixOS *channel* named
`nixos` or a checkout of the `nixpkgs` Git repository, which will be
transformed into such a channel by the module.  Please refer to the
[appendix](#appendixChannels) for details.

### Module configuration

Pleas refer to the options declaration in `module/install-image.nix`
for a full description of the available options.  Alternatively, you
can run the command

```
nix-build module-manpages.nix -A installImage && man result/share/man/man5/configuration.nix.5
```

in the repository to get a summary as a pseudo-manpage.

### Image creation

The actual image is created by `lib/make-install-image.nix` inside a
VM.  The main ingredient is the evaluation of the desired NixOS
configuration in the context of the supplied channel (simplified):

```
  config = (import (channel + "/nixos/nixos/lib/eval-config.nix") {
    modules = [ (nixosConfigDir + "/configuration.nix") ];
  }).config;
```

The Nix store of the install image is populated with the closures of
`config.system.build.toplevel` and `channel`, which makes all packages
needed for the final activation on the install client available from
the install image itself (i.e. there will be no need to fetch
substitutes from a binary cache).  This is actually not quite true,
because the final system configuration contains elements unknown at
the time of creation of the image, in particular the exact
configuration of the boot loader.  This is why the code in
`lib/make-install-image.nix` contains a few additional packages, which
are not part of said closures, to make that final step self-contained
as well.

The module produces three derivations, which are available in the
attribute set `config.system.build.installImage`

   * `channel`. The NixOS channel containing the `nixpkgs` sources from
      the `installImage.nixpkgs.path` option
   * `tarball`. The `tar` archive containing the install image
   * `config`. A shell-script containing configuration parameters derived
      from the `installImage` module options that need to be propagated to
      the installer.  Currently, this includes
      
       * The device on which to install the root file system of the
         install client (`installImage.rootDevice`)
       * The flags for the network configuration of the install client
         (`useDHCP` and `staticInterfaceFromDHCP`)

The `channel` derivation is made available for convenience and is not
required for the installation process.

The `tarball` and `config` derivations each contain a single file
called `nixos.tar.gz` and `config`, respectively.  These files need to
be copied into the `installer` directory of the NFS root file system
used by the installer.

### <a name="imageExamples"></a>Examples

In the following examples, we assume that the current directory is a
checkout of the `nixos-pxe-installer` repository.

The most basic usage is represented by the following code

```
$ cat default.nix
with import <nixpkgs> {};

let
  installImage = (import <nixpkgs/nixos/lib/eval-config.nix> {
    modules = [ modules/install-image.nix ];
  }).config.system.build.installImage;
in
  {
    inherit (installImage) channel tarball config;
  }
```

which can be executed by `nix-build`.  This will build an install
image from the `nixos` channel of the current system based on the
default value `<nixpkgs>` of the option `installImage.nixpkgs.path`,
as can be seen from the channel version

```
$ nixos-version 
16.03.659.011ea84 (Emu)

$ nix-build -A channel
these derivations will be built:
  /nix/store/xpg4vk7hq7am5zwsniva1dg770qi91xv-nixos-16.03.659.011ea84.drv
building path(s) ‘/nix/store/ip7vgnh1ffhpc07gmjpzr8b8c38m1c9j-nixos-16.03.659.011ea84’
/nix/store/ip7vgnh1ffhpc07gmjpzr8b8c38m1c9j-nixos-16.03.659.011ea84
```

To create a clone of the current system, one could use

```
with import <nixpkgs> {};

let
  installImageConfig = {
    installImage = {
      nixosConfigDir = /etc/nixos;
    };
  };
  installImage = (import <nixpkgs/nixos/lib/eval-config.nix> {
    modules = [ modules/install-image.nix
                installImageConfig ];
  }).config.system.build.installImage;
in
  {
    inherit (installImage) channel tarball config;
  }
```

To create an install image for the current version of the NixOS
release 16.03, one would first clone into the `release-16.03` branch
of the `nixpkgs` repository

```
$ git clone -b release-16.03 https://github.com/NixOS/nixpkgs.git
Cloning into 'nixpkgs'...
remote: Counting objects: 707015, done.
remote: Compressing objects: 100% (60/60), done.
remote: Total 707015 (delta 28), reused 0 (delta 0), pack-reused 706955
Receiving objects: 100% (707015/707015), 332.81 MiB | 18.80 MiB/s, done.
Resolving deltas: 100% (461452/461452), done.
Checking connectivity... done.
```

Then use

```
with import <nixpkgs> {};

let
  installImageConfig = {
    installImage = {
      nixpkgs.path = ./nixpkgs;
    };
  };
  installImage = (import <nixpkgs/nixos/lib/eval-config.nix> {
    modules = [ modules/install-image.nix
                installImageConfig ];
  }).config.system.build.installImage;
in
  {
    inherit (installImage) channel tarball config;
  }
```

to build the image.  The mechanics for deriving the version number can
be seen in action when building the channel (through the derivation
named `get-rev-count` and the names of derivations constructed from
it):

```
$ nix-build example.nix -A channel
building path(s) ‘/nix/store/8kb9yiclcxai27a8ml56d7pj87y7xqyv-get-rev-count’
building path(s) ‘/nix/store/2vnq4f2l9mdrlqfx3bp4zrl5hv9wbzdq-nixos-channel-16.03.702.d444f80’
unpacking sources
unpacking source archive /home/gall/projects/nixos-pxe-installer/nixpkgs
source root is nixpkgs
setting SOURCE_DATE_EPOCH to timestamp 1462270038 of file nixpkgs/pkgs/top-level/rust-packages.nix
patching sources
autoconfPhase
No bootstrap, bootstrap.sh, configure.in or configure.ac. Assuming this is not an GNU Autotools package.
configuring
grep: : No such file or directory
grep: : No such file or directory
no configure script, doing nothing
post-installation fixup
shrinking RPATHs of ELF executables and libraries in /nix/store/2vnq4f2l9mdrlqfx3bp4zrl5hv9wbzdq-nixos-channel-16.03.702.d444f80
gzipping man pages in /nix/store/2vnq4f2l9mdrlqfx3bp4zrl5hv9wbzdq-nixos-channel-16.03.702.d444f80
patching script interpreter paths in /nix/store/2vnq4f2l9mdrlqfx3bp4zrl5hv9wbzdq-nixos-channel-16.03.702.d444f80
distPhase
finalPhase
build time elapsed:  0m0.081s 0m0.060s 0m37.317s 0m10.215s
these derivations will be built:
  /nix/store/l4blwp5i9xa3nbs222fkbv3dcipn7r71-nixos-16.03.702.d444f80.drv
building path(s) ‘/nix/store/rcba63kq88yv1lav17cvja3xghpfbps3-nixos-16.03.702.d444f80’
/nix/store/rcba63kq88yv1lav17cvja3xghpfbps3-nixos-16.03.702.d444f80
```

In this example, the newest available version of NixOS 16.03 is 43
commits ahead of the NixOS system currently installed on the system
(`16.03.659.011ea84` vs `16.03.702.d444f80`).

The installer configuration reflects the defaults of the module
options `rootDevice`, `networking.useDHCP` and
`networking.staticInterfaceFromDHCP`:

```
$ nix-build example.nix -A config && cat result/config
/nix/store/7fym30dgr33xyss5aa9zvlrmb9sxjf5k-install-config
rootDevice=/dev/sda
useDHCP=1
staticInterfaceFromDHCP=
```

## Installer

The installer currently supports only network boots of UEFI systems.
The boot sequence is as follows.

   * Client issues a DHCP "discover" request
   * DHCP server responds with IP configuration,
     IP address of a TFTP server (`next server` BOOTP option)
     from which to fetch the boot loader and the file name of
     the boot loader image (`boot file name` BOOTP option)
   * Client fetches the boot loader and executes it

The boot loader used by the installer is based on the EFI variant of
Grub2.  It issues another DHCP request to discover the name of a TFTP
server (DHCP option 66) and downloads a Linux kernel from it with path
`nixos/bzImage`.

The kernel is started with the options `ip=:::::eth0:dhcp::
root=/dev/nfs` (by default, see the section about [multi-homed
hosts](#multihimed)) to initiate yet another round of DHCP request to
configure IP and ask for the path to a NFS-exported root file system
via DHCP option #17.  This option should look like

```
<ip-address>:<path>,vers=3,tcp,rsize=32768,wsize=32768,actimeo=600
```

where `<ip-address>` is the literal IPv4 address of the NFS server and
`<path>` is the file system path from which the root file system can
be mounted by the kernel.  The file system should be exported
read-only.

Once the read-only root file system has been mounted, it is
transformed into a writeable file system using unionfs/fuse and
control is transferred to a shell script that performs the actual
installation, which performs the following actions.

   * Source the installer configuration from `/installer/config` (this
     is the file that was generated by `install-image.nix`)
     
   * Create a new partition table on the disk specified in the
     `rootDevice` configuration variable containing two partitions

     * Type FAT32, size 512MiB, used as EFI boot partition
     * Type EXT4, rest of disk except 4GiB at the end (may be used
       as swap later on but remains unused by the installer), used
       as root partition

   * Create filesystems on the partitions (`vfat` and `ext4`,
     respectively)

   * Label the `ext4` partition as `nixos`

   * Mount the root partition as `/mnt`
   
   * Unpack the install image onto `/mnt`.  The image is expected to
     be a `tar` file located at `/installer/nixos-image`, which is
     typically a symbolic link to the file `nixos.tar.gz` created by
     `install-image.nix`.  The image is extracted with the
     `--auto-compress` option, i.e. the compression program is
     determined from the extension of the name of the install image
     (possibly after de-referencing symbolic links)

   * The root partition has a directory `/etc/nixos` which is empty or
     contains a pre-created configuration, depending on the
     `installImage.nixosConfigDir` configuration option.
   
   * The hardware-specific NixOS configuration is created by executing
     `nixos-generate-config --root=/mnt`.  This will generate the file
     `/mnt/etc/nixos/hardware-configuration.nix`.  If
     `/mnt/etc/nixos/configuration.nix` does not exist, it will be
     created as well and import `./hardware-configuration.nix`
     automatically.  If `/mnt/etc/nixos/configuration.nix` has been
     pre-created when the install image was generated, it will not be
     touched by `nixos-generate-config`.  In this case, it is
     important that it is configured to import
     `./hardware-configuration.nix`.

   * A basic network configuration is generated based on the `useDHCP`
     and `staticInterfaceFromDHCP` configuration variables.  If
     `useDHCP` is set, the network is configured as

     ```
     networking = {
       hostName = <hostname>;
       useDHCP = true;
     };
     ```

     where `<hostname>` is the hostname obtained from the DHCP server.
     If `useDHCP` is not set, the configuration

     ```
     networking = {
       hostName = "<hostname>;
       interfaces.<staticInterfaceFromDHCP>.ip4 = [ {
         address = "<ipv4Address>";
         prefixLength = <ipv4Plen>;
       } ];

       useDHCP = false;
       defaultGateway = "<ipv4Gateway>";
       nameservers = [ <dnsServer1> ... ];
     };
     ```

     will be used instead, where `<hostname>`, `<ipv4Address>`,
     `<ipv4Plen>`, `<ipv4Gateway>` and the list of DNS servers are
     obtained from the DHCP server. `<staticInterfaceFromDHCP>` is
     replaced by the configuration variable by that name.

   * The NixOS configuration of the final system is generated by
     executing `/nix-env -p /nix/var/nix/profiles/system -f
     '<nixpkgs/nixos>' --set -A system` in a chroot environment on the
     root partition.  Note that `/nix-env` is a symbolik link which
     points to `nix-env` on the install image (placed there by
     `install-image.nix`).

   * The final configuration is activated by executing
     `/nix/var/nix/profiles/system/bin/switch-to-configuration boot`
     in chroot on the root partition, which will generate the boot
     loader and configure the EFI boot loader to boot from it.

   * Reboot.  The EFI boot loader will automatically prefer the fresh
     root partition (no need to change boot poriorities manually from
     the BIOS)

### Multi-homed hosts

For multi-homed hosts, the Grub boot loader currently needs to be
configured with the interface to use for booting.  The name of the
interface is of the form `efinet<n>`, wheren `<n>` is an integer
assigned by Grub.  The loade displays a list of known interfaces when
it starts up, e.g.

```
Available interfaces: 
efinet7 00:0b:ab:84:21:80
efinet6 00:0b:ab:84:21:7f
efinet5 00:0b:ab:83:f3:e3
efinet4 00:0b:ab:83:f3:e2
efinet3 00:0b:ab:83:f3:e1
efinet2 00:0b:ab:83:f3:e0
efinet1 00:0b:ab:83:f3:df
efinet0 00:0b:ab:83:f3:de
```

By default, it uses `efinet0`, but this can be changed through the
module option `nfsroot.bootLoader.efinetDHCPInterface`.  The loader
will perform DHCP discovery on the specified interface and load the
linux kernel from the TFTP server obtained via DHCP option #66.

The kernel performs another DHCP request to configure its IP stack.
To avoid timeouts while probing inactive interfaces, the boot loader
specifies the interface to use via the `ip` kernel option.  Even
though this is the same device as that used by Grub, it is known to
the kernel under a different name, assigned to it by the networking
subsystem.  Usually it is of the form `eth<n>`, with `<n>` being an
integer.  The name cannot be reliably determined from Grub's `efinet`
parameter, which is why there is a separate module option for it:
`nfsroot.bootLoader.linuxPnPInterface`, which defaults to `eth0`.
Whatever is specified there will appear in the kernel command line
`ip=:::::<interface>:dhcp::` in place of `<interface>`.

### Module configuration

Pleas refer to the options declaration in `module/install-image.nix`
for a full description of the available options.  Alternatively, you
can run the command

```
nix-build module-manpages.nix -A installer && man result/share/man/man5/configuration.nix.5
```

in the repository to get a summary as a pseudo-manpage.


## Appendix 
### <a name="appendixChannels"></a>Channels

In the context of the `install-image.nix` module, a channel is defined
as the instantiation of a [NixOS
channel](https://nixos.org/nixos/manual/index.html#sec-upgrading) as
the result of performing a `nix-channel --upgrade` operation, which is
a store path that contains a reference to a binary cache URL and a
copy of a `nixpkgs` source tree.  For example, consider a system with
the following channel named `nixos`

```
# nix-channel --list
nixos https://nixos.org/channels/nixos-16.03
```

Instantiation of the channel results in the creation of a new
generation of the root user's profile called `channels`:

```
# ls -l /nix/var/nix/profiles/per-user/root/channels/
total 12
lrwxrwxrwx 1 root nixbld 81 Jan  1  1970 binary-caches -> /nix/store/25d02max8scl...-nixos-16.03.659.011ea84/binary-caches
lrwxrwxrwx 1 root nixbld 60 Jan  1  1970 manifest.nix -> /nix/store/0vhr39lcfvb2...-env-manifest.nix
lrwxrwxrwx 1 root nixbld 73 Jan  1  1970 nixos -> /nix/store/25d02max8scl...-nixos-16.03.659.011ea84/nixos
```

The symbolik links `binary-caches` and `nixos` point to the store path
`/nix/store/25d02max8scl...-nixos-16.03.659.011ea84`, which contains the URL of the binary cache associated with the channel

```
# cat /nix/store/25d02max8scl...-nixos-16.03.659.011ea84/binary-caches/nixos 
https://cache.nixos.org
```

and a copy of a full `nixpkgs` source tree

```
# ls -la /nix/store/25d02max8scl...-nixos-16.03.659.011ea84/nixos
total 64
dr-xr-xr-x  7 root nixbld 4096 Jan  1  1970 .
dr-xr-xr-x  4 root nixbld 4096 Jan  1  1970 ..
-r--r--r--  1 root nixbld 1685 Jan  1  1970 COPYING
-r--r--r--  1 root nixbld  370 Jan  1  1970 default.nix
dr-xr-xr-x  4 root nixbld 4096 Jan  1  1970 doc
-r--r--r--  1 root nixbld   40 Jan  1  1970 .git-revision
dr-xr-xr-x  3 root nixbld 4096 Jan  1  1970 lib
dr-xr-xr-x  4 root nixbld 4096 Jan  1  1970 maintainers
-r--r--r--  1 root nixbld   43 Jan  1  1970 .mention-bot
dr-xr-xr-x  7 root nixbld 4096 Jan  1  1970 nixos
lrwxrwxrwx  1 root nixbld    1 Jan  1  1970 nixpkgs -> .
dr-xr-xr-x 16 root nixbld 4096 Jan  1  1970 pkgs
-r--r--r--  1 root nixbld 2270 Jan  1  1970 README.md
-r--r--r--  1 root nixbld   13 Jan  1  1970 svn-revision
-r--r--r--  1 root nixbld  244 Jan  1  1970 .travis.yml
-r--r--r--  1 root nixbld    5 Jan  1  1970 .version
-r--r--r--  1 root nixbld   12 Jan  1  1970 .version-suffix
```

It is this store path
(`/nix/store/25d02max8scl...-nixos-16.03.659.011ea84` in this example)
to which we refer to as *channel* in the context of the
`install-image.nix` module.

It is worth noting that the string `nixos` in the directory names
`nixos` and `binary-caches/nixos` of the store path is the name by
which the channel was registered with `nix-channel --add`.  The
channel named `nixos` plays a special role in a NixOS system, because
it provides the default Nix expression used for the configuration of
the system, e.g. by `nixos-rebuild`.  This is reflected in the fact
that the standard `NIX_PATH` refers to that channel explicitely, e.g.

```
$ echo $NIX_PATH
/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix:/nix/var/nix/profiles/per-user/root/channels
```

For this reason, the `install-image.nix` module requires a channel
named `nixos` as input.

Apart from referring to an existing channel, `install-image.nix` can
also be called with a reference to a directory that contains a
checked-out version of a Git repository of the `nixpkgs` source tree.
The main differences (apart from the Git-specific files) with respect
to a channel as defined above are the following

   * Missing `.version-suffix`
   * No reference to a channel name
   * No reference to a binary cache

The file `.version-suffix`, together with `.version`, makes up the
full version identifier of a NixOS system:

```
$ (cd /nix/store/25d02max8sclx4g7xdpqhdm54iz63a0p-nixos-16.03.659.011ea84/nixos && cat .version .version-suffix)
16.03.659.011ea84
```

It is not part of a `nixpkgs` Git repository.  Instead, it is
constructed from a particular commit in one of the `release` branches
by the Hydra CI system when a new release is created.  The relevant
code can be found in `nixos/release.nix` of `nixpkgs`:

```
{ nixpkgs ? { outPath = ./..; revCount = 56789; shortRev = "gfedcba"; }
, stableBranch ? false
, supportedSystems ? [ "x86_64-linux" "i686-linux" ]
}:
  .
  .
  .
  version = builtins.readFile ../.version;
  versionSuffix =
    (if stableBranch then "." else "pre") + "${toString (nixpkgs.revCount - 67824)}.${nixpkgs.shortRev}";
  .
  .
  .
  channel = import lib/make-channel.nix { inherit pkgs nixpkgs version versionSuffix; };
  .
  .
  .
```

When called from the Hydra build system, the dummy default values of
the variables `revCount` and `shortRev` (`56789` and `gfedcba`,
respectively), are replaced by values obtained by executing the
equivalent of the following shell code in the Git repository

```
revision=$(git rev-list --max-count=1 HEAD)
revCount=$(git rev-list $revision | wc -l)
shortRev=$(git rev-parse --short $revision)
```

Hydra also sets the variable `stableBranch` to the value `true` if it
is building a release from one of the stable NixOS branches
(e.g. `release-16.03` or `release-15.09` at the time of writing) to
make the distinction to an unstable release visible in the version
number.

The `install-image.nix` module imitates this mechanism in order to
produce a NixOS channel that looks exactly as if it had been built by
the Hydra system:

   * Calculate `revCount` and `shortRev` from the Git repository
   * Create a properly versioned archive by calling
     `<nixpkgs/nixos/lib/make-channel.nix>`
   * Create the actual channel by calling `<nix/unpack-channel.nix>`
     with channel name `nixos`

In the last step, a binary cache URL supplied to `install-image.nix`
is added to the channel as well.
