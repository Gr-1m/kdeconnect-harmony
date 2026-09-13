import uiMaterial from '@ohos.arkui.uiMaterial';
import { DeviceItem, RememberedDevice, BatteryItem } from '../model/DeviceModels';
import { GlassCard } from './GlassCard';

// 设备 Tab：
// - 手机（窄屏）：三条横线（汉堡）拉出抽屉式侧栏，占屏大部分 + 背景变暗，选中后收起回主区；
// - 平板（>=600vp）：侧栏常驻，展开时直接切换，收起只留三条横线。
@Component
export struct DevicesTab {
  @Link connectedDevices: DeviceItem[];
  @Link discoveredDevices: DeviceItem[];
  @Link rememberedDevices: RememberedDevice[];
  @Prop immersive: boolean = false;
  @Prop isWide: boolean = false;
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
  // 点设备行（发现页/已连接列表）→ 回到该设备的「功能页」（设备信息 + 大按钮）
  onOpenDevice: (d: DeviceItem) => void = () => {
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
  @State railExpanded: boolean = true;
  // 手动连接默认值：host 留空（10.0.2.2 只是 QEMU 模拟器的 NAT 网关，真机无意义），port 用默认端口
  @State manualHost: string = '';
  @State manualPort: string = '1716';
  // 发现列表下拉刷新态（触发广播后自动收起）
  @State discoveryRefreshing: boolean = false;

  // 侧栏开合：宽屏（平板）由本组件常驻侧栏自行伸缩；窄屏（手机）由页面标题旁的汉堡开抽屉
  private openSide(): void {
    if (this.isWide) {
      animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
        this.railExpanded = !this.railExpanded;
      });
    }
  }

  private pickSection(index: number): void {
    this.deviceSection = index;
  }

  // 是否处于配对态：**必须看 paired 标记**（需求 3 后条目会永久保留，
  // 只判断"存在条目"会把已解除配对的设备误判为已配对——用户实测反馈的 bug）
  private isPaired(deviceId: string): boolean {
    return this.rememberedDevices.some((r: RememberedDevice) => r.id === deviceId && r.paired);
  }

  private batteryOf(deviceId: string): string {
    const item: BatteryItem | undefined = this.batteryItems.find((b: BatteryItem) => b.deviceId === deviceId);
    return item === undefined ? '' : item.text;
  }

  private sectionTitleOf(index: number): ResourceStr {
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

  // 三条横线（汉堡）：不依赖 sys.symbol 资源，直接绘制
  @Builder
  hamburger() {
    Column({ space: 4 }) {
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.text_primary'))
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.text_primary'))
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.text_primary'))
    }
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .borderRadius(10)
    .backgroundColor($r('app.color.chip_bg'))
    .onClick(() => {
      this.openSide();
    })
  }

  @Builder
  railItem(index: number, label: ResourceStr, shortLabel: ResourceStr, count: number, expanded: boolean) {
    Column({ space: 2 }) {
      Text(expanded ? label : shortLabel)
        .fontSize(12)
        .fontColor(this.deviceSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .fontWeight(this.deviceSection === index ? FontWeight.Medium : FontWeight.Normal)
        .maxLines(2)
        .textAlign(TextAlign.Center)
      if (count > 0) {
        Text(`${count}`)
          .fontSize(10)
          .fontColor($r('app.color.accent_text'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(999)
          .backgroundColor($r('app.color.accent_soft'))
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor(this.deviceSection === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.pickSection(index);
    })
  }

  @Builder
  railList(expanded: boolean) {
    Column({ space: 6 }) {
      this.railItem(0, $r('app.string.connected_devices'), $r('app.string.rail_connected_short'),
        this.connectedDevices.length, expanded)
      this.railItem(1, $r('app.string.discovered_devices'), $r('app.string.rail_discovered_short'),
        this.discoveredDevices.length, expanded)
      this.railItem(2, $r('app.string.remembered_devices'), $r('app.string.rail_remembered_short'),
        this.rememberedDevices.length, expanded)
      this.railItem(3, $r('app.string.manual_connect'), $r('app.string.rail_manual_short'), 0, expanded)
    }
    .width('100%')
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
        Text(d.id)
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
        Text(d.host !== '' ? `${d.host}:${d.tcpPort}` : $r('app.string.address_pending'))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
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
      Circle({ width: 8, height: 8 })
        .fill($r('app.color.dot_remembered'))
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
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
    .border({ width: 1, color: $r('app.color.card_border') })
    .onClick(() => {
      this.onPlaceholderAction(key);
    })
  }

  // 设备详情（对齐参考稿主页面）：上方设备信息 + 下方大按钮
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
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 大按钮：暂为占位（功能未实现）
      Row({ space: 10 }) {
        this.actionCard('send_file', $r('sys.symbol.paperplane'),
          $r('app.string.action_send_file'), $r('app.string.action_send_file_desc'))
        this.actionCard('clipboard', $r('sys.symbol.text_clipboard'),
          $r('app.string.action_clipboard'), $r('app.string.action_clipboard_desc'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 10 }) {
        this.actionCard('find_phone', $r('sys.symbol.location_up'),
          $r('app.string.action_find_phone'), $r('app.string.action_find_phone_desc'))
        this.actionCard('ring', $r('sys.symbol.bell'),
          $r('app.string.action_ring'), $r('app.string.action_ring_desc'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 10 }) {
        this.actionCard('battery', $r('sys.symbol.battery'),
          $r('app.string.action_battery'), $r('app.string.action_battery_desc'))
        this.actionCard('media', $r('sys.symbol.screen_share'),
          $r('app.string.action_media'), $r('app.string.action_media_desc'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private selectedDeviceVisible(): boolean {
    if (this.selectedDeviceId.length === 0) {
      return false;
    }
    return this.connectedDevices.some((d: DeviceItem) => d.id === this.selectedDeviceId);
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
            const port: number = parseInt(this.manualPort, 10) || 1716;
            this.onManualConnect(this.manualHost, port);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  sectionContent() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.sectionTitleOf(this.deviceSection))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      if (this.deviceSection === 0) {
        // 抽屉里选中了设备 → 详情（信息 + 大按钮）；否则维持原来的已连接列表
        if (this.selectedDeviceVisible()) {
          ForEach(this.connectedDevices.filter((d: DeviceItem) => d.id === this.selectedDeviceId),
            (d: DeviceItem) => {
              this.deviceDetail(d)
            }, (d: DeviceItem) => d.id)
        } else {
          if (this.connectedDevices.length === 0) {
            this.emptyHint($r('app.string.group_empty'))
          }
          ForEach(this.connectedDevices, (d: DeviceItem) => {
            this.connectedRow(d)
          }, (d: DeviceItem) => d.id)
        }
      } else if (this.deviceSection === 1) {
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
    GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
      this.sectionContent()
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.isWide) {
        // 平板/宽屏：侧栏常驻（可收起为仅三条横线），右侧主区
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Row() {
              this.hamburger()
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            if (this.railExpanded) {
              this.railList(true)
            } else {
              this.railList(false)
            }
          }
          .width(this.railExpanded ? 104 : 52)
          .height('100%')
          .padding(6)
          .borderRadius(18)
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })

          Column() {
            this.mainArea()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      } else {
        // 手机：标题旁汉堡已在页面层（Index）；此处只剩主区
        Column({ space: 10 }) {
          Column() {
            this.mainArea()
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
      }

    }
    .width('100%')
    .layoutWeight(1)
  }
}
