### This module takes a nixpkgs channel and a NixOS configuration and
### creates a tarball containing the closure of the resulting NixOS
### system suitable for use in the PXE-based installer provided by the
### installer-nfsroot.nix module.  It produces the following derivations
### in the attribute set config.system.build.installImage.
###
###   tarball
###     The tarball itself.  It will be unpacked onto the
###     clients root partition
###   config
###     A shell script that defines some variables which
###     propagate configuration settings from the installImage
###     options to the installation process
###
{ config, lib, pkgs, ... }:

with pkgs;
with lib;
with builtins;

let

  ## Construct a derivation that contains the nixos channel from the
  ## nixpkgs expression provided by installImage.nixpkgs.path, which
  ## needs to be a store path.
  ##
  ## If the store path is a Git repository, assume that it is a
  ## checkout of some version of the nixpkgs repository and construct
  ## the "revCount" and "shortRev" attributes for HEAD just like hydra
  ## would for an input of type "Git checkout".  Then call
  ## nixos/release.nix to produce a source tarball of that particular
  ## nixpkgs expression containing the proper .version-suffix file.
  ##
  ## If the store path is not a Git repository, assume that it is the
  ## nixpkgs directory from an exisiting channel and pack it up in a
  ## tarball as if it had been created by nix/release.nix.
  ##
  ## In either case, the tarball is then run through
  ## <nix/unpack-channel.nix> to produce a derivation containing a
  ## regular channel named "nixos".  The URL of the binary cache
  ## associated with this channel is taken from the configuration
  ## option installImage.binaryCacheURL.

  cfg = config.installImage;
  nixpkgs = cfg.nixpkgs.path;
    isGitRepo = path: import (runCommand "is-git-repo" {}
      ''
        if [ -d ${path} -a -d ${path}/.git ]; then
          echo true >$out
        else
          echo false >$out
        fi
      '');
  channelInfo =
    ## This set contains two attributes:
    ##   src: a tarball of a properly versioned nixpkgs directory as required
    ##        for a proper channel
    ##   name: the name of the release as passed to <nix/unpack-channel.nix>,
    ##         which simply ignores it, though
    if isGitRepo nixpkgs then
      let
        nixpkgsRevs = import (runCommand "get-rev-count"
          { preferLocalBuild = true;
            inherit nixpkgs;
            buildInputs = [ pkgs.git ];
            ## Force execution for every invocation because there
            ## is no easy way to detect when the Git rev has changed.
            dummy = builtins.currentTime; }
          ''
            ## Note: older versions of git require write access to the parent's
            ## .git hierarchy for submodules.  This will lead to breakage here
            ## with the nix build-user without write permissions
            git=${git}/bin/git
            cd ${nixpkgs}
            revision=$($git rev-list --max-count=1 HEAD)
            revCount=$($git rev-list $revision | wc -l)
            shortRev=$($git rev-parse --short $revision)
            echo "{ revCount = $revCount; shortRev = \"$shortRev\"; }" >$out
          '');
        ## We use the mechanism provided by the standard NixOS
        ## release.nix to create a tar archive of the nixpkgs directory
        ## including proper versioning.  The tarball containing the
        ## nixpkgs tree is located in the "tarballs" subdirectory of
        ## that derivation. Its name is derived from the version number
        ## of the channel.
        channelSrc = (import (nixpkgs + "/nixos/release.nix") {
          nixpkgs = { outPath = nixpkgs; inherit (nixpkgsRevs) revCount shortRev; };
          inherit (cfg.nixpkgs) stableBranch;
        }).channel;
      in
        ## Construct the full path to the tarball in the Nix store and derive the
        ## name of the release from it
        rec { src = channelSrc + "/tarballs/"
                    + (head (attrNames (readDir (channelSrc + "/tarballs"))));
              name = removeSuffix ".tar.xz" (baseNameOf (builtins.unsafeDiscardStringContext src)); }
    else
      ## Assume this is nixpkgs from an existing channel.
      let
        path = storePath nixpkgs;
        version = fileContents (path + "/.version");
        versionSuffix = fileContents (path + "/.version-suffix");
        releaseName = "nixos-" + version + versionSuffix;
      in
        { src = (runCommand "make-tarball" {}
            ''
              mkdir -p $out/${releaseName}
              cd $out
              cp -prd ${path}/. ${releaseName}
              tar cfJ $out/${releaseName}.tar.xz ${releaseName}
            '') + "/" + releaseName + ".tar.xz";
          name = releaseName; };

  ## This will be passed as the "--channel" argument to
  ## "nixos-install" in ../lib/make-install-image.nix
  channel = import <nix/unpack-channel.nix> {
    channelName = "nixos";
    inherit (channelInfo) src name;
    inherit (cfg) binaryCacheURL;
  };

  tarball = let
    defaultNixosConfigDir = runCommand "nixos-default-config"
      {}
      ''
        mkdir $out
        cat <<"EOF" >$out/hardware-configuration.nix
        { config, lib, pkgs, ... }:

        {
          imports =
            [ <nixpkgs/nixos/modules/installer/scan/not-detected.nix>
            ];

          boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "sd_mod" ];
          powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
        }
        EOF

        mkdir $out/networking
        cat <<"EOF" >$out/networking/default.nix
        { config, lib, pkgs, ... }:

        {
          imports = [ ./interfaces.nix ];
        }
        EOF

        cat <<"EOF" >$out/networking/interfaces.nix
        { config, lib, pkgs, ... }:

        {
          networking.useDHCP = true;
        }
        EOF

        cat <<"EOF" >$out/configuration.nix
        { config, pkgs, ... }:
        {
          imports = [ ./hardware-configuration.nix
                      ./networking ];

          boot.kernelParams = with import ./serial-config.nix; [ "console=ttyS''${serialUnit},''${linuxConsoleConfig}" ];
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;

          ## Default root password is "root"
          users.mutableUsers = false;
          users.extraUsers.root.hashedPassword = "$6$cSUnFL6MbD34$BaS0NLN1KCddegCaTKDMCc1D21Pdge9gFz5tr65U0KgNOgtrEoAGuVnelaPIuEb7iC0FOWE7HUG6NV2b2yN8s/";
        }
        EOF
      '';
  in import ../lib/make-install-image.nix (rec {
    inherit pkgs lib channel;
    inherit (cfg) additionalPkgs system;
    tarballName = "nixos.tar.gz";
    serialConfig = writeText "serial-config"
      ''
        {
          serialUnit = "${toString cfg.serial.unit}";
          linuxConsoleConfig = "${cfg.serial.linuxConsoleSpeed}";
        }
      '';
  } // (if (cfg.nixosConfigDir != null) then
         { inherit (cfg) nixosConfigDir; }
       else
         { nixosConfigDir = toPath defaultNixosConfigDir; }));

  installConfig = runCommand "install-config"
    {}
    ''
      mkdir $out
      cat >$out/config <<EOF
      rootDevice=${cfg.rootDevice}
      partitionSeparator=${cfg.partitionSeparator}
      useBinaryCache=${optionalString cfg.installerUseBinaryCache "true"}
      EOF
    '';
in

{
  options = {
    installImage = {
      nixosConfigDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "path-to/nixos-configuration";
        description = ''
          This option specifies the directory that holds the NixOS configuration
          that will be installed on the client by recursively copying its contents
          to <filename>/etc/nixos</filename>.  It must contain the file
          <filename>configuration.nix</filename>, which must import the file
          <filename>./hardware-configuration.nix</filename>.

          The file <filename>hardware-configuration</filename> doesn't need to be
          present.  It will be created during the installation process, overwriting
          any existing file.

          If the option is null, a minimalistic default configuration is generated, which
          selects the systemd boot loader and sets the root password to "root". Logins
          are only possible on the console.  DHCP is enabled for all interfaces.
        '';
      };

      nixpkgs = {
        path = mkOption {
          type = types.path;
          default = <nixpkgs>;
          example = literalExample ''
            nixpkgs.path = builtins.path { path = ./nixpkgs; };
          '';
          description = ''
            A store path that contains a complete nixpkgs source tree
            from which the configuration of the install client is
            derived.  This can either be an existing NixOS channel
            named or a checkout of a Git repository.
          '';
        };
        stableBranch = mkOption {
          type = types.bool;
          default = true;
          description = ''
            If <option>nixpkgs.path</option> is a Git repository, it will be
            transformed into a NixOS channel.  Part of this process is the generation of the
            file <filename>.version-suffix</filename> from the Git revision.
            The version suffix starts with a dot if this option is set to true, otherwise it
            starts with the string "pre" to indicate a pre-release.  It should be set to true
            when the Git repository is a checkout of one of the stable nixpkgs release branches.

            If <option>nixpkgs.path</option> is a channel, this option is ignored.
          '';
        };
      };

      system = mkOption {
        type = types.str;
        default = builtins.currentSystem;
        example = literalExample ''
          system = "x86_64-linux"
        '';
        description = ''
          The system type for which to build the configration to be installed on
          the client.
        '';
      };

      additionalPkgs = mkOption {
        type = types.listOf types.package;
        default = [];
        example = literalExample ''
          additionalPkgs = with (import nixpkgs.path {
            inherit installImage.system;
          }).pkgs; [ foo bar ];
        '';
        description = ''
          A list of packages whose closures will be added to that of the system
          derived from  <option>nixpkgs.path</option> and <option>nixosConfigDir</option>.
          Care must be taken to properly reference packages from the context of
          <option>nixpkgs.path</option> as illustrated by the example.
        '';
      };

      binaryCacheURL = mkOption {
        type = types.str;
        default = https://cache.nixos.org/;
        description = ''
          The URL of the binary cache to register for the nixos channel derived from
          <option>nixpkgs.path</option>.
        '';
      };

      installerUseBinaryCache = mkOption {
        type = types.bool;
	default = true;
	description = ''
	  Whether to use the binary cache when activating the final configuration
	  on the install target.  This is required if some packages needed for the
	  system activation cannot be created locally.  The option must be set
	  to false if the install target is unable to reach the binary cache,
	  irrespective of whether the cache is needed or not.  This is because
	  nixos-rebuild tries to query the cache for its properties unconditionally.
	'';
      };

      rootDevice = mkOption {
        type = types.str;
        default = "/dev/sda";
        description = ''
          This option specifies the disk to use for the installation.  The installer
          will use the entire disk for the NixOS system.  It creates two partitions,
          one of type VFAT to hold the EFI boot files of size 512MiB, the other of type
          EXT4 to hold the NixOS system.  The disk will be overwritten unconditionally.
        '';
      };

      partitionSeparator = mkOption {
        type = types.str;
        default = "";
        description = ''
          The traditional convention for device names of disk partitions is to
          append a number to the name of the device, e.g. /dev/sda1, /dev/sda2.  Some
          devices started to use numbers in their names, making this scheme ambiguous.
          The solution is to insert a letter between the device name and the partition
          number, usually 'p'.  The <option>partitionSeparator</option> makes this
          configurable for the rootDevice.
        '';
      };

      serial = {
        unit = mkOption {
          type = types.int;
          default = 0;
          description = ''
            The unit number of the serial device to use for the boot loader and
            the kernel console.
          '';
        };

        linuxConsoleSpeed = mkOption {
	  type = types.str;
	  default = "115200n8";
	  description = ''
	    Serial console setting in the format <speed><parity><bits> as expected
	    by the console Linux kernel option.
	  '';
	};
      };

    };
  };

  config = {

    ## Provide access to the build products
    system.build.installImage = {
      inherit tarball channel;
      config = installConfig;
    };
  };
}
