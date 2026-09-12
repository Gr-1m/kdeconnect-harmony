#ifndef KDECONNECT_NET_LOG_H
#define KDECONNECT_NET_LOG_H

#include "hilog/log.h"

#undef LOG_TAG
#define LOG_TAG "KDEConnect"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0001, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0001, LOG_TAG, __VA_ARGS__)

#endif
