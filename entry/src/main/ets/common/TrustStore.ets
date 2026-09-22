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

  // 新格式：{schemaVersion, devices:[{id,name,certPem,pairedAt}]}
  private static parseStore(raw: string): TrustedDevice[] {
    const out: TrustedDevice[] = [];
    try {
      const data: TrustStoreData = JSON.parse(raw) as TrustStoreData;
      // P3-10②：**读取并校验 schemaVersion**（旧实现只解析 devices，版本号完全没用上）。
      // 语义：①字段缺失 ⇒ 视为 legacy v0，按现状尽力解析；②**高于**当前版本 ⇒ 说明是更新版本写的
      // （可能有本端不认识的字段/语义），只告警、仍尽力解析可用字段，绝不静默丢弃整份信任列表；
      // ③低于或等于当前版本 ⇒ 正常解析（未来若引入逐版本迁移，分支挂在这里）。
      const sv: number = data.schemaVersion ?? 0;
      if (sv > TRUST_SCHEMA_VERSION) {
        console.warn(`KDC trust store schemaVersion=${sv} newer than supported ${TRUST_SCHEMA_VERSION}; parsing best-effort`);
      } else if (sv === 0) {
        console.warn('KDC trust store schemaVersion missing (legacy v0); parsing best-effort');
      }

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
