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
# ---------------------------------------------------------------------------
# 宿主工具选择（Windows 修正 v2，2026-11-09；由 Win10 远程实测驱动）
# ① 本工程**交叉编译**到 OHOS（CMakeCache: `CMAKE_SYSTEM_NAME=OHOS`）⇒ CMake 的 `WIN32` 恒为
#    FALSE，`if(WIN32)` 分支永不生效（v1 静默失效的根因）。故一律按「磁盘上实际存在哪个可执行
#    文件」判定（`clang.exe` ↔ `clang`），宿主无关、不会误判。
# ② cc-rs / cargo 会把 `CC_/AR_/RUSTFLAGS` 的取值**按空格切分**，而 Windows 上 SDK 默认装在
#    `C:\Program Files\…`（含空格）⇒ 需要一个**无空格等价根**（llvm 与 sysroot 都要 relocate）：
#      cmd /c mklink /J C:\Users\<user>\ohos-llvm "<sdk>\default\openharmony\native"
#      setx OHOS_LLVM_LINK C:\Users\<user>\ohos-llvm        # 指向 native（内含 llvm/ 与 sysroot/）
#    设了它 → 由它派生 `${link}/llvm` 与 `${link}/sysroot`（随之为无空格路径）；未设 → 用 SDK 原路径。
# ③ Windows 宿主上若最终路径仍含空格 → 直接 FATAL：否则会在 ring 的 cc-rs 编译期抛出很难懂的
#    `failed to find tool "C:/Program"`（初次踩坑耗时 20+ 分钟）。
# ---------------------------------------------------------------------------
set(RUST_NDK_ROOT "${OHOS_NDK_DIR}")
if(DEFINED ENV{OHOS_LLVM_LINK}
   AND (EXISTS "$ENV{OHOS_LLVM_LINK}/llvm/bin/clang" OR EXISTS "$ENV{OHOS_LLVM_LINK}/llvm/bin/clang.exe"))
    set(RUST_NDK_ROOT "$ENV{OHOS_LLVM_LINK}")
endif()
set(RUST_LLVM_DIR "${RUST_NDK_ROOT}/llvm")
set(RUST_SYSROOT "${RUST_NDK_ROOT}/sysroot")

set(RUST_ENV_EXTRA)
if(EXISTS "${RUST_LLVM_DIR}/bin/clang.exe")
    if("${RUST_NDK_ROOT}" MATCHES " ")
        message(FATAL_ERROR
            "OHOS SDK 路径含空格（${RUST_NDK_ROOT}）⇒ cc-rs/cargo 会误切分 CC/AR/sysroot。"
            "请在 Windows 上建无空格 junction 指向 SDK 的 native 目录并设 OHOS_LLVM_LINK："
            "cmd /c mklink /J C:\\Users\\<user>\\ohos-llvm \"<sdk>\\default\\openharmony\\native\"；"
            "setx OHOS_LLVM_LINK C:\\Users\\<user>\\ohos-llvm（见 devdocs/CPP_GUIDE.md §9.2）")
    endif()
    # Windows 宿主：clang.exe/llvm-ar.exe；且无 /bin/sh ⇒ 链接器不用 sh wrapper，
    # 直接用 clang.exe，并把 wrapper 的有效参数（--target/--sysroot）以 -C link-arg 等价传入
    # （-D__MUSL__ 只在预处理期有意义，链接期无效，故不传）。
    set(RUST_CLANG "${RUST_LLVM_DIR}/bin/clang.exe")
    set(RUST_LLVM_AR "${RUST_LLVM_DIR}/bin/llvm-ar.exe")
    set(RUST_LINKER "${RUST_CLANG}")
    list(APPEND RUST_ENV_EXTRA
        "CARGO_TARGET_${RUST_TRIPLE_UPPER}_RUSTFLAGS=-C link-arg=--target=${RUST_CLANG_TARGET} -C link-arg=--sysroot=${RUST_SYSROOT}")
else()
    set(RUST_CLANG "${RUST_LLVM_DIR}/bin/clang")
    set(RUST_LLVM_AR "${RUST_LLVM_DIR}/bin/llvm-ar")
    set(RUST_LINKER "${RUST_WRAPPER}")
endif()

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
        "CARGO_TARGET_${RUST_TRIPLE_UPPER}_LINKER=${RUST_LINKER}"
        ${RUST_ENV_EXTRA}
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
