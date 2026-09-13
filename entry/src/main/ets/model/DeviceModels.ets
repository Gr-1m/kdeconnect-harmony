// 设备列表数据模型（设备页三组共用）。记住的设备单独建模：AP-3 将扩展证书指纹等字段。

export interface DeviceItem {
  id: string;
  name: string;
  // 已知时为 '10.1.2.3'；当前 net 层 deviceDiscovered 事件 host 恒为 null（待 native 修复），未知用 ''
  host: string;
  tcpPort: number;
  // identity 包的 deviceType（desktop/phone/…），未知为 ''
  deviceType: string;
  // 发现列表的在线态（CodeArts MSG78 §2，对齐 Android/KDE）：deviceLost 只把条目置为 false（灰显），
  // 不再从列表删除，避免「对端停止广播 60s 后列表被清空」。
  online: boolean;
}

export interface RememberedDevice {
  id: string;
  name: string;
}

// 插件推给 UI 的展示项（如电量）；由 Index 维护、DevicesTab 渲染
export interface BatteryItem {
  deviceId: string;
  text: string;
}
