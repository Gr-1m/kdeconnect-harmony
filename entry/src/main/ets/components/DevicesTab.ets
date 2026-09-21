// SPDX-License-Identifier: GPL-2.0-or-later
import uiMaterial from '@ohos.arkui.uiMaterial';
import { DeviceItem, RememberedDevice, BatteryItem } from '../model/DeviceModels';
import { GlassCard } from './GlassCard';

// 设备详情页大按钮卡片的**统一高度**（vp）：6 张卡等高才对齐；
// 剪贴板卡内含安全控件，故控件贴底 + 副标题限 1 行来适配这个高度。
const ACTION_CARD_HEIGHT: number = 132;

// 平板侧栏宽度（横屏占 30%，夹在 180–340vp 之间；竖屏固定 104vp 紧凑）
const WIDE_RAIL_LIMIT: ConstraintSizeOptions = { minWidth: 180, maxWidth: 340 };

// 设备 Tab：
// - 竖屏（手机 / 平板竖屏）：标题旁汉堡 → 抽屉式侧栏（Index.drawerOverlay），主区单列；
// - 横屏（平板，宽 > 高）：左侧栏**常驻**占 30%（已连接 / 发现 都是可点设备列表），
//   右侧主区显示选中设备的功能页（设备信息 + 大按钮）或所选分区内容。
@Component
export struct DevicesTab {
  // 三态互斥列表由页面层派生后单向下发（已连接 / 发现 / 记住=离线已知），本组件只读
  @Prop connectedDevices: DeviceItem[] = [];
  @Prop discoveredDevices: DeviceItem[] = [];
  @Prop rememberedDevices: RememberedDevice[] = [];
  // 配对态要用**全量**已知设备表（含在线的），不能用上面那份离线子集
  @Prop rememberedAll: RememberedDevice[] = [];
  @Prop immersive: boolean = false;
  // 并排侧栏模式（仅横屏平板）：侧栏常驻 30%
  @Prop sideBySide: boolean = false;
  // AP-1：本侧已发起、等待对端确认的设备 id
  @Prop requestedPairIds: string[] = [];
  // 插件推来的展示项（电量）
  @Prop batteryItems: BatteryItem[] = [];
  cardMaterial: uiMaterial.Material | undefined = undefined;
  onUnpairDevice: (d: DeviceItem) => void = () => {
  };
  // 手机窄屏：汉堡按钮已上移到页面标题旁（Index.menuButton），组件内不再渲染；
  // wide（平板）仍用组件内常驻侧栏，靠 railExpanded 伸缩。
  // 抽屉里选中的设备（Index 持有）：非空时「已连接设备」分区改渲染设备详情 + 大按钮
  @Prop selectedDeviceId: string = '';
  // 大按钮占位回调（功能暂未实现）
  onPlaceholderAction: (key: string) => void = () => {
  };
  // 发送文件卡的**卡内按钮**：直接拉起文件选择器并发送（= 文件页「选择文件并发送」同一动作）
  onSendFilePick: () => void = () => {
  };
  // 点设备行（发现页/已连接列表）→ 回到该设备的「功能页」（设备信息 + 大按钮）
  onOpenDevice: (d: DeviceItem) => void = () => {
  };
  // 剪贴板安全控件授权结果（true=已获临时读权限，可立刻读取并发送）
  onClipboardPaste: (granted: boolean) => void = () => {
  };
  // 剪贴板卡片整体点击 → 索取对端剪贴板（kdeconnect.clipboard.connect，MSG112 §1 双向）
  onClipboardRequest: () => void = () => {
  };
  onManualConnect: (host: string, port: number) => void = () => {
  };
  onPairDevice: (d: DeviceItem) => void = () => {
  };
  // 发现列表下拉刷新 → 请求页面触发一次 identity 广播（MSG73/MSG74）
  onRefreshDiscovery: () => void = () => {
  };
  // 侧栏选中项：0 已连接 / 1 发现 / 2 记住的 / 3 手动连接
  // @Link：连接/配对成功后由 Index 切回「已连接设备」分区
  @Link deviceSection: number;
  // 手动连接默认值：host 留空（10.0.2.2 只是 QEMU 模拟器的 NAT 网关，真机无意义），port 用默认端口
  @State manualHost: string = '';
  @State manualPort: string = '1716';
  // 发现列表下拉刷新态（触发广播后自动收起）
  @State discoveryRefreshing: boolean = false;
  // 主区实测宽度（vp）：决定大按钮列数（窄→2 列 / 宽→3 列）
  @State paneWidthVp: number = 0;

  private pickSection(index: number): void {
    this.deviceSection = index;
  }

  // 大按钮列数：以**主区实测宽度**为准（横屏侧栏占 30% 后主区变宽 → 3 列）
  private cardColumns(): number {
    if (this.paneWidthVp > 0) {
      return this.paneWidthVp >= 460 ? 3 : 2;
    }
    return this.sideBySide ? 3 : 2;
  }

  // §8-D：onAreaChange 计数 + 去抖（先量后改）。
  // 开屏首帧 / 旋转 / 拖动改尺寸时该回调会连续触发，每次写 @State paneWidthVp 都会让
  // cardColumns() 重算并重排卡片。原实现已有「变化 >1vp 才写」的同值保护，这里再叠加
  // 150ms 去抖：拖动过程中不写，停稳后写一次；计数用于确认实际触发量级。
  private areaChangeCount: number = 0;
  private paneAreaTimer: number = -1;

  // P3-9：组件销毁时清理去抖 timer。旧实现只在**下一次** onPaneArea 触发时 clearTimeout
  // ⇒ 组件被销毁后那个挂着的 timer 仍会跑一拍，回调里访问已不存在的状态。
  aboutToDisappear(): void {
    if (this.paneAreaTimer >= 0) {
      clearTimeout(this.paneAreaTimer);
      this.paneAreaTimer = -1;
    }
  }

  private onPaneArea(a: Area): void {
    const w: number = Number(a.width);
    if (!Number.isFinite(w) || w <= 0) {
      return;
    }
    this.areaChangeCount++;
    if (this.areaChangeCount <= 3 || this.areaChangeCount % 20 === 0) {
      console.info(`KDC onAreaChange #${this.areaChangeCount} w=${Math.round(w)}vp`);
    }
    if (this.paneAreaTimer >= 0) {
      clearTimeout(this.paneAreaTimer);
    }
    this.paneAreaTimer = setTimeout((): void => {
      this.paneAreaTimer = -1;
      if (Math.abs(w - this.paneWidthVp) > 1) {
        this.paneWidthVp = w;
      }
    }, 150);
  }

  // 是否处于配对态：**必须看 paired 标记**（需求 3 后条目会永久保留，
  // 只判断"存在条目"会把已解除配对的设备误判为已配对——用户实测反馈的 bug）
  private isPaired(deviceId: string): boolean {
    return this.rememberedAll.some((r: RememberedDevice) => r.id === deviceId && r.paired);
  }

  private batteryOf(deviceId: string): string {
    const item: BatteryItem | undefined = this.batteryItems.find((b: BatteryItem) => b.deviceId === deviceId);
    return item === undefined ? '' : item.text;
  }

  // 地址显示（MSG106_OMP_TO_DEVECO §1 / MSG108_CODEARTS_TO_DEVECO §3 收尾）：
  // host 未知 → 「地址待定」；**端口未知（0）时只显示 host**（KDE 只在 UDP 广播里带 tcpPort，
  // 拨入 identity 不带 ⇒ 之前会渲染成 `<host>:0`）。
  private addressText(d: DeviceItem): ResourceStr {
    if (d.host === '') {
      return $r('app.string.address_pending');
    }
    return d.tcpPort > 0 ? `${d.host}:${d.tcpPort}` : d.host;
  }

  private sectionTitleOf(index: number): ResourceStr {
    // 横屏：右侧是「详情」面板（列表都在左侧栏），故 0/1 分区标题统一为「设备详情」
    if (this.sideBySide && (index === 0 || index === 1)) {
      return $r('app.string.device_detail_title');
    }
    if (index === 0) {
      return $r('app.string.connected_devices');
    }
    if (index === 1) {
      return $r('app.string.discovered_devices');
    }
    if (index === 2) {
      return $r('app.string.remembered_devices');
    }
    return $r('app.string.manual_connect_optional');
  }

  // ---- 横屏常驻侧栏（占 30%）：已连接 / 发现 都是可点设备列表，点设备 → 右侧功能页 ----

  @Builder
  sideGroupLabel(title: ResourceStr, count: number) {
    Row({ space: 6 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (count > 0) {
        Text(`${count}`)
          .fontSize(11)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 2 })
  }

  @Builder
  sideDeviceRow(d: DeviceItem, connected: boolean) {
    Row({ space: 8 }) {
      Circle({ width: 8, height: 8 })
        .fill(connected ? $r('app.color.dot_connected') : $r('app.color.dot_discovered'))
      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 已连接行显示 deviceId（身份稳定）；发现行显示 IP:端口（ID 移到配对弹窗核对）
        Text(connected ? d.id : this.addressText(d))
          .fontSize(9)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (connected) {
        Text($r('app.string.remembered_hint'))
          .fontSize(9)
          .fontColor($r('app.color.dot_remembered'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.chip_bg'))
      } else if (this.requestedPairIds.includes(d.id)) {
        Text($r('app.string.pair_pending'))
          .fontSize(9)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      } else {
        // 未配对：配对入口就在发现列表（用户 2026-09-14 裁决）
        Button($r('app.string.pair_action'))
          .fontSize(11)
          .height(28)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(8)
          .onClick(() => {
            this.onPairDevice(d);
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor(this.selectedDeviceId === d.id ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      // 已连接 → 打开功能页；未配对 → 走配对（与行内「配对」按钮一致）
      if (connected) {
        this.onOpenDevice(d);
      } else {
        this.onPairDevice(d);
      }
    })
  }

  // 分区入口（记住的设备 / 手动连接）：点 → 右侧主区切到该分区
  @Builder
  sideEntryRow(index: number, label: ResourceStr, count: number) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(14)
        .fontColor(this.deviceSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .fontWeight(this.deviceSection === index ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (count > 0) {
        Text(`${count}`)
          .fontSize(11)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor(this.deviceSection === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.pickSection(index);
    })
  }

  @Builder
  sidePanel() {
    // 侧栏整体支持下拉刷新 → 触发一次 identity 广播（发现列表移入侧栏后，刷新手势也随之搬家）
    Refresh({ refreshing: $$this.discoveryRefreshing }) {
      Scroll() {
        Column({ space: 2 }) {
          this.sideGroupLabel($r('app.string.connected_devices'), this.connectedDevices.length)
          if (this.connectedDevices.length === 0) {
            Text($r('app.string.group_empty'))
              .fontSize(11)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
              .padding({ left: 12, right: 12, top: 2, bottom: 6 })
          }
          ForEach(this.connectedDevices, (d: DeviceItem) => {
            this.sideDeviceRow(d, true)
          }, (d: DeviceItem) => `conn-${d.id}`)

          this.sideGroupLabel($r('app.string.discovered_devices'), this.discoveredDevices.length)
          if (this.discoveredDevices.length === 0) {
            Text($r('app.string.discovered_hint'))
              .fontSize(11)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
              .padding({ left: 12, right: 12, top: 2, bottom: 6 })
          }
          ForEach(this.discoveredDevices, (d: DeviceItem) => {
            this.sideDeviceRow(d, false)
          }, (d: DeviceItem) => `disc-${d.id}`)

          Divider()
            .color($r('app.color.card_border'))
            .margin({ top: 8, bottom: 4 })

          this.sideEntryRow(2, $r('app.string.remembered_devices'), this.rememberedDevices.length)
          this.sideEntryRow(3, $r('app.string.manual_connect'), 0)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => {
      this.onRefreshDiscovery();
      setTimeout((): void => {
        this.discoveryRefreshing = false;
      }, 1500);
    })
  }

  @Builder
  connectedRow(d: DeviceItem) {
    Row({ space: 8 }) {
      Circle({ width: 8, height: 8 })
        .fill($r('app.color.dot_connected'))
      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(d.id)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
        if (this.batteryOf(d.id).length > 0) {
          Text(this.batteryOf(d.id))
            .fontSize(10)
            .fontColor($r('app.color.dot_connected'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 已连接设备只保留**配对 / 解除配对**（用户 2026-09-13 裁决：对齐 iOS；
      // 不再提供「断开」——链路由 KDE 自行管理，对端重拨/重连都与 UI 无关）
      if (this.isPaired(d.id)) {
        Text($r('app.string.remembered_hint'))
          .fontSize(10)
          .fontColor($r('app.color.dot_remembered'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.chip_bg'))
        Button($r('app.string.unpair_action'))
          .fontSize(12)
          .height(32)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(8)
          .onClick(() => {
            this.onUnpairDevice(d);
          })
      } else if (this.requestedPairIds.includes(d.id)) {
        Text($r('app.string.pair_pending'))
          .fontSize(10)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      } else {
        // 已连接但未配对：只显示状态徽标（**配对入口在「发现设备」页**，用户 2026-09-13 裁决）
        Text($r('app.string.remembered_unpaired'))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.chip_bg'))
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    // 点整行 = 打开该设备的「功能页」（设备信息 + 大按钮）
    .onClick(() => {
      this.onOpenDevice(d);
    })
  }

  @Builder
  discoveredRow(d: DeviceItem) {
    Row({ space: 10 }) {
      Circle({ width: 8, height: 8 })
        .fill(d.online ? $r('app.color.dot_discovered') : $r('app.color.text_muted'))
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(d.name)
            .fontSize(13)
            .fontColor(d.online ? $r('app.color.text_primary') : $r('app.color.text_muted'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 离线标记（超时不删条目，只标离线）
          if (!d.online) {
            Text($r('app.string.device_offline'))
              .fontSize(9)
              .fontColor($r('app.color.text_muted'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(999)
              .backgroundColor($r('app.color.chip_bg'))
          }
        }
        // 列表只展示 IP:端口（设备 ID 挪到配对弹窗里核对，用户 2026-09-14）
        Text(this.addressText(d))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 用户 2026-09-13 裁决：配对统一在「发现设备」页（KDE 发现后会自动连接 ⇒ 不再提供「连接」按钮）。
      // 行内信息：设备名称 + uuid + ip:port；按钮：配对 / 已配对（解除配对）/ 等待确认。
      if (this.isPaired(d.id)) {
        Text($r('app.string.remembered_hint'))
          .fontSize(10)
          .fontColor($r('app.color.dot_remembered'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.chip_bg'))
        Button($r('app.string.unpair_action'))
          .fontSize(12)
          .height(32)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(8)
          .onClick(() => {
            this.onUnpairDevice(d);
          })
      } else if (this.requestedPairIds.includes(d.id)) {
        Text($r('app.string.pair_pending'))
          .fontSize(10)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      } else {
        Button($r('app.string.pair_action'))
          .fontSize(12)
          .height(32)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(8)
          .onClick(() => {
            this.onPairDevice(d);
          })
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    // 点整行 = 打开该设备的「功能页」（已连接时）；未连接由页面层提示离线。
    // 配对仍只由行内「配对」按钮触发，避免误触发配对。
    .onClick(() => {
      this.onOpenDevice(d);
    })
  }

  @Builder
  rememberedRow(r: RememberedDevice) {
    Row({ space: 10 }) {
      // 记住的设备 = 曾经连接过、当前离线 → 状态灯用离线灰（用户 2026-09-14 规则）
      Circle({ width: 8, height: 8 })
        .fill($r('app.color.text_muted'))
      Column({ space: 2 }) {
        Text(r.name)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(r.id)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text($r('app.string.device_offline'))
        .fontSize(9)
        .fontColor($r('app.color.text_muted'))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor($r('app.color.chip_bg'))
      // 需求 3（用户 miaoshu.txt）：条目永久保留；仅区分是否仍处于配对态
      Text(r.paired ? $r('app.string.remembered_hint') : $r('app.string.remembered_unpaired'))
        .fontSize(10)
        .fontColor(r.paired ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor($r('app.color.chip_bg'))
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  emptyHint(text: ResourceStr) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.text_muted'))
      .padding({ top: 4, bottom: 4 })
  }

  // 大按钮（对齐参考稿主页面的「检测与帮助 / 我要换电池」卡片：图标 + 标题 + 副标题）。
  // 功能暂未实现：点击只回调占位 key（Index 侧给 toast）。
  @Builder
  actionCard(key: string, icon: Resource, title: ResourceStr, desc: ResourceStr) {
    Column({ space: 6 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([$r('app.color.accent_text')])
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
      Text(desc)
        .fontSize(11)
        .fontColor($r('app.color.text_muted'))
        .maxLines(2)
    }
    .layoutWeight(1)
    .height(ACTION_CARD_HEIGHT)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .backgroundBlurStyle(undefined)
    .border({ width: 1, color: $r('app.color.card_border') })
    .onClick(() => {
      this.onPlaceholderAction(key);
    })
  }

  // 发送文件卡（用户 2026-09-16 要求）：整卡点击仍 = 跳到文件页；卡内按钮 = 直接选文件并发送，
  // 与文件页「选择文件并发送」同一个动作。版式对齐剪贴板卡（等高 + 控件贴底）。
  @Builder
  sendFileCard(icon: Resource, title: ResourceStr, desc: ResourceStr) {
    Column() {
      Column({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([$r('app.color.accent_text')])
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(desc)
          .fontSize(11)
          .fontColor($r('app.color.text_muted'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)

      // 与剪贴板卡的 PasteButton 观感一致：用**系统按钮的普通样式**（ButtonStyleMode.NORMAL =
      // 浅底深字的中性按钮；默认的 EMPHASIZED 是品牌蓝强调按钮，这正是之前观感不同的原因）。
      // 不覆盖任何颜色，交给系统主题（黑夜/白天模式都自动正确）。
      Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.paperplane'))
            .fontSize(14)
            .fontColor([$r('sys.color.brand')])
          Text($r('app.string.action_send_pick'))
            .fontSize(12)
        }
      }
      .height(26)
      .padding({ left: 12, right: 12 })
      .onClick(() => {
        this.onSendFilePick();
      })
    }
    .layoutWeight(1)
    .height(ACTION_CARD_HEIGHT)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .backgroundBlurStyle(undefined)
    .border({ width: 1, color: $r('app.color.card_border') })
    .onClick(() => {
      this.onPlaceholderAction('send_file');
    })
  }

  // 设备详情（对齐参考稿主页面）：上方设备信息 + 下方大按钮
  // 剪贴板卡：读本机剪贴板需 `ohos.permission.READ_PASTEBOARD`，而它在 SDK 权限定义里是
  // `availableLevel: system_basic`（三方应用申请会导致安装失败）→ 必须改用官方**安全控件**
  // `PasteButton`：用户点击即获**临时读权限**（SUCCESS）。故这张卡内嵌一个小号粘贴控件作为动作入口。
  // 版式：与其它大按钮**等高**（ACTION_CARD_HEIGHT），副标题限 1 行、控件贴底（SpaceBetween），
  // 否则会把这卡撑高 → 与左列「发送文件」不对齐（用户实测反馈）。
  @Builder
  clipboardCard(icon: Resource, title: ResourceStr, desc: ResourceStr) {
    Column() {
      // 说明见下方注释：整卡点击 = 索取对端剪贴板；控件点击 = 授权后发送本机剪贴板
      Column({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(24)
          .fontColor([$r('app.color.accent_text')])
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(desc)
          .fontSize(11)
          .fontColor($r('app.color.text_muted'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)

      // 安全控件：不可被遮挡、不设透明度；点击回调带授权结果
      PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE })
        .fontSize(12)
        .height(26)
        .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
          this.onClipboardPaste(result === PasteButtonOnClickResult.SUCCESS);
        })
    }
    .layoutWeight(1)
    .height(ACTION_CARD_HEIGHT)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .backgroundBlurStyle(undefined)
    .border({ width: 1, color: $r('app.color.card_border') })
    .onClick(() => {
      this.onClipboardRequest();
    })
  }

  @Builder
  deviceDetail(d: DeviceItem) {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column() {
          SymbolGlyph($r('sys.symbol.computer'))
            .fontSize(26)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(56)
        .height(56)
        .borderRadius(16)
        .backgroundColor($r('app.color.chip_bg'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 4 }) {
          Text(d.name)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(d.id)
            .fontSize(10)
            .fontColor($r('app.color.text_muted'))
            .fontFamily('monospace')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 8 }) {
            Text(this.isPaired(d.id) ? $r('app.string.remembered_hint') : $r('app.string.remembered_unpaired'))
              .fontSize(10)
              .fontColor(this.isPaired(d.id) ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(999)
              .backgroundColor($r('app.color.chip_bg'))
            if (this.batteryOf(d.id).length > 0) {
              Text(this.batteryOf(d.id))
                .fontSize(10)
                .fontColor($r('app.color.dot_connected'))
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(999)
                .backgroundColor($r('app.color.chip_bg'))
            }
            // 解除配对入口：横屏右侧只显示详情（列表里的行内按钮不可见），故详情页也保留一个
            if (this.isPaired(d.id)) {
              Button($r('app.string.unpair_action'))
                .fontSize(11)
                .height(28)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(8)
                .onClick(() => {
                  this.onUnpairDevice(d);
                })
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 大按钮：暂为占位（功能未实现）
      // 自适应列数：按主区实测宽度 2 列 / 3 列；所有卡片统一 ACTION_CARD_HEIGHT 保证对齐
      // 6 个按钮按 MSG112 §1 定版：发送文件 / 剪贴板（双向）/ 查找设备 / 远程输入 / 远程命令 / 媒体控制
      if (this.cardColumns() >= 3) {
        Row({ space: 10 }) {
      this.sendFileCard($r('sys.symbol.paperplane'),
        $r('app.string.action_send_file'), $r('app.string.action_send_file_desc'))
          this.clipboardCard($r('sys.symbol.text_clipboard'),
            $r('app.string.action_clipboard'), $r('app.string.action_clipboard_desc'))
          this.actionCard('find_device', $r('sys.symbol.location_up'),
            $r('app.string.action_find_device'), $r('app.string.action_find_device_desc'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: 10 }) {
          this.actionCard('remote_input', $r('sys.symbol.touchpad'),
            $r('app.string.action_remote_input'), $r('app.string.action_remote_input_desc'))
          this.actionCard('run_command', $r('sys.symbol.play_circle'),
            $r('app.string.action_run_command'), $r('app.string.action_run_command_desc'))
          this.actionCard('media', $r('sys.symbol.screen_share'),
            $r('app.string.action_media'), $r('app.string.action_media_desc'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        Row({ space: 10 }) {
      this.sendFileCard($r('sys.symbol.paperplane'),
        $r('app.string.action_send_file'), $r('app.string.action_send_file_desc'))
          this.clipboardCard($r('sys.symbol.text_clipboard'),
            $r('app.string.action_clipboard'), $r('app.string.action_clipboard_desc'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: 10 }) {
          this.actionCard('find_device', $r('sys.symbol.location_up'),
            $r('app.string.action_find_device'), $r('app.string.action_find_device_desc'))
          this.actionCard('remote_input', $r('sys.symbol.touchpad'),
            $r('app.string.action_remote_input'), $r('app.string.action_remote_input_desc'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: 10 }) {
          this.actionCard('run_command', $r('sys.symbol.play_circle'),
            $r('app.string.action_run_command'), $r('app.string.action_run_command_desc'))
          this.actionCard('media', $r('sys.symbol.screen_share'),
            $r('app.string.action_media'), $r('app.string.action_media_desc'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private selectedDeviceVisible(): boolean {
    if (this.selectedDeviceId.length === 0) {
      return false;
    }
    if (this.connectedDevices.some((d: DeviceItem) => d.id === this.selectedDeviceId)) {
      return true;
    }
    // 功能卡片规则（【根治】，CodeArts MSG6 §3 / MSG13 §3-2 裁决）：
    // 设备**短暂离线**（抖动/重连/暂时断网）时仍保留其详情页，只有「被解除配对」
    // 才收起（paired=false）。这样卡片不会再"闪一下就没"。
    return this.isPaired(this.selectedDeviceId);
  }

  // 详情页要渲染的设备：在线取实时条目；离线但已配对 ⇒ 用已知设备表兜底（online=false）
  private selectedDeviceList(): DeviceItem[] {
    const live: DeviceItem[] = this.connectedDevices.filter((d: DeviceItem) => d.id === this.selectedDeviceId);
    if (live.length > 0) {
      return live;
    }
    const rem: RememberedDevice | undefined =
      this.rememberedAll.find((r: RememberedDevice) => r.id === this.selectedDeviceId);
    const name: string = rem === undefined ? this.selectedDeviceId : rem.name;
    const item: DeviceItem = {
      id: this.selectedDeviceId,
      name: name,
      host: '',
      tcpPort: 0,
      deviceType: '',
      online: false
    };
    return [item];
  }

  @Builder
  manualForm() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.manualHost, placeholder: 'host' })
          .layoutWeight(5)
          .height(40)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .onChange((v: string) => {
            this.manualHost = v;
          })
        TextInput({ text: this.manualPort, placeholder: 'port' })
          .layoutWeight(3)
          .height(40)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .onChange((v: string) => {
            this.manualPort = v;
          })
        Button($r('app.string.connect'))
          .layoutWeight(3)
          .height(40)
          .fontSize(13)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(10)
          .onClick(() => {
            // 裁定表 #10（双层校验）：空端口用默认值；非数字原样传 NaN 交上层 toast 提示
            //（旧写法 `parseInt || 1716` 会把 NaN 吞成默认端口，用户得不到任何反馈）。
            const raw: string = this.manualPort.trim();
            const parsed: number = raw.length === 0 ? 1716 : parseInt(raw, 10);
            this.onManualConnect(this.manualHost.trim(), parsed);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  sectionContent() {
    Column({ space: 8 }) {
      // 「已连接设备」分区：只有选中设备（默认自动选中已连接的第一台）时才显示标题 + 详情页；
      // 没有可选设备时不再渲染一个空壳页，直接给「请选择设备查看功能」提示
      if (!(this.deviceSection === 0 && !this.selectedDeviceVisible())) {
        Row({ space: 8 }) {
          Text(this.sectionTitleOf(this.deviceSection))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
      }
      if (this.deviceSection === 0) {
        // 已连接设备只保留「详情/功能页」，默认直接用（自动选中第一台已连接设备）
        if (this.selectedDeviceVisible()) {
          ForEach(this.selectedDeviceList(),
            (d: DeviceItem) => {
              this.deviceDetail(d)
            }, (d: DeviceItem) => d.id)
        } else {
          this.emptyHint($r('app.string.select_device_hint'))
        }
      } else if (this.deviceSection === 1) {
        // 横屏：发现列表在左侧栏（带下拉刷新与配对按钮），右侧不再重复
        if (this.sideBySide) {
          this.emptyHint($r('app.string.select_device_hint'))
        } else {
        // 下拉刷新：手动触发一次 identity 广播（对端后启动/丢包时用）。
        // 用官方组合 Refresh + List：List 是可滚动子组件（下拉手势生效），且内容**从顶部排列**
        // （此前 Refresh + Scroll + height('100%') 高度解析失败 → 内容被垂直居中，用户反馈"从中间开始"）。
        Refresh({ refreshing: $$this.discoveryRefreshing }) {
          Scroll() {
            Column({ space: 8 }) {
              if (this.discoveredDevices.length === 0) {
                this.emptyHint($r('app.string.discovered_hint'))
              }
              ForEach(this.discoveredDevices, (d: DeviceItem) => {
                this.discoveredRow(d)
              }, (d: DeviceItem) => d.id)
            }
            .width('100%')
            // 关键：填满 Scroll 并顶部对齐。若不给高度，Scroll 会把内容**垂直居中**
            // （真机/模拟器实测：卡片内只剩 77px 内容却居中在卡片中间 → 用户反馈"列表从中间开始"）。
            .height('100%')
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Start)
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        // 不再 layoutWeight(1)：Refresh 按内容高度布局（撑满时其内部会把内容垂直居中，
        // 实测表现为「列表从卡片中间开始」）；内容高度即下拉手势区域。
        .onRefreshing(() => {
          this.onRefreshDiscovery();
          setTimeout((): void => {
            this.discoveryRefreshing = false;
          }, 1500);
        })
        }
      } else if (this.deviceSection === 2) {
        if (this.rememberedDevices.length === 0) {
          this.emptyHint($r('app.string.remembered_hint_empty'))
        }
        ForEach(this.rememberedDevices, (r: RememberedDevice) => {
          this.rememberedRow(r)
        }, (r: RememberedDevice) => r.id)
      } else {
        this.manualForm()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  mainArea() {
    // fill：并排侧栏模式下卡片填满主区高度（与侧栏等高，避免底部空出一块）
    GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial, fill: this.sideBySide }) {
      this.sectionContent()
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.sideBySide) {
        // 横屏平板：侧栏常驻占 30%（已连接 / 发现 均为可点设备列表），右侧主区
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            this.sidePanel()
          }
          .width('30%')
          .constraintSize(WIDE_RAIL_LIMIT)
          .height('100%')
          .padding(6)
          .borderRadius(18)
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Start)

          Column() {
            this.mainArea()
          }
          .layoutWeight(1)
          .height('100%')
          .alignItems(HorizontalAlign.Start)
          .onAreaChange((_old: Area, area: Area) => {
            this.onPaneArea(area);
          })
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      } else {
        // 竖屏（手机与平板竖屏同款）：标题旁汉堡拉抽屉（Index），此处只剩主区单列
        Column({ space: 10 }) {
          Column() {
            this.mainArea()
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .onAreaChange((_old: Area, area: Area) => {
            this.onPaneArea(area);
          })
        }
        .width('100%')
        .layoutWeight(1)
      }

    }
    .width('100%')
    .height('100%')
  }
}
