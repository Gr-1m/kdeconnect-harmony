cmake_minimum_required(VERSION 3.5.0)
project(kdeconnect_napi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_STANDARD 11)

if(NOT DEFINED NATIVEROUTER)
    set(NATIVEROUTER ${OHOS_SYSROOT_DIR})
endif()

include_directories(${NATIVEROUTER}/usr/include)

# BearSSL 0.6（MIT，官方源 bearssl.org）：src/ 下 277 个 .c 与官方 Makefile coresrc 清单一致，
# 直接 GLOB 编译为静态库（hvigor 按 ABI 分别交叉编译，无需独立脚本）。
file(GLOB_RECURSE BEARSSL_SRCS ${CMAKE_CURRENT_SOURCE_DIR}/bearssl/src/*.c)
add_library(bearssl STATIC ${BEARSSL_SRCS})
# 官方 Makefile 用 -Isrc -Iinc：inc 为公共 API，src/inner.h 为内部头（仅本库使用，PRIVATE）
target_include_directories(bearssl
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/bearssl/inc
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/bearssl/src
)
set_target_properties(bearssl PROPERTIES POSITION_INDEPENDENT_CODE ON)

# 网络栈核心（cpp/net/）与 NAPI 桥（cpp/napi/ + napi_init.cpp）均由 native agent 维护；
# 规范见 devdocs/CPP_GUIDE.md，接口契约以 cpp/types/libkdeconnect_napi/Index.d.ts 为准。
# 注意：GLOB 对新增文件需重新配置（每次 hvigor 构建都会重跑 CMake，无需手动刷新缓存）。
file(GLOB_RECURSE NET_SRCS ${CMAKE_CURRENT_SOURCE_DIR}/net/*.cpp ${CMAKE_CURRENT_SOURCE_DIR}/net/*.c)
file(GLOB_RECURSE NAPI_SRCS ${CMAKE_CURRENT_SOURCE_DIR}/napi/*.cpp)
file(GLOB_RECURSE PAYLOAD_SRCS ${CMAKE_CURRENT_SOURCE_DIR}/payload/*.cpp)
file(GLOB_RECURSE JSON_SRCS ${CMAKE_CURRENT_SOURCE_DIR}/json/*.c)

add_library(kdeconnect_napi SHARED
    napi_init.cpp
    ${JSON_SRCS}
    ${PAYLOAD_SRCS}
    ${NET_SRCS}
    ${NAPI_SRCS}
)

target_include_directories(kdeconnect_napi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(kdeconnect_napi PUBLIC
    bearssl
    libace_napi.z.so
    libhilog_ndk.z.so
)
