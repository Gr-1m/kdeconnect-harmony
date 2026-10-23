// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { DeviceItem } from '../model/DeviceModels';

const DRAWER_DEVICE_CAP: number = 2;

@Component
export struct DrawerOverlay {
  connectedList: DeviceItem[] = [];
  discoveredList: DeviceItem[] = [];
  rememberedCount: number = 0;
  @Prop selectedDeviceId: string = '';
  @Prop requestedPairIds: string[] = [];
  @Prop deviceSection: number = 0;
  @Link drawerExpanded: boolean;
  onClose: () => void = () => {};
  onOpenDevice: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPairRequest: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPickSection: (index: number) => void = (_i: number) => {};
  isPaired: (deviceId: string) => boolean = (_id: string) => false;
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;

  private visibleDrawerDevices(): DeviceItem[] {
    const list: DeviceItem[] = this.connectedList;
    if (this.drawerExpanded || list.length <= DRAWER_DEVICE_CAP) {
      return list;
    }
    return list.slice(0, DRAWER_DEVICE_CAP);
  }

  private addressOf(d: DeviceItem): ResourceStr {
    if (d.host === '') {
      return $r('app.string.address_pending');
    }
    return d.tcpPort > 0 ? `${d.host}:${d.tcpPort}` : d.host;
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('KDE Connect')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })
      }
      .width('100%')
      .margin({ bottom: 4 })

      Scroll() {
        Column({ space: 6 }) {
          Text($r('app.string.connected_devices'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 4, bottom: 4 })
          if (this.connectedList.length === 0) {
            Text($r('app.string.drawer_pick_device_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
          }
          ForEach(this.visibleDrawerDevices(), (d: DeviceItem) => {
            this.drawerDeviceRow(d)
          }, (d: DeviceItem) => `conn-${d.id}`)

          if (this.connectedList.length > DRAWER_DEVICE_CAP) {
            Row({ space: 6 }) {
              Text(this.drawerExpanded ? $r('app.string.drawer_collapse') : $r('app.string.drawer_expand'))
                .fontSize(13)
                .fontColor($r('app.color.accent_text'))
              SymbolGlyph(this.drawerExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(13)
                .fontColor([$r('app.color.accent_text')])
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
                this.drawerExpanded = !this.drawerExpanded;
              });
            })
          }

          Text($r('app.string.discovered_devices'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 10, bottom: 4 })
          if (this.discoveredList.length === 0) {
            Text($r('app.string.discovered_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
          }
          ForEach(this.discoveredList, (d: DeviceItem) => {
            this.drawerPairRow(d)
          }, (d: DeviceItem) => `disc-${d.id}`)

          this.drawerSectionRow(2, $r('app.string.remembered_devices'), this.rememberedCount)
          this.drawerSectionRow(3, $r('app.string.manual_connect'), 0)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.getUIContext().px2vp(this.statusBarHeightPx) + 16,
      bottom: 16
    })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  drawerDeviceRow(d: DeviceItem) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.computer'))
          .fontSize(22)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor($r('app.color.chip_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(15)
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
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.isPaired(d.id) ? $r('app.string.remembered_hint') : $r('app.string.remembered_unpaired'))
        .fontSize(10)
        .fontColor(this.isPaired(d.id) ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor($r('app.color.chip_bg'))
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.selectedDeviceId === d.id ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.onOpenDevice(d);
    })
  }

  @Builder
  drawerPairRow(d: DeviceItem) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.computer'))
          .fontSize(22)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor($r('app.color.chip_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(d.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.addressOf(d))
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.requestedPairIds.includes(d.id)) {
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
            this.onPairRequest(d);
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .onClick(() => {
      this.onPairRequest(d);
    })
  }

  @Builder
  drawerSectionRow(index: number, label: ResourceStr, count: number) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(14)
        .fontColor(this.deviceSection === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .fontWeight(this.deviceSection === index ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
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
    .padding({ left: 12, right: 12, top: 15, bottom: 15 })
    .borderRadius(12)
    .backgroundColor(this.deviceSection === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      this.onPickSection(index);
    })
  }
}
