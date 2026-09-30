# A game that takes the installed SDK through find_package, as CI builds it:
#
#   cmake --install build --prefix /tmp/gamend
#   cmake -S tests/package -B build-package -DCMAKE_PREFIX_PATH=/tmp/gamend
#   cmake --build build-package
#
# It builds the conformance example, so it needs the curl and IXWebSocket
# transports.
cmake_minimum_required(VERSION 3.20)
project(gamend_package_test LANGUAGES CXX)

find_package(gamend CONFIG REQUIRED)

add_executable(gamend_package_test ../../examples/conformance.cpp)
target_link_libraries(gamend_package_test PRIVATE gamend::gamend)
if(MSVC)
  target_compile_definitions(gamend_package_test PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()
