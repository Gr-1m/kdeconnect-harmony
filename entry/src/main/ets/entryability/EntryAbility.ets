import { KcBridge } from '../net/KcBridge';
// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
// KI-1 ①：短时任务（TransientTask，**免权限**）。SDK 依据见 MSG113：@ohos.resourceschedule.backgroundTaskManager
// 的 requestSuspendDelay 属 SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask，
// .d.ts 上无 @permission（长时任务才需被华为驳回的 KEEP_BACKGROUND_RUNNING）。
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
// S0/S2（系统分享）：分享方经 want 授予**临时**读权限 ⇒ 必须在 Ability 内立刻复制到沙箱。
import { systemShare } from '@kit.ShareKit';
import { fileIo } from '@kit.CoreFileKit';
// S1：分享意图的纯逻辑（零 Kit；宿主可测）
import { buildShareIntent, ShareIntent, SharedRecordLike } from '../common/ShareIntent';
import { BusinessError } from '@kit.BasicServicesKit';
// KI-1 ②：停栈迁到本 Ability（页面 aboutToDisappear 不再停栈）。

export default class EntryAbility extends UIAbility {
  // KI-1 ①：本次后台会话的短时任务 id（-1 = 未申请）。
  private transientTaskId: number = -1;
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
    // S0/S2：冷启动即可能带着分享来（分享面板 → 本应用）
    this.consumeShareWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onNewWant');
    // S0/S2：应用已在运行时的新分享
    this.consumeShareWant(want);
  }

  /**
   * 系统分享入口（DESIGN_SYSTEM_SHARE §3.5）。
   * S0 目标：确认面板出现 + 抓 `SharedRecord` 真实形状 + 验证「复制到沙箱」的权限是否够。
   * S2 目标：复制完成后把意图写进 `AppStorage('pendingShareData')` 供页面消费（本轮已带上，页面消费属 S3）。
   */
  private consumeShareWant(want: Want): void {
    if (want.action !== 'ohos.want.action.sendData') {
      return;                                   // 普通启动/其它 want：不处理
    }
    hilog.info(0x0000, 'KDC-Share', '%s', 'share want received');
    systemShare.getSharedData(want).then((data: systemShare.SharedData): void => {
      const records: systemShare.SharedRecord[] = data.getRecords();
      hilog.info(0x0000, 'KDC-Share', 'records=%{public}d', records.length);
      // S1：Kit 对象 → 纯镜像（ArkTS 禁结构化类型 ⇒ 必须逐字段显式构造）
      const likes: SharedRecordLike[] = [];
      for (const r of records) {
        const like: SharedRecordLike = {
          utd: r.utd, uri: r.uri, content: r.content, title: r.title, label: r.label
        };
        likes.push(like);
      }
      const plan: ShareIntent = buildShareIntent(likes);
      const texts: string[] = plan.texts;
      const files: string[] = [];
      const dir: string = `${this.context.cacheDir}/share`;
      try {
        fileIo.mkdirSync(dir);
      } catch (e) {
        // 已存在即可
      }
      let index: number = 0;
      for (const r of records) {
        index++;
        // S0 取证：逐条记录真实字段（uri/content/utd/title/label/description）
        hilog.info(0x0000, 'KDC-Share',
          'rec#%{public}d utd=%{public}s uri=%{public}s content=%{public}s title=%{public}s label=%{public}s',
          index, r.utd, r.uri ?? '-', (r.content ?? '-').substring(0, 40), r.title ?? '-', r.label ?? '-');
        if (r.content !== undefined && r.content.length > 0 && (r.uri === undefined || r.uri.length === 0)) {
          texts.push(r.content);
          continue;
        }
        if (r.uri !== undefined && r.uri.length > 0) {
          const ext: string = r.uri.includes('.') ? r.uri.substring(r.uri.lastIndexOf('.')) : '';
          const dest: string = `${dir}/share_${Date.now()}_${index}${ext}`;
          // 显示名（发给对端的 filename）在 plan 里已按记录顺序算好；这里只保证沙箱名唯一
          try {
            // 分享方授予的临时 URI：立即复制（授权不跨 Ability/进程）
            fileIo.copyFileSync(r.uri, dest);
            const size: number = fileIo.statSync(dest).size;
            hilog.info(0x0000, 'KDC-Share', 'copied ok size=%{public}d -> %{public}s', size, dest);
            files.push(dest);
          } catch (e) {
            const err = e as BusinessError;
            hilog.error(0x0000, 'KDC-Share', 'copy failed code=%{public}d msg=%{public}s uri=%{public}s',
              err.code, err.message, r.uri);
          }
        }
      }
      // S2：写意图（页面消费属 S3；此处只落 AppStorage，未接 UI 时也不丢数据）
      // 显示名按 `plan.fileNames` 下标对齐（files 里此时是**沙箱路径**，名字来自 title/label/uri 清洗）
      const names: string[] = plan.fileNames.slice(0, files.length);
      AppStorage.setOrCreate('pendingShareData',
        JSON.stringify({ texts: texts, files: files, fileNames: names }));
      hilog.info(0x0000, 'KDC-Share',
        'pendingShareData kind=%{public}s texts=%{public}d files=%{public}d dropped=%{public}d',
        plan.kind, texts.length, files.length, plan.dropped.length);
      for (const d of plan.dropped) {
        hilog.warn(0x0000, 'KDC-Share', 'share record dropped: %{public}s', d);
      }
    }).catch((e: BusinessError): void => {
      hilog.error(0x0000, 'KDC-Share', 'getSharedData failed: %{public}d %{public}s', e.code, e.message);
    });
  }

  onDestroy(): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onDestroy');
    this.cancelTransientTask();
    // KI-1 ②：进程/Ability 真正销毁时才停栈（页面消失不再断链）。
    try {
      KcBridge.stop();
      hilog.info(0x0000, 'testTag', '%s', 'native.stop on ability destroy');
    } catch (e) {
      hilog.error(0x0000, 'testTag', 'native.stop failed: %{public}s',
        e instanceof Error ? e.message : 'unknown');
    }
  }

  /** KI-1 ①：回前台/销毁时成对取消短时任务（配额只在该用的时候用）。 */
  private cancelTransientTask(): void {
    if (this.transientTaskId < 0) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(this.transientTaskId);
      hilog.info(0x0000, 'testTag', 'transient task cancelled id=%{public}d', this.transientTaskId);
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'cancelSuspendDelay failed: %{public}s',
        e instanceof Error ? e.message : 'unknown');
    }
    this.transientTaskId = -1;
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
    this.cancelTransientTask();
  }

  onBackground(): void {
    hilog.info(0x0000, 'testTag', '%s', 'Ability onBackground');
    // KI-1 ①：切后台即申请短时任务，避免真机 ~18s 后被 OnAppFrozen 冻结（链路/在途传输全废）。
    // 一次后台会话只申请一次；失败（如配额耗尽 9900002）只记日志并降级，不重试风暴。
    // reason 用**英文**（裁决：CodeArts MSG131 §3 #2 / AtomCode 两实例同建议）——该串会进系统电源
    // 管理/任务面板，英文可避免非中文环境下的显示与编码问题。
    try {
      if (this.transientTaskId < 0) {
        const info: backgroundTaskManager.DelaySuspendInfo =
          backgroundTaskManager.requestSuspendDelay('KDE Connect: keep link and transfers alive', () => {
            hilog.info(0x0000, 'testTag', '%s', 'transient task about to expire');
          });
        this.transientTaskId = info.requestId;
        hilog.info(0x0000, 'testTag', 'transient task id=%{public}d delay=%{public}dms',
          info.requestId, info.actualDelayTime);
      }
    } catch (e) {
      hilog.error(0x0000, 'testTag', 'requestSuspendDelay failed: %{public}s',
        e instanceof Error ? e.message : 'unknown');
    }
  }
}
