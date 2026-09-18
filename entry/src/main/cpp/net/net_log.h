#ifndef KDECONNECT_NET_LOG_H
#define KDECONNECT_NET_LOG_H

#include "hilog/log.h"

#undef LOG_TAG
#define LOG_TAG "KDEConnect"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0001, LOG_TAG, __VA_ARGS__)

#endif

// —— S4（CodeArts MSG23 §3）：排查级埋点的编译期开关 ——
//   1（默认，宿主测试用）：全部埋点（PHASESPLIT/LOCKHOLD/ENTRY-SPLIT/LOCKWAIT/FRAMESPLIT/DRAINSPLIT…）；
//   0（release）：只留粗粒度哨兵 —— [KDC-NETLOOP] 汇总行（其 maxHold/maxJsLockWait 仍照常累计）。
// 注意：**累计量不受开关影响**（仅打印被去掉），故 NETLOOP 行在 release 下信息量不变。
#ifndef KDC_TELEMETRY
#define KDC_TELEMETRY 1
#endif
