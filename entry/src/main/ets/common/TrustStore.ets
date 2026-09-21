// SPDX-License-Identifier: GPL-2.0-or-later
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { TrustedDevice, TrustStoreData, TRUST_SCHEMA_VERSION } from '../model/TrustModels';

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
        return TrustStore.parseStore(raw);
      }
      const legacyRaw: string = String(await pref.get(TrustStore.LEGACY_KEY, ''));
      if (legacyRaw.length > 0) {
        const migrated: TrustedDevice[] = TrustStore.migrateLegacy(legacyRaw);
        await TrustStore.save(ctx, migrated);
        return migrated;
      }
    } catch (e) {
      // 读取失败按空处理（首次启动）
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
      // 持久化失败仅丢失本次写入
    }
  }

  // 新格式：{schemaVersion, devices:[{id,name,certPem,pairedAt}]}
  private static parseStore(raw: string): TrustedDevice[] {
    const out: TrustedDevice[] = [];
    try {
      const data: TrustStoreData = JSON.parse(raw) as TrustStoreData;
      const list: TrustedDevice[] = data.devices;
      for (const d of list) {
        if (d.id !== undefined && d.id !== '') {
          out.push({
            id: d.id,
            name: d.name ?? d.id,
            certPem: d.certPem ?? '',
            pairedAt: d.pairedAt ?? 0,
            paired: d.paired ?? true
          });
        }
      }
    } catch (e) {
      // 结构损坏 → 返回空，交由后续迁移/重新配对修复
    }
    return out;
  }

  // 旧格式：[{id,name}] → TrustedDevice[]
  private static migrateLegacy(raw: string): TrustedDevice[] {
    const out: TrustedDevice[] = [];
    try {
      const arr: Array<Record<string, string>> = JSON.parse(raw) as Array<Record<string, string>>;
      for (const it of arr) {
        const id: string = it['id'] ?? '';
        if (id !== '') {
          out.push({ id: id, name: it['name'] ?? id, certPem: '', pairedAt: 0, paired: true });
        }
      }
    } catch (e) {
      // 旧结构损坏 → 忽略
    }
    return out;
  }
}
