## Create manpages for the options of the install-image.nix and
## installer-nfsroot.nix modules
##  nix-build module-manpages.nix -A installImage && man result/share/man/man5/configuration.nix.5
##  nix-build module-manpages.nix -A installer && man result/share/man/man5/configuration.nix.5
##
let
  pkgs = (import <nixpkgs> {}).pkgs;
  eval = (import <nixpkgs/nixos/lib/eval-config.nix> {
    inherit pkgs;
    modules = [ ./modules/install-image.nix
                ./modules/installer-nfsroot.nix ];
  });
  manpage = options: (import <nixpkgs/nixos/doc/manual> {
    inherit pkgs;
    version = eval.config.system.nixosVersion;
    revision = eval.config.system.nixosRevision;
    options = options;
  }).manpages;

in
  {
    installImage = manpage eval.options.installImage;
    installer = manpage eval.options.nfsroot;
  }
