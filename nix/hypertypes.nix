{ mkDerivation, base, base-compat, base16-bytestring, binary
, constraints, containers, deepseq, fetchFromGitHub, generic-data, lattices, lens, monad-st
, mtl, one-liner, pretty, QuickCheck, show-combinators, template-haskell, th-abstraction
, transformers, stdenv, generic-constraints
}:
mkDerivation {
  pname = "hypertypes";
  version = "0.1.0.0";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "hypertypes";
    sha256 = "18lc0mh83zkqlq18pilrp5wl5h4l28b9vbrcc0cwbrxdpriqzlyv";
    rev = "47dd6d3e51b9883fa735fc5ce3555561974f0791";
  };
  libraryHaskellDepends = [
    base base-compat binary constraints containers deepseq generic-data lattices lens
    monad-st mtl one-liner pretty QuickCheck show-combinators template-haskell
    th-abstraction transformers generic-constraints
  ];
  homepage = "https://github.com/lamdu/hypertypes.git#readme";
  description = "Library for typed ASTs";
  license = stdenv.lib.licenses.bsd3;
}
