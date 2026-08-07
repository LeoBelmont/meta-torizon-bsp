# This fork (nxp-imx/ethos-u-driver-stack-imx) still declares
# cmake_minimum_required(VERSION 3.0.2), which CMake >= 4.0 rejects outright.
EXTRA_OECMAKE += "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
