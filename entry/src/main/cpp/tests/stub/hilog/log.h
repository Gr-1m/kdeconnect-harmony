#ifndef KDECONNECT_HILOG_STUB_H
#define KDECONNECT_HILOG_STUB_H

// host 单测专用：替代 NDK hilog 头（tests/run.sh 用 -I 指向本目录）。
// 单测不需要日志输出，no-op 即可（避免展开可变参格式串的编译差异）。

typedef enum { LOG_APP = 0 } LogType;
typedef enum { LOG_DEBUG = 0, LOG_INFO = 1, LOG_WARN = 3, LOG_ERROR = 4 } LogLevel;

#define OH_LOG_Print(...) ((void)0)

#endif
