// 信任设备存储模型（AP-3）。Preferences 中的持久化结构带 schemaVersion，
// 供 AP-7（bundleName 改名）等未来迁移使用。
// 说明：证书指纹/钉扎的判定在 native（WP-2），此处只存对端证书 PEM 与展示信息。

export const TRUST_SCHEMA_VERSION: number = 2;

export interface TrustedDevice {
  id: string;
  name: string;
  // 对端证书 PEM（配对时从 native.getPeerCertificate 取；未取到为空串）
  certPem: string;
  // 配对成功时间（epoch ms）
  pairedAt: number;
}

export interface TrustStoreData {
  schemaVersion: number;
  devices: TrustedDevice[];
}
