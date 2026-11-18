// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 事件**形状镜像**（B-1 配套）：`libkdeconnect_napi/Index.d.ts` 的 `NetEventBase`/`NetEvent` 的纯 ArkTS 副本。
//
// 为什么需要：B-1 的解码（`common/EventKind.ets`）必须能在**宿主通道**（bun，不加载 .so）里回归，
// 而真身类型定义在 native 的 `.d.ts` 中（import 即拉 cdylib 符号）⇒ 这里放一份**字段同名同型**的镜像。
// 漂移由 `tools/check-event-kinds.py` 守卫：`Index.d.ts` 的 `NetEventBase` 字段必须在本文件里全部出现。

export type NetEventType =
  | 'deviceDiscovered'
  | 'deviceLost'
  | 'connected'
  | 'disconnected'
  | 'packetReceived'
  | 'pairingRequest'
  | 'payloadTransfer'
  | 'error';

export type PayloadDirection = 'send' | 'receive';
export type PayloadState = 'started' | 'progress' | 'finished' | 'failed' | 'cancelled';

export interface NetEventBase {
  type: NetEventType;
  deviceId?: string;
  deviceName?: string;
  deviceType?: string;
  host?: string;
  tcpPort?: number;
  role?: 'server' | 'client';
  packet?: string;
  payloadTransferId?: number;
  errorCode?: number;
  errorMessage?: string;
  payloadDirection?: PayloadDirection;
  payloadState?: PayloadState;
  payloadSize?: number;
  payloadBytesDone?: number;
  payloadFileName?: string;
  payloadFilePath?: string;
}

export type NetEvent = NetEventBase;
