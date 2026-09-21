// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef KDECONNECT_HILOG_STUB_H
#define KDECONNECT_HILOG_STUB_H

// host 单测专用：替代 NDK hilog 头（tests/run.sh 用 -I 指向本目录）。
//
// 行为：不输出日志，但**必须"使用"参数**：
//   - 否则「只在日志里用到的变量」在 -Wall -Wextra 下会误报 unused-variable
//     （曾迫使调用点写 `(void) err;` 之类噪音）；
//   - 走 `printf` 的格式检查还顺带在 host 编译期校验日志格式串（%s/%d 不匹配）
//   —— 这在设备侧 hilog 上是不检查的。
// `if (0)` 保证运行期零开销（死代码消除），仅在语义上引用参数。
#include <cstdio>

typedef enum { LOG_APP = 0 } LogType;
typedef enum { LOG_DEBUG = 0, LOG_INFO = 1, LOG_WARN = 3, LOG_ERROR = 4 } LogLevel;

// 真实 hilog 签名：OH_LOG_Print(type, level, domain, tag, fmt, ...) —— 前 4 个固定参数，
// 之后是格式串 + 变参（net_log.h 的 LOGx 宏就是这么展开的）。
#define OH_LOG_Print(type, level, domain, tag, ...) \
    do { \
        (void) (type); \
        (void) (level); \
        (void) (domain); \
        (void) (tag); \
        if (0) { \
            ::printf(__VA_ARGS__); \
        } \
    } while (0)

#endif
