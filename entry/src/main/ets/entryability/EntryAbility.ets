// SPDX-License-Identifier: GPL-2.0-or-later
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';

export default class EntryAbility extends UIAbility {
  // 手机端禁旋转（用户 2026-09-15 要求）：本 App 的「横屏」= 平板并排侧栏布局，手机上不该出现。
  // 判定：平板/2in1/桌面/电视 → 跟随系统（module.json5 的 auto_rotation）；其余（phone/wearable/未知）→ 锁竖屏。
  // deviceType 判不出来时用屏幕最小边兜底（< 600vp 视为手机）。
  private isLargeScreenDevice(): boolean {
    const dt: string = deviceInfo.deviceType;
    if (dt === 'tablet' || dt === '2in1' || dt === 'pc' || dt === 'desktop' || dt === 'tv') {
      return true;
    }
    if (dt !== 'default' && dt !== '') {
      return false;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      const minVp: number = Math.min(d.width, d.height) / density;
      return minVp >= 600;
    } catch (e) {
      return false;
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onWindowStageCreate');
    // 沉浸式全屏：内容延伸到状态栏/导航栏下方，安全区高度经 AppStorage 传给页面
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true);
      const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('statusBarHeightPx', avoid.topRect.height);
      AppStorage.setOrCreate('navBarHeightPx', avoid.bottomRect.height);
      try {
        win.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            AppStorage.setOrCreate('statusBarHeightPx', data.area.topRect.height);
            AppStorage.setOrCreate('navBarHeightPx', data.area.bottomRect.height);
          }
        });
      } catch (e2) {
        hilog.warn(0x0000, 'testTag', 'avoidAreaChange listen failed: %{public}s',
          e2 instanceof Error ? e2.message : 'unknown');
      }
      // 手机（窄屏）锁竖屏；平板等大屏保持 auto_rotation，横屏走并排侧栏
      const LOCK_PHONE_PORTRAIT: boolean = true;
      if (!LOCK_PHONE_PORTRAIT || this.isLargeScreenDevice()) {
        hilog.info(0x0000, 'testTag', 'orientation follows system (deviceType=%{public}s)',
          deviceInfo.deviceType);
      } else {
        win.setPreferredOrientation(window.Orientation.PORTRAIT, (err) => {
          if (err) {
            hilog.error(0x0000, 'testTag', 'lock portrait failed: %{public}s', err.message ?? '');
            return;
          }
          hilog.info(0x0000, 'testTag', 'orientation locked to PORTRAIT (deviceType=%{public}s)',
            deviceInfo.deviceType);
        });
      }
    } catch (e) {
      hilog.error(0x0000, 'testTag', 'FullScreen setup failed: %{public}s',
        e instanceof Error ? e.message : 'unknown');
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'testTag', 'Failed to load content. Cause: %{public}s', err.message ?? '');
        return;
      }
      hilog.info(0x0000, 'testTag', 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onBackground');
  }
}
