{
  buildPythonPackage,
  fetchPypi,
  setuptools,
  luma-core,
}:

buildPythonPackage rec {
  pname = "luma.oled";
  version = "3.13.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = ""; # first build prints the real one
  };

  build-system = [ setuptools ];
  dependencies = [ luma-core ];

  doCheck = false;
  pythonImportsCheck = [ "luma.oled.device" ];
}
