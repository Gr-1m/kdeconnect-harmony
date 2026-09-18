#!/usr/bin/env bash
# native host 单测构建+运行（WP-4 native 侧）。只依赖 gcc/g++/make，无需 cmake/SDK。
# BearSSL 用官方 Makefile 构建静态库（BUILD= 指到 /tmp，不污染 vendor 目录）。
# CI（.gitcode/workflows）可直接调本脚本。
set -euo pipefail
cd "$(dirname "$0")"

OUT=/tmp/kdc_native_tests
mkdir -p "$OUT"

# R1：packet_io / cert_util 的实现已迁到 Rust（rust/kdc_core），C++ 侧是薄 shim
# ⇒ 先构建 host 静态库，再把 .a 链进每个测试二进制（脚本把路径打到 stdout）。
RUST_LIB="$(../rust/build_host.sh)"
echo "[run.sh] rust staticlib: $RUST_LIB"

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
    "$OUT/cJSON.o" "$BEARSSL_LIB" "$RUST_LIB" \
    -lpthread -ldl -lm \
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
    "$OUT/cJSON.o" "$BEARSSL_LIB" "$RUST_LIB" \
    -lpthread -ldl -lm \
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
    "$OUT/cJSON.o" "$BEARSSL_LIB" "$RUST_LIB" \
    -lpthread -ldl -lm \
    -o "$OUT/kdc_net_tests"

"$OUT/kdc_net_tests"

"$OUT/kdc_payload_tests"

# —— S5-a 不变量：每个头文件必须能**独立编译**（自带所需依赖），否则拆 TU/新增 TU 会随机编译失败 ——
# 排除 napi_exports.h：它依赖 SDK 的 napi/native_api.h（宿主无该头，属预期而非缺陷）。
hdr_fail=0
for h in ../net/*.h ../payload/*.h; do
    case "$h" in *napi_exports.h) continue ;; esac
    printf '#include "%s"\nint main(){return 0;}\n' "$(basename "$h")" > "$OUT/hdrcheck.cpp"
    if ! g++ -std=c++17 -fsyntax-only -I.. -I../net -I../payload -Istub -I../bearssl/inc \
         "$OUT/hdrcheck.cpp" 2>/dev/null; then
        echo "header not self-sufficient: $h"
        hdr_fail=1
    fi
done
echo "header self-check: failed=$hdr_fail (0=全部自足)"
[ "$hdr_fail" = 0 ]
