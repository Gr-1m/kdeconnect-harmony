# SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# 全 Rust 原生栈（2026-11-07 切换）。
#
# 目标：把 `rust/full/napi`（ohos-rs cdylib）构建为 `libkdeconnect_napi.so`，
# 输出到 hvigor 约定的 `intermediates/cmake/.../obj/<abi>/`。
#
# 与旧 C++ 构建的差异：
#   - 不再编译 bearssl/ json/ net/ napi/（这些目录保留作行为对照，逐步删除）；
#   - 交叉工具链仍来自 hvigor 传入的 OHOS NDK（BiSheng/OpenHarmony 均可）；
#   - ring 的 C 部分必须用目标 clang 编译，否则 aarch64 链接会报 architecture mismatch。
#
# 环境变量（均从 hvigor/CMake 已知路径推导，不写死本机路径）：
#   OHOS_NDK       = <sdk>/native           （clang/sysroot 根）
#   OHOS_NDK_HOME  = <sdk>                  （napi-build-ohos 需要）
#   CC_<triple> / AR_<triple>               （ring 交叉编译）
#   CARGO_TARGET_<TRIPLE>_LINKER            （rustc 链接驱动）

cmake_minimum_required(VERSION 3.5.0)
project(kdeconnect_napi_full_rust)

# hvigor 的 CMake 工具链传入 OHOS_SDK_NATIVE=<sdk>/native；旧变量 NATIVEROUTER
# 在本机配置下为空，必须优先用前者。
# Windows 兼容：Windows 上 clang 的实际文件名为 clang.exe，旧写法 EXISTS ".../clang" 恒假
# ⇒ 配置阶段直接落到 FATAL_ERROR（DevEco Win10 实测）。故两处分支都同时判 .exe。
if(DEFINED OHOS_SDK_NATIVE AND (EXISTS "${OHOS_SDK_NATIVE}/llvm/bin/clang" OR EXISTS "${OHOS_SDK_NATIVE}/llvm/bin/clang.exe"))
    set(OHOS_NDK_DIR "${OHOS_SDK_NATIVE}")
elseif(DEFINED NATIVEROUTER AND (EXISTS "${NATIVEROUTER}/llvm/bin/clang" OR EXISTS "${NATIVEROUTER}/llvm/bin/clang.exe"))
    set(OHOS_NDK_DIR "${NATIVEROUTER}")
elseif(DEFINED NATIVEROUTER)
    get_filename_component(OHOS_NDK_DIR "${NATIVEROUTER}" DIRECTORY)
else()
    message(FATAL_ERROR "未找到 OHOS SDK native 目录（OHOS_SDK_NATIVE/NATIVEROUTER 均为空）")
endif()
get_filename_component(OHOS_SDK_ROOT "${OHOS_NDK_DIR}" DIRECTORY)
set(RUST_SYSROOT "${OHOS_NDK_DIR}/sysroot")

if(NOT (EXISTS "${OHOS_NDK_DIR}/llvm/bin/clang" OR EXISTS "${OHOS_NDK_DIR}/llvm/bin/clang.exe"))
    message(FATAL_ERROR "OHOS clang not found under ${OHOS_NDK_DIR}/llvm/bin/ (clang / clang.exe both missing)")
endif()

set(RUST_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/napi/Cargo.toml")
set(RUST_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/rust-target")

if(OHOS_ARCH STREQUAL "arm64-v8a" OR CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    set(RUST_TARGET "aarch64-unknown-linux-ohos")
    set(RUST_TRIPLE_ENV "aarch64_unknown_linux_ohos")
    set(RUST_TRIPLE_UPPER "AARCH64_UNKNOWN_LINUX_OHOS")
    set(RUST_CLANG_TARGET "aarch64-linux-ohos")
    set(RUST_LLVM_LIB_DIR "aarch64-linux-ohos")
elseif(OHOS_ARCH STREQUAL "x86_64" OR CMAKE_ANDROID_ARCH_ABI STREQUAL "x86_64")
    set(RUST_TARGET "x86_64-unknown-linux-ohos")
    set(RUST_TRIPLE_ENV "x86_64_unknown_linux_ohos")
    set(RUST_TRIPLE_UPPER "X86_64_UNKNOWN_LINUX_OHOS")
    set(RUST_CLANG_TARGET "x86_64-linux-ohos")
    set(RUST_LLVM_LIB_DIR "x86_64-linux-ohos")
else()
    message(FATAL_ERROR "unsupported ABI for Rust build: OHOS_ARCH=${OHOS_ARCH} ABI=${CMAKE_ANDROID_ARCH_ABI}")
endif()

find_program(RUST_CARGO_EXECUTABLE cargo)
if(NOT RUST_CARGO_EXECUTABLE)
    message(FATAL_ERROR
        "找不到 cargo：全 Rust 原生栈需要 Rust 工具链。安装：rustup-init -y --profile minimal "
        "--no-modify-path --default-toolchain stable && rustup target add "
        "aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos；详见 rust/README.md。")
endif()

set(RUST_SO "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}/libkdeconnect_napi.so")
set(RUST_BUILT_SO "${RUST_TARGET_DIR}/${RUST_TARGET}/release/libkdeconnect_napi.so")
set(RUST_WRAPPER "${CMAKE_CURRENT_SOURCE_DIR}/rust/wrappers/${RUST_CLANG_TARGET}-clang")
set(RUST_CLANG "${OHOS_NDK_DIR}/llvm/bin/clang")
set(RUST_LLVM_AR "${OHOS_NDK_DIR}/llvm/bin/llvm-ar")

file(GLOB_RECURSE RUST_SRCS CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/core/src/*.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/napi/src/*.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/core/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/napi/Cargo.toml"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/full/napi/build.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/kdc_core/src/*.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/rust/kdc_core/Cargo.toml"
)

add_custom_command(
    OUTPUT "${RUST_SO}"
    COMMAND ${CMAKE_COMMAND} -E env
        "OHOS_NDK=${OHOS_NDK_DIR}"
        "OHOS_NDK_HOME=${OHOS_SDK_ROOT}"
        "CC_${RUST_TRIPLE_ENV}=${RUST_CLANG} --target=${RUST_CLANG_TARGET} --sysroot=${RUST_SYSROOT} -D__MUSL__"
        "AR_${RUST_TRIPLE_ENV}=${RUST_LLVM_AR}"
        "CARGO_TARGET_${RUST_TRIPLE_UPPER}_LINKER=${RUST_WRAPPER}"
        "${RUST_CARGO_EXECUTABLE}" build --release
            --manifest-path "${RUST_MANIFEST}"
            --target "${RUST_TARGET}"
            --target-dir "${RUST_TARGET_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${RUST_BUILT_SO}" "${RUST_SO}"
    DEPENDS ${RUST_SRCS}
    COMMENT "cargo build kdeconnect_napi (${RUST_TARGET})"
    VERBATIM
)

add_custom_target(kdeconnect_napi ALL DEPENDS "${RUST_SO}")
