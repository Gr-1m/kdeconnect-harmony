import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { PayloadTransfer, PayloadState } from '../model/PayloadModels';

// 已接收文件历史（跨重启保留）
// - 只记录「已结束」的接收记录（finished/failed/cancelled），进行中的不入库；
// - 与 TrustStore 同一套 Preferences（库名 kdeconnect）；存 JSON 字符串；
// - 最多保留 MAX_ENTRIES 条，超出丢最旧（列表本身按 transferId 倒序）。
const PREF_NAME: string = 'kdeconnect';
const KEY: string = 'payloadHistory';
const MAX_ENTRIES: number = 100;

interface HistoryEntry {
  transferId: number;
  deviceId: string;
  // 方向（2026-09-17 扩展）：原先只存 receive，导致「发送记录」重启即丢（用户实测：历史里只剩 1 条）
  direction: string;
  state: string;
  fileName: string;
  size: number;
  bytesDone: number;
  filePath: string;
  settled: boolean;
  timeMs?: number;
}

export class PayloadHistory {
  private static saveChain: Promise<void> = Promise.resolve();

  static async load(ctx: Context): Promise<PayloadTransfer[]> {
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      const raw: string = String(await pref.get(KEY, ''));
      if (raw.length === 0) {
        return [];
      }
      const entries: HistoryEntry[] = JSON.parse(raw) as HistoryEntry[];
      const out: PayloadTransfer[] = [];
      for (const e of entries) {
        out.push({
          transferId: e.transferId,
          deviceId: e.deviceId,
          direction: e.direction === 'send' ? 'send' : 'receive',
          state: PayloadHistory.toState(e.state),
          fileName: e.fileName,
          size: e.size,
          bytesDone: e.bytesDone,
          filePath: e.filePath,
          settled: e.settled,
          timeMs: e.timeMs ?? 0
        });
      }
      return out;
    } catch (err) {
      return [];
    }
  }

  static async save(ctx: Context, items: PayloadTransfer[]): Promise<void> {
    const run: () => Promise<void> = async (): Promise<void> => {
      try {
        const pref = await preferences.getPreferences(ctx, PREF_NAME);
        const existing: PayloadTransfer[] = await PayloadHistory.load(ctx);
        const merged: PayloadTransfer[] = [];
        for (const p of items) {
          if (p.direction !== 'receive' && p.direction !== 'send') {
            continue;
          }
          if (merged.some((m: PayloadTransfer) => m.transferId === p.transferId)) {
            continue;
          }
          merged.push(p);
        }
        for (const e of existing) {
          if (merged.some((m: PayloadTransfer) => m.transferId === e.transferId)) {
            continue;
          }
          merged.push(e);
        }
        const entries: HistoryEntry[] = [];
        for (const p of merged) {
          entries.push({
            transferId: p.transferId,
            deviceId: p.deviceId,
            direction: p.direction,
            state: p.state,
            fileName: PayloadHistory.safeFileName(p.fileName, p.transferId),
            size: p.size,
            bytesDone: p.bytesDone,
            filePath: p.filePath,
            settled: p.settled,
            timeMs: p.timeMs ?? 0
          });
          if (entries.length >= MAX_ENTRIES) {
            break;
          }
        }
        await pref.put(KEY, JSON.stringify(entries));
        await pref.flush();
      } catch (err) {
      }
    };
    PayloadHistory.saveChain = PayloadHistory.saveChain.then(run, run);
    return PayloadHistory.saveChain;
  }

  // 文件名白名单（与 Index.ets 的 sanitizeFileName 同规则；此处独立一份避免跨层依赖）
  private static safeFileName(raw: string, transferId: number): string {
    let name: string = raw;
    name = name.replace(new RegExp('/', 'g'), '_');
    name = name.replace(new RegExp('\\\\', 'g'), '_');
    while (name.startsWith('.')) {
      name = name.substring(1);
    }
    if (name.length === 0) {
      name = `transfer_${transferId}`;
    }
    if (name.length > 128) {
      name = name.substring(0, 128);
    }
    return name;
  }

  static async clear(ctx: Context): Promise<void> {
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(KEY, '[]');
      await pref.flush();
    } catch (err) {
      // 同上
    }
  }

  // 兜底（AtomCode P3-1）：'started'/'progress' 按约定不入库，出现即说明写侧契约破了；
  // 兜底用 'failed'（安全降级）——绝不能兜成 'finished'，否则未完成的文件会显示"已完成"。
  private static toState(raw: string): PayloadState {
    if (raw === 'finished' || raw === 'failed' || raw === 'cancelled') {
      return raw;
    }
    return 'failed';
  }
}
