cmake_minimum_required(VERSION 3.16)
project(ApogeeSymIO VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")
set(CMAKE_OSX_ARCHITECTURES "arm64")

# Fetch libASPL from GitHub
include(FetchContent)
FetchContent_Declare(
    libASPL
    GIT_REPOSITORY https://github.com/gavv/libASPL.git
    GIT_TAG 633e0f70203edd87d320fc5a3cae901e1363aac5
)
FetchContent_MakeAvailable(libASPL)

# Reuse the app artwork for the CoreAudio device icon.
set(MAESTRO_DEVICE_ICON "${CMAKE_CURRENT_SOURCE_DIR}/../../Apps/Maestro/MaestroApp/Resources/AppIconRounded.icns")
set_source_files_properties("${MAESTRO_DEVICE_ICON}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

# Plugin source files
add_library(ApogeeSymIO MODULE
    ApogeeDriver.cpp
    "${MAESTRO_DEVICE_ICON}"
)

# Include libASPL private headers so we can subclass VolumeControl.
# VolumeCurve is a forward declaration in the public header; the full definition
# is in src/VolumeCurve.hpp. Without it, std::unique_ptr<VolumeCurve> cannot
# be destructed in our ApogeeVolumeControl subclass.
target_include_directories(ApogeeSymIO PRIVATE
    ${libaspl_SOURCE_DIR}/src
    # Shared shmem contract, compiled by MaestroVolumeProxy too so the two
    # views of the shared memory cannot drift apart.
    ${CMAKE_CURRENT_SOURCE_DIR}/../Shared
)

# Link libASPL and system frameworks
target_link_libraries(ApogeeSymIO
    PRIVATE
        libASPL
        "-framework CoreAudio"
        "-framework CoreFoundation"
        "-framework IOKit"
)

# Configure as a .driver bundle (AudioServerPlugin)
set_target_properties(ApogeeSymIO PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    PREFIX ""
    SUFFIX ""
)
