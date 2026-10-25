// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { DeviceItem } from '../model/DeviceModels';
import { DrawerOverlay } from './DrawerOverlay';
import { FilesDrawerContent } from './FilesDrawerContent';
import { SettingsDrawerContent } from './SettingsDrawerContent';

@Component
export struct SideBarPanelHost {
  @StorageLink('sideConnectedList') sideConnected: DeviceItem[] = [];
  @StorageLink('sideDiscoveredList') sideDiscovered: DeviceItem[] = [];
  @StorageLink('sideRememberedCount') sideRememberedCount: number = 0;
  @StorageLink('sideDeviceSection') sideDeviceSection: number = 0;
  @StorageLink('sideCurrentTab') sideCurrentTab: number = 0;
  @StorageLink('sideSettingsSection') sideSettingsSection: number = 0;

  @Prop selectedDeviceId: string = '';
  @Prop requestedPairIds: string[] = [];
  @Prop settingsDeviceId: string = '';
  @Prop settingsStatusText: string = '';
  @Prop settingsAppVersion: string = '';
  @Link drawerExpanded: boolean;
  onClose: () => void = () => {};
  onOpenDevice: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPairRequest: (d: DeviceItem) => void = (_d: DeviceItem) => {};
  onPickSection: (index: number) => void = (_i: number) => {};
  isPaired: (deviceId: string) => boolean = (_id: string) => false;

  build() {
    if (this.sideCurrentTab === 0) {
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
    } else if (this.sideCurrentTab === 1) {
      FilesDrawerContent()
    } else if (this.sideCurrentTab === 2) {
      SettingsDrawerContent({
        settingsSection: this.sideSettingsSection,
        onPickSection: (index: number): void => {
          this.onPickSection(index);
        },
        onClose: (): void => {
          this.onClose();
        }
      })
    } else {
      Column() {
        Row() {
          Text('KDE Connect')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .margin({ left: 12 })
        }
        .width('100%')
        .margin({ bottom: 4 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 16 })
      .alignItems(HorizontalAlign.Start)
    }
  }
}
