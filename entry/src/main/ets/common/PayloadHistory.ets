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
  state: string;
  fileName: string;
  size: number;
  bytesDone: number;
  filePath: string;
  settled: boolean;
}

export class PayloadHistory {
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
          direction: 'receive',
          state: PayloadHistory.toState(e.state),
          fileName: e.fileName,
          size: e.size,
          bytesDone: e.bytesDone,
          filePath: e.filePath,
          settled: e.settled
        });
      }
      return out;
    } catch (err) {
      return [];
    }
  }

  static async save(ctx: Context, items: PayloadTransfer[]): Promise<void> {
    try {
      const entries: HistoryEntry[] = [];
      for (const p of items) {
        if (p.direction !== 'receive') {
          continue;
        }
        entries.push({
          transferId: p.transferId,
          deviceId: p.deviceId,
          state: p.state,
          fileName: p.fileName,
          size: p.size,
          bytesDone: p.bytesDone,
          filePath: p.filePath,
          settled: p.settled
        });
        if (entries.length >= MAX_ENTRIES) {
          break;
        }
      }
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(KEY, JSON.stringify(entries));
      await pref.flush();
    } catch (err) {
      // 落库失败不影响主流程（下次状态变化会再试）
    }
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

  private static toState(raw: string): PayloadState {
    if (raw === 'finished' || raw === 'failed' || raw === 'cancelled' || raw === 'started' || raw === 'progress') {
      return raw;
    }
    return 'finished';
  }
}
