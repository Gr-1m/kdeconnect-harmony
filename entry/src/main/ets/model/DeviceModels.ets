// 设备列表数据模型（设备页三组共用）。记住的设备单独建模：AP-3 将扩展证书指纹等字段。

export interface DeviceItem {
  id: string;
  name: string;
  // 已知时为 '10.1.2.3'；当前 net 层 deviceDiscovered 事件 host 恒为 null（待 native 修复），未知用 ''
  host: string;
  tcpPort: number;
  // identity 包的 deviceType（desktop/phone/…），未知为 ''
  deviceType: string;
}

export interface RememberedDevice {
  id: string;
  name: string;
}
