// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { DeviceItem } from '../model/DeviceModels';
import { DeviceController } from '../state/DeviceController';
import { DrawerOverlay } from './DrawerOverlay';

// 【修 B（用户 2026-10-13）】侧栏面板宿主 —— 数据走 **AppStorage 全局可观察**。
//
// 背景（三次尝试的结论）：
//   ① 页面级 builder 闭包里直接读 `@Observed` 控制器内部数据 —— 页面不重跑 ⇒ 面板停在初始空态；
//   ② 本宿主改用 `@ObjectLink` —— 仍失败（父级 builder 子树被 `HdsSideBar` 缓存、订阅未重建）；
//   ③ 页面 `@State` 快照 + `@Watch(drawerOpen)` 同步 —— 仍失败（同上原因）。
// ⇒ 结论：`HdsSideBar` 会缓存 `sideBarPanelBuilder` 构建出的子树，**父级怎么重跑都不会重新求值**；
//   因此面板数据必须由**本组件自己订阅的数据源**驱动，且该订阅不能依赖父级重渲染。
// ⇒ 采用 `@StorageLink`（AppStorage）：页面把派生列表写进 AppStorage，本组件订阅 ⇒ 键一变即刷新 ✓。
@Component
export struct SideBarPanelHost {
  // AppStorage 订阅（页面在 syncSideBarLists() 内写入）
  @StorageLink('sideConnectedList') sideConnected: DeviceItem[] = [];
  @StorageLink('sideDiscoveredList') sideDiscovered: DeviceItem[] = [];
  @StorageLink('sideRememberedCount') sideRememberedCount: number = 0;
  @StorageLink('sideDeviceSection') sideDeviceSection: number = 0;

  @Prop selectedDeviceId: string = '';
  @Prop requestedPairIds: string[] = [];
  @Link drawerExpanded: boolean;
  onClose: () => void = () => {};
  onOpenDevice: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPairRequest: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPickSection: (index: number) => void = (_i: number) => {};
  isPaired: (deviceId: string) => boolean = (_id: string) => false;

  build() {
    DrawerOverlay({
      connectedList: this.sideConnected,
      discoveredList: this.sideDiscovered,
      rememberedCount: this.sideRememberedCount,
      selectedDeviceId: this.selectedDeviceId,
      requestedPairIds: this.requestedPairIds,
      deviceSection: this.sideDeviceSection,
      drawerExpanded: this.drawerExpanded,
      onClose: (): void => {
        this.onClose();
      },
      onOpenDevice: (d: DeviceItem): void => {
        this.onOpenDevice(d);
      },
      onPairRequest: (d: DeviceItem): void => {
        this.onPairRequest(d);
      },
      onPickSection: (index: number): void => {
        this.onPickSection(index);
      },
      isPaired: (deviceId: string): boolean => {
        return this.isPaired(deviceId);
      }
    })
  }
}
