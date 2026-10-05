cmake_minimum_required(VERSION 3.22)

project(kx1 CXX C)

if(NOT TARGET SDL3::SDL3)
    find_package(SDL3 CONFIG)
endif()

if(NOT TARGET SDL3::SDL3)
    find_library(SDL3_LIBRARY NAMES "SDL3")
    find_path(SDL3_INCLUDE_DIR NAMES "SDL3/SDL.h")
    add_library(SDL3::SDL3 UNKNOWN IMPORTED)
    set_property(TARGET SDL3::SDL3 PROPERTY IMPORTED_LOCATION "${SDL3_LIBRARY}")
    set_property(TARGET SDL3::SDL3 PROPERTY INTERFACE_INCLUDE_DIRECTORIES "${SDL3_INCLUDE_DIR}")
endif()

if(NOT TARGET SDL3::SDL3)
    message(FATAL_ERROR "Cannot find SDL3.")
endif()

# ---- libs Skia statiques (produites par k0-android/scripts/build_skia.sh) ----
set(KX_SKIA_OUT "" CACHE PATH "répertoire out/android-<arch> du build skia")
if(NOT KX_SKIA_OUT)
    set(KX_SKIA_OUT "$ENV{KX_SKIA_OUT}")
endif()
if(NOT KX_SKIA_OUT)
    message(FATAL_ERROR "KX_SKIA_OUT manquant (ex. ~/kx/deps/skia/out/android-x64)")
endif()
get_filename_component(KX_SKIA_DIR "${KX_SKIA_OUT}/../.." ABSOLUTE)

set(KX_SKIA_LIBS
    skia skparagraph skshaper skunicode_core skunicode_icu
    harfbuzz freetype2 png jpeg jpeg12 jpeg16 skcms raw_ptr
    cpu-features expat allocator_base allocator_core)

set(KX_SKIA_LIB_TARGETS "")
foreach(name IN LISTS KX_SKIA_LIBS)
    if(EXISTS "${KX_SKIA_OUT}/lib${name}.a")
        add_library(kx_${name} STATIC IMPORTED GLOBAL)
        set_property(TARGET kx_${name} PROPERTY IMPORTED_LOCATION
                     "${KX_SKIA_OUT}/lib${name}.a")
        list(APPEND KX_SKIA_LIB_TARGETS kx_${name})
    endif()
endforeach()

# gallery.o : objet zig 0.17 pré-compilé par scripts/build_k3.sh
set(GALLERY_OBJ "${CMAKE_CURRENT_SOURCE_DIR}/gallery.o")
if(NOT EXISTS "${GALLERY_OBJ}")
    message(FATAL_ERROR "gallery.o manquant — lancer scripts/build_k3.sh (zig build-obj)")
endif()

add_library(main SHARED
    kx_gallery_glue.cpp
    kx/kx_skia_android.cpp
    kx/kx_scenes.cpp
    kx/kx_draw.cpp
    "${GALLERY_OBJ}"
)
set_source_files_properties("${GALLERY_OBJ}" PROPERTIES EXTERNAL_OBJECT true GENERATED true)

set_source_files_properties(kx/kx_skia_android.cpp kx/kx_scenes.cpp kx/kx_draw.cpp
    PROPERTIES COMPILE_OPTIONS "-fno-exceptions;-fno-rtti")

target_include_directories(main PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${KX_SKIA_DIR}
    ${KX_SKIA_DIR}/third_party/externals/vulkan-headers/include
    ${KX_SKIA_DIR}/third_party/externals/vulkanmemoryallocator/include)

target_compile_features(main PRIVATE cxx_std_20)
target_compile_definitions(main PRIVATE
    SK_GANESH SK_GRAPHITE SK_USE_PERFETTO=0 VK_USE_PLATFORM_ANDROID_KHR)
target_compile_options(main PRIVATE -fvisibility=hidden)
# gallery.o est PIC (zig -fPIC)
set_property(TARGET main PROPERTY LINK_DEPENDS "${GALLERY_OBJ}")

target_link_libraries(main PRIVATE
    SDL3::SDL3
    -Wl,--start-group ${KX_SKIA_LIB_TARGETS} -Wl,--end-group
    EGL GLESv3 log dl m z android icu jnigraphics
    -Wl,-u,kx_gallery_main)

# 16KiB page-size (API35+) — alignement ELF 16K.
target_link_options(main PRIVATE -Wl,-z,max-page-size=16384)
