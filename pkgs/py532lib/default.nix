{ buildPythonPackage, fetchPypi }:

buildPythonPackage rec {
  pname = "py532lib";
  version = "2018.6.14.dev1";
  format = "wheel";

  src = fetchPypi {
    inherit pname version;
    format = "wheel";
    dist = "py3";
    python = "py3";
    hash = ""; # first build prints the real one
  };

  doCheck = false; # no tests in the wheel
  pythonImportsCheck = [ "py532lib.mifare" ];
}
