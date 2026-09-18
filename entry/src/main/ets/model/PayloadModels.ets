// payload 传输状态模型（AP-2，契约见 libkdeconnect_napi/Index.d.ts v2）
export type PayloadDirection = 'send' | 'receive';

export type PayloadState = 'started' | 'progress' | 'finished' | 'failed' | 'cancelled';

export interface PayloadTransfer {
  transferId: number;
  deviceId: string;
  direction: PayloadDirection;
  state: PayloadState;
  fileName: string;
  size: number; // payloadSize；0=无 payload；-1=流式
  bytesDone: number;
  filePath: string; // receive: spool 落盘路径（finished 后交 keepPayload/discardPayload 处置）
  settled: boolean; // 已保存 / 已丢弃（UI 标记，避免重复操作）
  // 结束时间（ms，2026-09-17 加）：文件详情弹窗要展示"什么时间传过来的"；仅终态写入并持久化
  timeMs?: number;
}
