// Based on https://github.com/napina/jai_cgltf
#import "BuildCpp";
#import "Basic";
#import "Compiler";

Build :: ()
{
  extra := #ifx OS == .WINDOWS {
    string.["/Isrc", "/D_CRT_SECURE_NO_WARNINGS"];
  } else {
    string.["-Isrc", "-D_CRT_SECURE_NO_WARNINGS"];
  }

  build_cpp_static_lib("cgltf", "cgltf.cpp", working_directory="libs/cgltf", extra=extra);
};
