# terminAI native PTY session manager
cmake_minimum_required(VERSION 3.5.0)
project(terminAI)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(terminal SHARED terminal_napi.cpp)
target_link_libraries(terminal PUBLIC libace_napi.z.so libhilog_ndk.z.so)
