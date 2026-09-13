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
file(GLOB_RECURSE NET_SRCS CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/net/*.cpp ${CMAKE_CURRENT_SOURCE_DIR}/net/*.c)
file(GLOB_RECURSE NAPI_SRCS CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/napi/*.cpp)
file(GLOB_RECURSE PAYLOAD_SRCS CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/payload/*.cpp)
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

# —————— R1：Rust 静态库（rust/kdc_core = packet_io/cert_util 的 Rust 实现）——————
# PROCESS §8：Rust 产物必须接入 hvigor CMake，不另建独立构建入口 ⇒ 这里用 add_custom_command
# 调 cargo 交叉编译，再把 .a 链进同一个 .so。
# 交叉工具链见 rust/wrappers/（clang driver wrapper + llvm-ar + 说明）：
# 环境变量 CARGO_TARGET_*_LINKER / AR_* 比 .cargo/config.toml 更直接（无需 --config）。
set(RUST_CRATE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rust/kdc_core)
set(RUST_WRAPPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rust/wrappers)

if(OHOS_ARCH STREQUAL "arm64-v8a" OR CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    set(RUST_TARGET aarch64-unknown-linux-ohos)
    set(RUST_LINKER ${RUST_WRAPPER_DIR}/aarch64-linux-ohos-clang)
    set(RUST_AR_ENV AR_aarch64_unknown_linux_ohos=ohos-ar)
    set(RUST_LINKER_ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER=${RUST_LINKER})
elseif(OHOS_ARCH STREQUAL "x86_64" OR CMAKE_ANDROID_ARCH_ABI STREQUAL "x86_64")
    set(RUST_TARGET x86_64-unknown-linux-ohos)
    set(RUST_LINKER ${RUST_WRAPPER_DIR}/x86_64-linux-ohos-clang)
    set(RUST_AR_ENV AR_x86_64_unknown_linux_ohos=ohos-ar)
    set(RUST_LINKER_ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_OHOS_LINKER=${RUST_LINKER})
else()
    set(RUST_TARGET "")
endif()

if(RUST_TARGET)
    set(RUST_TARGET_DIR ${CMAKE_CURRENT_BINARY_DIR}/rust-target)
    set(RUST_LIB ${RUST_TARGET_DIR}/${RUST_TARGET}/release/libkdc_core.a)
    file(GLOB_RECURSE RUST_SRCS CONFIGURE_DEPENDS
        ${RUST_CRATE_DIR}/src/*.rs ${RUST_CRATE_DIR}/Cargo.toml)
    add_custom_command(
        OUTPUT ${RUST_LIB}
        COMMAND ${CMAKE_COMMAND} -E env
                "PATH=${RUST_WRAPPER_DIR}:$ENV{PATH}"
                ${RUST_AR_ENV}
                ${RUST_LINKER_ENV}
                cargo build --release --target ${RUST_TARGET} --target-dir ${RUST_TARGET_DIR} --manifest-path ${RUST_CRATE_DIR}/Cargo.toml
        DEPENDS ${RUST_SRCS}
        COMMENT "cargo build kdc_core (${RUST_TARGET})"
        VERBATIM
    )
    add_custom_target(kdc_core_rust DEPENDS ${RUST_LIB})
    add_library(kdc_core STATIC IMPORTED GLOBAL)
    set_target_properties(kdc_core PROPERTIES IMPORTED_LOCATION ${RUST_LIB})
    add_dependencies(kdc_core kdc_core_rust)
    target_link_libraries(kdeconnect_napi PUBLIC kdc_core)
endif()
