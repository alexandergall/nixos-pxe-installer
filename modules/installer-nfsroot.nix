# This module creates two derivations:
#
#   A tarball containing a file system tree that can be mounted as
#   (read-only) root file system via NFS
#
#   A tarball containing a GRUB EFI boot loader image and
#   configuration files that can be served to a PXE client together
#   with a Linux image used to mount the NFS root file system.

{ config, lib, pkgs, ... }:

with lib;

let

  ## FIXME: make serial console configurable
  ## FIXME: support legacy (non-EFI) systems
  grubConfig = pkgs.writeText "grub.cfg"
    ''
      serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
      terminal_input serial
      terminal_output serial
      set timeout=5
      menuentry "NixOS Automated Network Installation" {
        echo "Network status: "
        net_ls_addr
        net_ls_routes

        echo "Checking for $prefix/load-kernel-$net_default_mac.cfg"
        configfile $prefix/load-kernel-$net_default_mac.cfg

        echo "Checking for $prefix/load-kernel-$net_default_ip.cfg"
        configfile $prefix/load-kernel-$net_default_ip.cfg

        eval set hostname=\$net_''${net_default_interface}_hostname
        if test $hostname != ""; then
          echo "Checking for $prefix/load-kernel-$hostname.cfg"
          configfile $prefix/load-kernel-$hostname.cfg
        fi

        echo "Checking for $prefix/load-kernel.cfg"
        configfile $prefix/load-kernel.cfg
      }
    '';

  grubLoadKernel = pkgs.writeText "load-kernel.cfg"
    ''
        echo "load-kernel.cfg: loading kernel $prefix/bzImage ..."
        linux  $prefix/bzImage console=ttyS0,115200n8 ip=::::::dhcp:: root=/dev/nfs init=${nfsrootSetup}
        boot
    '';

  generateLoader = pkgs.writeScript "generate-bootloader"
    ''
      grub-mkimage -O x86_64-efi -o ./bootx64.efi -p '(tftp)' \
        serial terminal net efinet tftp normal echo eval test linux configfile reboot
    '';

  kernel = pkgs.linux_latest;
  bootLoader = pkgs.runCommand "grub-efi-bootloader"
    { buildInputs = [ pkgs.grub2_efi ]; }
    ''
      tmp=$TMPDIR/stage
      mkdir $tmp
      cp ${grubConfig} $tmp/grub.cfg
      cp ${grubLoadKernel} $tmp/load-kernel.cfg
      cp ${generateLoader} $tmp/generate
      cp ${kernel}/bzImage $tmp
      chmod a+x $tmp/generate
      (cd $tmp && ./generate)
      mkdir $out
      (cd $tmp && tar cf $out/boot-loader.tar.xz *)
    '';

  # Make the read-only NFS root writeable via unionfs-fuse
  nfsrootSetup = pkgs.substituteAll {
    src = ./nfsroot-setup.sh;
    shell = pkgs.bash + "/bin/bash";
    isExecutable = true;
    path = [ pkgs.coreutils pkgs.unionfs-fuse pkgs.utillinux ];
    inherit installer;
  };

  # A bash-snippet used by the installer to create a
  # static network configuration from the DHCP information
  dhcpcHook = pkgs.writeScript "dhcpc-hook.sh"
    ''
      #! ${pkgs.bash}/bin/bash
      if [ "$reason" = "REBOOT" -o "$reason" = "BOUND" ]; then
        echo hostname=$new_host_name
        echo ipv4Address=$new_ip_address
        echo ipv4Gateway=$new_routers
        echo ipv4Plen=$new_subnet_cidr
        echo dnsServers=\"$new_domain_name_servers\"
      fi
    '';

  # The installer is executed by nfsrootSetup once the
  # root file system is set up r/w
  installer = pkgs.substituteAll {
    src = ./installer.sh;
    isExecutable = true;
    path = with pkgs;
      [ coreutils
        iproute
        gawk
        parted
        dosfstools
        e2fsprogs
        utillinux
        gnugrep
        dhcpcd
        gnutar
        xz
        gzip
        kmod
        config.systemd.package
        config.system.build.nixos-generate-config
        config.system.build.nixos-enter
      ];
      inherit (pkgs) nix;
      systemd = config.systemd.package;
      # Kernel modules required by the installer
      kernelModules = [
        "ahci"
        "ext4"
        "vfat" "nls_cp437" "nls_iso8859_1"
        "af_packet"
        "efivars" "efivarfs"
      ];
      inherit dhcpcHook;
      inherit kernel;
  };
in

{

  options = {
    nfsroot = {
      extraKernelOptions = mkOption {
        default = "";
        example = "IXGB y IXGBE y";
        description = ''
          The nfsroot module generates a custom kernel that has
          support for some network drivers and root NFS compiled in.
          This configuration option can be used to add network
          drivers missing from the standard set.
        '';
      };

      contents = mkOption {
        type = types.listOf types.attrs;
        default = [];
        example = literalExample ''
          [ { source = pkgs.memtest86 + "/memtest.bin";
              target = "/boot/memtest.bin";
            }
          ]
        '';
        description = ''
          This option lists files to be copied to fixed locations in the
          generated NFS root file system.  Each item is a set with
          two keys, "source" and "target".  The former is a string that
          contains the absolute path of the file to be copied.  The latter
          is a string that contains the path within the NFS root file system
          to which the source file is copied either as absolute path or a path
          relative to the root of the NFS root file system.
        '';
      };

      storeContents = mkOption {
        type = types.listOf types.attrs;
        default = [];
        example = literalExample ''
          [ { object = pkgs.foo;
              symlink = "/bar";
            } ]
        '';
        description = ''
          This option lists derivations whose closures will be added to the
          Nix store in the generated NFS root file system.  Each item is a
          set with two, keys "object" annd "symlink".  The former identifies
          the derivation itself.  The latter is a string that identifies a
          path within the NFS root file system, at which a symlink to the
          derivation is created.  The value "none" indicates that no symlink
          should be created.
        '';
      };
    };
  };

  config = {

    # Closures to be copied to the Nix store on the NFS root
    # file system.
      nfsroot.storeContents = [
        { object = nfsrootSetup;
          symlink = "/init";
        }
        { object = installer;
          symlink = "none";
        }
      ];

    # Configure a custom kernel with some network drivers
    # and NFS support built in.
    # FIXME: remove unneeded features to make the thing smaller
    nixpkgs.config = {
      packageOverrides = p: rec {
        linux_latest = p.linux_latest.override {
          extraConfig = ''
            # Enable some network drivers
            IGB y
            IXGB y
            IXGBE y
            E1000 y
            E1000E y

            # Enable nfs root boot
            UNIX y # http://www.linux-mips.org/archives/linux-mips/2006-11/msg00113.html
            IP_PNP y
            IP_PNP_DHCP y
            FSCACHE y
            NFS_FS y
            NFS_FSCACHE y
            ROOT_NFS y
            NFS_V3 y
            NFS_V4 y

            # Enable fuse file system
            FUSE_FS y

            # Enable devtmpfs
            DEVTMPFS y
            DEVTMPFS_MOUNT y
          '' + config.nfsroot.extraKernelOptions;
        };
      };
    };

    system.build.nfsroot = {
      nfsRootTarball = import ../lib/make-nfsroot.nix ({
        inherit (pkgs) stdenv perl pathsFromGraph;
        inherit (config.nfsroot) contents storeContents;
      });
      inherit bootLoader;
    };
  };
}
