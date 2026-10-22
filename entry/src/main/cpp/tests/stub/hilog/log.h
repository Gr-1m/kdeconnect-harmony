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
// 排障时设 KDC_HOST_LOG=1：日志改走 hostLogPrintf 输出到 stderr（默认关闭，不污染测试输出）。
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

typedef enum { LOG_APP = 0 } LogType;
typedef enum { LOG_DEBUG = 0, LOG_INFO = 1, LOG_WARN = 3, LOG_ERROR = 4 } LogLevel;

// host 排障：默认静默；KDC_HOST_LOG=1 时输出到 stderr。
// OHOS 的格式串含隐私修饰 `%{public}s` / `%{public}lld`，printf 不认 ⇒ 先去掉 `{...}` 再 vfprintf。
inline bool hostLogEnabled()
{
    static const bool enabled = std::getenv("KDC_HOST_LOG") != nullptr;
    return enabled;
}

inline void hostLogPrintf(const char *fmt, ...)
{
    if (!hostLogEnabled()) {
        return;
    }
    std::string clean;
    clean.reserve(std::strlen(fmt));
    for (const char *p = fmt; *p != '\0'; ++p) {
        if (p[0] == '%' && p[1] == '{') {
            const char *close = std::strchr(p + 2, '}');
            if (close != nullptr) {
                clean += '%';
                p = close;
                continue;
            }
        }
        clean += *p;
    }
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stderr, clean.c_str(), ap);
    std::fputc('\n', stderr);
    va_end(ap);
}

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
        hostLogPrintf(__VA_ARGS__); \
    } while (0)

#endif
