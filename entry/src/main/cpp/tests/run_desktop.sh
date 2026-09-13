#!/usr/bin/env bash
# 手动运行的 host 集成工具（**不进 CI**）：需要同网段有一台在跑的 KDE Connect 桌面端。
# 默认对端 <host>:1716（本项目的开发桌面）。用法见 desktop_pair.cpp 头注释。
set -euo pipefail
cd "$(dirname "$0")"

OUT=/tmp/kdc_native_tests
mkdir -p "$OUT"
make -s -C ../bearssl -j"$(nproc)" BUILD="$OUT/bearssl" lib

gcc -O1 -I../bearssl/inc -I../bearssl/src -I../json -c ../json/cJSON.c -o "$OUT/cJSON.o"

g++ -std=c++17 -Wall -Wextra -O1 -pipe \
    -I. -I.. -Istub -I../bearssl/inc \
    desktop_pair.cpp \
    ../net/net_stack.cpp \
    ../net/tls_engine.cpp \
    ../net/tcp_connection.cpp \
    ../net/tcp_server.cpp \
    ../net/udp_discovery.cpp \
    ../net/cert_gen.cpp \
    ../net/cert_util.cpp \
    ../net/net_util.cpp \
    ../net/packet_io.cpp \
    ../payload/payload.cpp \
    "$OUT/cJSON.o" "$OUT/bearssl/libbearssl.a" \
    -lpthread \
    -o "$OUT/kdc_desktop"

exec "$OUT/kdc_desktop" "$@"
