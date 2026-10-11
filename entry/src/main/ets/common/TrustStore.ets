// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { TrustedDevice, TrustStoreData, TRUST_SCHEMA_VERSION } from '../model/TrustModels';
// T10：解析/迁移为**纯函数**（零 Kit）⇒ 抽到 TrustCodec 以便宿主单测（无需设备）。
// 本文件只保留与 Preferences 交互的 I/O 职责（load/save）。
import { parseTrustStore, migrateLegacyTrust } from './TrustCodec';

// 信任设备存储（AP-3）：Preferences 'kdeconnect' 下的 'trustedDevices'（JSON，带 schemaVersion）。
// 兼容迁移：旧键 'rememberedDevices'（[{id,name}]）首次加载时升级并写入新键（旧键保留不删，防数据丢失）。
export class TrustStore {
  private static PREF_NAME: string = 'kdeconnect';
  private static KEY: string = 'trustedDevices';
  private static LEGACY_KEY: string = 'rememberedDevices';

  static async load(ctx: Context): Promise<TrustedDevice[]> {
    try {
      const pref = await preferences.getPreferences(ctx, TrustStore.PREF_NAME);
      const raw: string = String(await pref.get(TrustStore.KEY, ''));
      if (raw.length > 0) {
        return parseTrustStore(raw);
      }
      const legacyRaw: string = String(await pref.get(TrustStore.LEGACY_KEY, ''));
      if (legacyRaw.length > 0) {
        const migrated: TrustedDevice[] = migrateLegacyTrust(legacyRaw);
        await TrustStore.save(ctx, migrated);
        return migrated;
      }
    } catch (e) {
      // P3-10①：**不再静默吞错** —— 语义仍是"读取失败按空处理（首次启动/存储异常）"，
      // 但必须留痕：旧实现 catch 里只有一句注释，真出问题时日志里什么都看不到。
      console.warn('KDC trust store load failed, treated as empty: '
        + (e instanceof Error ? e.message : 'unknown'));
    }
    return [];
  }

  static async save(ctx: Context, devices: TrustedDevice[]): Promise<void> {
    try {
      const pref = await preferences.getPreferences(ctx, TrustStore.PREF_NAME);
      const data: TrustStoreData = { schemaVersion: TRUST_SCHEMA_VERSION, devices: devices };
      await pref.put(TrustStore.KEY, JSON.stringify(data));
      await pref.flush();
    } catch (e) {
      // P3-10①：写入失败仍只是"丢掉本次写入"，但同样不再静默 ——
      // 否则"配对态没存上、重启后又变回未配对"这类问题在日志里无法定位。
      console.warn('KDC trust store save failed (this write lost): '
        + (e instanceof Error ? e.message : 'unknown'));
    }
  }
}
