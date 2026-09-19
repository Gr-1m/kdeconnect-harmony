import { MprisSnapshot } from '../model/MprisModels';
import { SystemSinkUi } from '../model/SystemVolumeModels';

// 批1 根治（CodeArts MSG16 授权 / ARKTS_PERF_ROADMAP §2）：插件 → UI 的**类型化事件**。
//
// 背景：原通道是 `notify(kind: string, data: string)` —— 插件把对象 `JSON.stringify`，
// UI 侧再 `JSON.parse`，每个事件多两次 JSON 往返（MPRIS 稳态 ~1/s）。本文件把通道改为
// 传对象：MPRIS 这类带结构化数据的事件不再序列化；纯标量事件（'ringing' / 计数等）
// 由 PluginBase.notify 内部包成 { kind, text } —— **调用点零改动**。
//
// 契约：协议与线上格式**完全不变**，只改进程内通道。
// 约定（2026-09-19 补，避免再出现"字符串打包通道"）：**结构化数据一律加类型化字段**，
// 不要再往 text 里塞 "a|b|c" 这种自造格式 —— 系统音量曾这样做过，已改回 svSinks。
export interface PluginEvent {
  kind: string;
  mprisList?: string[];
  mprisSnap?: MprisSnapshot;
  svSinks?: SystemSinkUi[];
  battery?: BatteryPayload;
  runOutput?: RunOutputPayload;
  text?: string;
}

export interface BatteryPayload {
  charge: number;
  charging: boolean;
}

export interface RunOutputPayload {
  success: boolean;
  exitCode: number;
  text: string;
}

// 便捷构造：标量事件（旧 notify(kind, data) 的等价物）
export function textEvent(kind: string, data: string): PluginEvent {
  const ev: PluginEvent = { kind: kind, text: data };
  return ev;
}
