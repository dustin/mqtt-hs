{ compiler ? "ghc884" }:

let
  nixpkgs = builtins.fetchTarball {
    # nixpkgs release 21.11
    # url: <https://github.com/NixOS/nixpkgs/releases/tag/21.11>
    url = "https://github.com/NixOS/nixpkgs/archive/refs/tags/21.11.tar.gz";
    sha256 = "162dywda2dvfj1248afxc45kcrg83appjd0nmdb541hl7rnncf02";
  };

  config = { };

  overlay = pkgsNew: pkgsOld: {
    haskell = pkgsOld.haskell // {
      packages = pkgsOld.haskell.packages // {
        "${compiler}" = pkgsOld.haskell.packages."${compiler}".override (old: {
          overrides = let
            packageSources =
              pkgsNew.haskell.lib.packageSourceOverrides { "mqtt-net" = ./.; };

            manualOverrides = haskellPackagesNew: haskellPackagesOld: { };

            default = old.overrides or (_: _: { });

          in pkgsNew.lib.fold pkgsNew.lib.composeExtensions default [
            packageSources
            manualOverrides
          ];
        });
      };
    };
  };

  pkgs = import nixpkgs {
    inherit config;
    overlays = [ overlay ];
  };

in {
  inherit (pkgs.haskell.packages."${compiler}") mqtt-net;

  shell = (pkgs.haskell.packages."${compiler}".mqtt-net).env;
}
