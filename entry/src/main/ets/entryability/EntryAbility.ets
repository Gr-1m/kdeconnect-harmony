import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
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
