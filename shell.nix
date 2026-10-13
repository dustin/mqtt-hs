{ pkgs ? import <nixpkgs> { } }:
with pkgs;
let
  hpkgs = haskellPackages;
  ghcWithDeps = hpkgs.ghcWithPackages (p: with p; [
    async
    attoparsec
    attoparsec-binary
    binary
    bytestring
    conduit
    conduit-extra
    containers
    crypton-connection
    data-default-class
    deepseq
    monad-loops
    network-conduit-tls
    network-uri
    optparse-applicative
    QuickCheck
    stm
    text
    time
    websockets
    # test deps
    checkers
    HUnit
    lens
    mtl
    tasty
    tasty-discover
    tasty-hunit
    tasty-quickcheck
  ]);
in
mkShell {
  buildInputs = [
    ghcWithDeps
    stylish-haskell
    hlint
    ghcid
    hpkgs.haskell-language-server
    hpkgs.tasty-discover
    cabal-install
    hpack
    zlib
  ];

  shellHook = ''
    # ...
  '';
}
