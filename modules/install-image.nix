# This module creates a tarball that contains a complete NixOS system
# for installation via the generic PXE-based installer provided
# by installer-nfsroot.nix.  It produces the following derivations in
# the attribute set config.system.build.installImage
#
#   tarball
#     The tarball itself.  It will be unpacked onto the
#     clients root partition
#   config
#     A shell script that defines some variables which
#     propagate configuration settings from the installImage
#     options to the installation process
#   channel
#     A regular NixOS channel created from installImage.nixpkgs.path
#     by <nix/unpack-channel.nix>
#
{ config, lib, pkgs, ... }:

with pkgs;
with lib;
with builtins;

let

  ## Hack to check assertions even when not building the system
  ## configuration.
  failed = map (x: x.message) (filter (x: !x.assertion) config.assertions);

  ## Construct a derivation that contains the nixos channel from the
  ## nixpkgs expression provided by installImage.nixpkgs.path.  If
  ## that directory is a store path, make sure that it contains the
  ## "nixos" channel or bail out.  Otherwise, create a derivation that
  ## contains a copy of that store path.  The URL for the binary cache
  ## assiciated with the channel is preserved.
  ##
  ## If the directory is not a store path, check whether it is a Git
  ## repository and bail out if it isn't.  Otherwise we assume that it
  ## is a checkout that contains some version of nixpkgs and construct
  ## the "revCount" and "shortRev" attributes for HEAD just like hydra
  ## would for an input of type "Git checkout".  Then create a pseudo
  ## derivation of nixpkgs from it, suitable for passing to
  ## nixos/release.nix to produce a source tarball of that particular
  ## nixpkgs expression containing the proper .version-suffix file.
  ## This tarball is then run through <nix/unpack-channel.nix> to
  ## produce a derivation containing a regular channel named "nixos".
  ## The URL of the binary cache associated with this channel is taken
  ## from the configuration option installImage.binaryCacheURL.
  ##
  ## In either case we end up with a derivation for a channel named
  ## "nixos" which contains the relevant nixpkgs source and will be
  ## installed on the target system as the initial channel.

  cfg = config.installImage;
  nixpkgs = toPath cfg.nixpkgs.path;
  isNixosChannel = path:
    if isStorePath (dirOf (dirOf path)) then
      let channelName = baseNameOf (dirOf path); in
      if channelName == "nixos" then
        true
      else
        throw "expected channel \"nixos\", got ${channelName} in store path ${path}"
    else
      false;

  channel = if isNixosChannel nixpkgs then
    ## Create a copy of the channel store path as
    ## a derivation
    let
      path = dirOf (storePath nixpkgs);
      name = builtins.unsafeDiscardStringContext (builtins.substring 33 (-1) (baseNameOf path));
    in runCommand "${name}"
      { preferLocalBuild = true; }
      ''
        mkdir $out
        cd ${path} && tar cf - . | (cd $out && tar xpf -)
      ''
  else
    let
      nixpkgsRevs = if pathExists (nixpkgs + "/.git") then
        import (runCommand "get-rev-count"
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
          '')
        else
          throw "${storePath nixpkgs} is neither a NixOS channel nor a Git repository";

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
      ## Construct the full path to the tarball in the Nix store and derive the
      ## name of the release from it
      channelTarPath = builtins.unsafeDiscardStringContext (channelSrc + "/tarballs/"
        + (head (attrNames (readDir (channelSrc + "/tarballs")))));
      releaseName = removeSuffix ".tar.xz" (baseNameOf channelTarPath);

    in import <nix/unpack-channel.nix> {
      channelName = "nixos";
      name = "${releaseName}";
      src = channelTarPath;
      inherit (cfg) binaryCacheURL;
    };

  tarball = import ../lib/make-install-image.nix rec {
    inherit pkgs lib channel;
    inherit (cfg) nixosConfigDir additionalPkgs system;
    tarballName = "nixos.tar.gz";
    memSize = 4096;

    postVM =
      ''
        mv xchg/${tarballName} $out
      '';
  };

  installConfig = runCommand "install-config"
    {}
    ''
      mkdir $out
      cat >$out/config <<EOF
      rootDevice=${cfg.rootDevice}
      useDHCP=${if cfg.networking.useDHCP then "1" else ""}
      staticInterfaceFromDHCP=${cfg.networking.staticInterfaceFromDHCP}
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
          that will be installed on the client.  It must contain the file
          <filename>configuration.nix</filename>, which must import the file
          <filename>./hardware-configuration.nix</filename> and should import
          <filename>./networking</filename>, if the automatic network configuration
          provided by the <option>useDHCP</option> and <option>staticInterfaceFromDHCP</option>
          options is used.

          The file <filename>hardware-configuration</filename> doesn't need to be
          present.  It will be created during the installation process, overwriting
          any existing file.

          If the option is null, an empty configuration directory will be created and
          populated by "nixos-generate-config" when the client system is installed.
        '';
      };

      nixpkgs = {
        path = mkOption {
          type = types.path;
          default = <nixpkgs>;
          example = literalExample ''
            nixpkgs = ./nixpkgs
          '';
          description = ''
            The path to a directory that contains a complete nixpkgs source tree from
            which the configuration of the install client is derived.  This can either be
            a checkout of a Git repository or a NixOS channel named "nixos".  The former will be
            transformed into a channel named "nixos" before further processing.
          '';
        };
        stableBranch = mkOption {
          type = types.bool;
          default = true;
          description = ''
            If <option>installImage.nixpkgs.path</option> is a Git repository, it will be
            transformed into a NixOS channel.  Part of this process is the generation of the
            file <filename>.version-suffix</filename> from the Git revision via "git describe".
            The version suffix starts with a dot if this option is set to true, otherwise it
            starts with the string "pre" to indicate a pre-release.
          '';
        };
      };

      system = mkOption {
        type = types.str;
        default = builtins.currentSystem;
        description = ''
          The system type for which to build the configration to be installed on
          the client.
        '';
      };

      additionalPkgs = mkOption {
        type = types.listOf types.package;
        default = [];
        description = ''
          A list of packages whose closures will be added to that of the system
          specified by the configuration in option
          <option>installImage.nixosConfigDir</option>.
        '';
      };

      binaryCacheURL = mkOption {
        type = types.str;
        default = https://cache.nixos.org/;
        description = ''
          The URL of the binary cache to register for the nixos channel of the
          system if the channel is derived from a Git checkout if nixpkgs.  This
          option is ignored if <option>installImage.nixpkgs.path</option> refers
          to an existing channel.  In that case, the URL of the binary cache of
          that channel is preserved.
        '';
      };

      rootDevice = mkOption {
        default = "/dev/sda";
        example = "/dev/sda";
        description = ''
          This option specifies the disk to use for the installation.  The installer
          will use the entire disk for the NixOS system.  It creates two partitions,
          one of type VFAT to hold the EFI boot files of size 512MiB, the other of type
          EXT4 to hold the NixOS system.  The disk will be overwritten unconditionally.
        '';
      };

      networking = {
        useDHCP = mkOption {
          type = types.bool;
          default = true;
          description = ''
            If set to true, the installed system will use DHCP on all available
            interfaces.  If set to false, a static configuration is created according
            to the option <option>staticInterfaceFromDHCP</option>.
          '';
        };
        staticInterfaceFromDHCP = mkOption {
          type = types.str;
          default = "";
          example = "enp1s0";
          description = ''
            If <option>useDHCP</option> is false, a static interface configuration will
            be created for the interface specified in this option. The IP address, netmask
            and default gateway are taken from the DHCP information obtained during the
            installation process.
          '';
        };
      };
    };
  };

  config = {

    assertions = [
      { assertion = cfg.networking.useDHCP == false -> cfg.networking.staticInterfaceFromDHCP != "";
        message = "installImage: Static network configuration requested but no interface " +
                  "specified in staticInterfaceFromDHCP";
      }
    ];

    ## Dummies to make forced assertions succeed
    fileSystems."/".device = "/none";
    boot.loader.grub.device = "/none";

    ## Provide access to the build products
    system.build.installImage = if failed == [] then {
      inherit tarball channel;
      config = installConfig;
    } else
      throw "\nFailed assertions:\n${concatStringsSep "\n" (map (x: "- ${x}") failed)}";
  };
}
