cmake_minimum_required(VERSION 3.24)

# usd_ms.dll de Blender est en CRT Release (/MD) : pas de configuration Debug.
set(CMAKE_CONFIGURATION_TYPES "Release;RelWithDebInfo" CACHE STRING "" FORCE)

# C : requis par la config CMake de zfp (find_package(OpenMP COMPONENTS C)).
project(rdc VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
    # __cplusplus correct (NanoVDB s'en sert pour choisir invoke_result) et
    # sources lues en UTF-8.
    add_compile_options(
        "$<$<COMPILE_LANGUAGE:C,CXX>:/Zc:__cplusplus;/utf-8>"
        "$<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/Zc:__cplusplus,/utf-8>"
    )
endif()

# Bibliothèques précompilées de Blender (USD 25.08, namespace pxrBlender_v25_08).
# Récupérées par sparse checkout du tag v5.0.1 de lib-windows_x64.
set(RDC_BLENDER_LIBS "${CMAKE_SOURCE_DIR}/external/lib-windows_x64"
    CACHE PATH "Racine des libs précompilées de Blender 5.0.1")

option(RDC_BUILD_USD_PLUGIN "Plugin USD SdfFileFormat .rdc" ON)
option(RDC_BUILD_TOOLS "Outils de vérification (depcheck, gpucheck)" ON)
option(RDC_ENABLE_CUDA "Code CUDA (RTX 4060 : sm_89)" ON)

if(RDC_ENABLE_CUDA)
    set(CMAKE_CUDA_ARCHITECTURES 89)
    set(CMAKE_CUDA_STANDARD 20)
    set(CMAKE_CUDA_STANDARD_REQUIRED ON)
    enable_language(CUDA)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

# Le plugin USD tourne dans Blender : il ne doit dépendre ni de vcpkg/TBB
# (conflit avec le tbb12.dll de Blender) ni d'OpenVDB.
if(RDC_BUILD_USD_PLUGIN)
    include(BlenderUsd)
    add_subdirectory(src/usd_plugin)
endif()

if(RDC_BUILD_TOOLS)
    add_subdirectory(tools)
endif()
