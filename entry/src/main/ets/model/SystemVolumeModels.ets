// 系统音量（kdeconnect.systemvolume）的 **UI 视图模型**（2026-09-18 用户要求「设备 tab 读 OutputDevice」）。
//
// 分工（2026-09-19 重构后固定，勿再把协议细节泄漏到 UI）：
//   - 协议 DTO（绝对刻度 volume/maxVolume、name/requestSinks 等）只存在于 SystemVolumePlugin.ets；
//   - 本文件是**唯一的 UI 视图模型**，刻度已换算成百分比；
//   - 插件出「行对象数组」，UI 只渲染：不做换算、不做兜底猜测、不持有第二份真相。
//
// ★ 为什么是 @Observed class 而不是 interface（2026-09-19 实测踩坑，勿回退）：
//   这些行在 UI 侧由 `ForEach` 渲染，键是 `name`。**ForEach 键不变时不会重新执行子组件构建**，
//   所以给行组件传「标量 @Prop」会导致：对端/本地的后续变化**永远不刷新**（表现为"点静音对端有效果、
//   按钮文案不变"）。ArkUI 官方对「列表项内容会变」给出的就是 @Observed + @ObjectLink：
//   行对象**实例保持稳定**、字段原地更新，订阅它的那一行自己重建，其余行与页面不受影响。
@Observed
export class SystemSinkUi {
  name: string = '';         // sink 标识（发请求按它指定，UI 不可改）
  description: string = '';  // 面向用户的名字（对端下发，可能为空 ⇒ UI 回退显示 name）
  // 0-100；**-1 = 未知**：该 sink 的 maxVolume 刻度还没拿到。此时滑杆禁用并显示「—」，
  // 不做「>100 就夹到 100」之类的猜测——那类兜底正是「音量被当成 0 ⇒ 听感静音」的同类问题。
  volumePct: number = -1;
  muted: boolean = false;
  isDefault: boolean = false;  // 协议 enabled：对端默认输出（UI 只作标记）

  // 从协议侧状态更新本行（**唯一**的写入点，由插件在 push 时调用）。
  // 逐字段赋值而不是整体替换对象：保持实例稳定，@ObjectLink 才能把变化推给对应的那一行。
  update(name: string, description: string, volumePct: number, muted: boolean, isDefault: boolean): void {
    this.name = name;
    this.description = description;
    this.volumePct = volumePct;
    this.muted = muted;
    this.isDefault = isDefault;
  }
}
