# Cible importée blender::usd : USD monolithique livré avec Blender 5.0.1.
#
# On n'utilise pas usd/pxrConfig.cmake : il exige MaterialX, Imath, Vulkan,
# OpenSubdiv... alors que le plugin n'a besoin que de Sdf/Tf/Vt.
# Le plugin doit utiliser le CRT Release (/MD) comme usd_ms.dll : seules les
# configurations Release et RelWithDebInfo sont supportées.

set(_usd    "${RDC_BLENDER_LIBS}/usd")
set(_tbb    "${RDC_BLENDER_LIBS}/tbb")
set(_python "${RDC_BLENDER_LIBS}/python/311")

foreach(_f "${_usd}/include/pxr/pxr.h" "${_usd}/lib/usd_ms.lib"
           "${_tbb}/lib/tbb12.lib" "${_python}/libs/python311.lib")
    if(NOT EXISTS "${_f}")
        message(FATAL_ERROR "Libs Blender introuvables : ${_f}\n"
            "Voir README : sparse checkout de lib-windows_x64 au tag v5.0.1.")
    endif()
endforeach()

add_library(blender::usd SHARED IMPORTED GLOBAL)
set_target_properties(blender::usd PROPERTIES
    IMPORTED_IMPLIB   "${_usd}/lib/usd_ms.lib"
    IMPORTED_LOCATION "${_usd}/lib/usd_ms.dll"
    INTERFACE_INCLUDE_DIRECTORIES "${_usd}/include;${_tbb}/include;${_python}/include"
    # tbb et python se lient automatiquement via #pragma comment(lib, ...)
    INTERFACE_LINK_DIRECTORIES "${_tbb}/lib;${_python}/libs"
    INTERFACE_COMPILE_DEFINITIONS "NOMINMAX;WIN32_LEAN_AND_MEAN;_CRT_SECURE_NO_WARNINGS"
    # Mêmes options MSVC que le build USD (registres Tf, gros objets).
    INTERFACE_COMPILE_OPTIONS "/Zc:inline-;/Zc:rvalueCast;/bigobj;/EHsc;/Zc:__cplusplus"
)
