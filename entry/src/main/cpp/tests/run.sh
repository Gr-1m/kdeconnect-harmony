#!/usr/bin/env bash
# native host 单测构建+运行（WP-4 native 侧）。只依赖 gcc/g++/make，无需 cmake/SDK。
# BearSSL 用官方 Makefile 构建静态库（BUILD= 指到 /tmp，不污染 vendor 目录）。
# CI（.gitcode/workflows）可直接调本脚本。
set -euo pipefail
cd "$(dirname "$0")"

OUT=/tmp/kdc_native_tests
mkdir -p "$OUT"

# BearSSL 0.6 静态库（host 版；与 NDK 侧同源码，见 CMakeLists.txt）
make -s -C ../bearssl -j"$(nproc)" BUILD="$OUT/bearssl" lib
BEARSSL_LIB="$OUT/bearssl/libbearssl.a"

gcc -O1 -I../bearssl/inc -I../bearssl/src -I../json \
    -c ../json/cJSON.c -o "$OUT/cJSON.o"

# 1) 纯函数单测（proto/地址策略/证书工具）
g++ -std=c++17 -Wall -Wextra -O1 \
    -I. -I.. -Istub -I../bearssl/inc \
    test_main.cpp \
    ../net/packet_io.cpp \
    ../net/cert_util.cpp \
    ../net/cert_gen.cpp \
    ../net/net_util.cpp \
    "$OUT/cJSON.o" "$BEARSSL_LIB" \
    -o "$OUT/kdc_native_tests"

"$OUT/kdc_native_tests"

# 2) payload 集成测试（真实 PayloadManager + TlsEngine + 假宿主）
g++ -std=c++17 -Wall -Wextra -O1 \
    -I. -I.. -Istub -I../bearssl/inc \
    payload_e2e.cpp \
    ../payload/payload.cpp \
    ../net/tls_engine.cpp \
    ../net/tcp_connection.cpp \
    ../net/cert_gen.cpp \
    ../net/cert_util.cpp \
    ../net/net_util.cpp \
    ../net/packet_io.cpp \
    "$OUT/cJSON.o" "$BEARSSL_LIB" \
    -lpthread \
    -o "$OUT/kdc_payload_tests"

# 3) net 栈测试（连接失败可解释性 + 有界握手；不需局域网/设备）
g++ -std=c++17 -Wall -Wextra -O1 \
    -I. -I.. -Istub -I../bearssl/inc \
    net_stack_tests.cpp \
    ../net/net_stack.cpp \
    ../net/tcp_connection.cpp \
    ../net/tcp_server.cpp \
    ../net/udp_discovery.cpp \
    ../net/tls_engine.cpp \
    ../net/cert_gen.cpp \
    ../net/cert_util.cpp \
    ../net/net_util.cpp \
    ../net/packet_io.cpp \
    ../payload/payload.cpp \
    "$OUT/cJSON.o" "$BEARSSL_LIB" \
    -lpthread \
    -o "$OUT/kdc_net_tests"

"$OUT/kdc_net_tests"

"$OUT/kdc_payload_tests"
