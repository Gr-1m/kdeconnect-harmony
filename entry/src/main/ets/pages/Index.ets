// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import native from 'libkdeconnect_napi.so';
import { NetConfig, CertPair, NetEvent } from 'libkdeconnect_napi.so';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { Context, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { display, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import deviceInfo from '@ohos.deviceInfo';
import { PacketRouter, RouterCallbacks } from '../net/PacketRouter';
import { PluginBase } from '../plugins/PluginBase';
import { PluginEvent } from '../plugins/PluginEvent';
import { PluginRegistry } from '../plugins/PluginRegistry';
import { PluginHost } from '../plugins/PluginHost';
import { PingPlugin } from '../plugins/PingPlugin';
import { SharePlugin } from '../plugins/SharePlugin';
import { BatteryPlugin } from '../plugins/BatteryPlugin';
import { ClipboardPlugin } from '../plugins/ClipboardPlugin';
import { FindMyPhonePlugin } from '../plugins/FindMyPhonePlugin';
import { RunCommandPlugin, RunCommandEntry } from '../plugins/RunCommandPlugin';
import { ConnectivityReportPlugin } from '../plugins/ConnectivityReportPlugin';
import { SystemVolumePlugin } from '../plugins/SystemVolumePlugin';
import { MprisPlugin } from '../plugins/MprisPlugin';
import { RemoteInputPlugin } from '../plugins/RemoteInputPlugin';
import { NotificationPlugin } from '../plugins/NotificationPlugin';
import { DeviceItem, BatteryItem } from '../model/DeviceModels';
import { PayloadTransfer } from '../model/PayloadModels';
import { MprisSnapshot } from '../model/MprisModels';
import { TrustedDevice } from '../model/TrustModels';
import { TrustStore } from '../common/TrustStore';
import { PayloadHistory } from '../common/PayloadHistory';
import { PayloadDetailDialog } from '../components/PayloadDetailDialog';
import { PairConfirmDialog } from '../components/PairConfirmDialog';
import { RunCommandDialog } from '../components/RunCommandDialog';
import { MprisDialog } from '../components/MprisDialog';
import { ReceivedFilesDialog } from '../components/ReceivedFilesDialog';
import { NotificationHelper } from '../common/NotificationHelper';
import { NetworkWatcher } from '../common/NetworkWatcher';
import { colorModeOf, languageOf, LANG_SYSTEM, THEME_FOLLOW_SYSTEM, systemDeviceName } from '../common/AppSettings';
import { DevicesTab } from '../components/DevicesTab';
import { DrawerOverlay } from '../components/DrawerOverlay';
import { FilesTab } from '../components/FilesTab';
import { SettingsTab } from '../components/SettingsTab';
import { LogsTab } from '../components/LogsTab';
import { PairSession } from '../state/PairSession';
import { PluginEventBus } from '../state/PluginEventBus';
import { MprisController } from '../state/MprisController';
import { PayloadController, SendJob } from '../state/PayloadController';
import { SettingsController, SettingEntry } from '../state/SettingsController';
import { PluginEventHandlers } from '../state/PluginEventHandlers';
import { DeviceController } from '../state/DeviceController';
import { DeviceActionController } from '../state/DeviceActionController';
import hilog from '@ohos.hilog';

// timestamp 仅 pair 请求需要（KDE pair 响应体只含 {"pair": false}）
// 底部悬浮栏 Tab 定义（设备 / 文件 / 设置 / 日志[开发期]）
interface TabDef {
  label: ResourceStr;
}

// 连接/配对会话超时（毫秒）：TCP+TLS 建连 20s；配对请求等对端确认 45s
// （对端 KDE PairingHandler::pairingTimeoutMsec 也是 30s：本侧必须留更长，
//  否则用户还在点对端通知时本侧就先判失败。见 MSG65 §2）
const CONNECT_TIMEOUT_MS: number = 20000;
const PAIR_TIMEOUT_MS: number = 45000;
// 抽屉收起态最多显示的已连接设备数（超出才出现「展开 ⌄」）
const DRAWER_DEVICE_CAP: number = 2;
// 抽屉面板宽度上限（vp）：大屏上 78% 会撑成一条巨板，故夹住
const DRAWER_WIDTH_LIMIT: ConstraintSizeOptions = { maxWidth: 360 };
// 一次最多选几个文件发送（用户 2026-09-18 拍板改为多选；上限取值与系统文件选择器常见上限一致）
const MAX_PICK_FILES: number = 9;

// 注（CodeArts MSG45 §1 授权清理）：`code=110` 有界重试已按裁定 #15 撤除，它遗留下的
// `SendJob.attempt` 字段与 `PAYLOAD_ERR_HANDSHAKE_TIMEOUT` / `MAX_SEND_ATTEMPT` 两个常量在此删除 ——
// 避免"注释引用已不存在的常量"。若将来要恢复重试，依据见 DevEco MSG38（待 native 阶段诊断数据定位）。

@Entry
@Component
struct Index {
  @State status: string = 'booting';
  // 通知/日志工具（阶段 3 批次 1 步骤 5c ⇒ common/NotificationHelper.ets）：日志缓冲与节流、
  // 提示文案映射全在模块里；页面只负责注入（resText/showToast/setNoticeKey/logTabVisible）与渲染。
  // logStore（@Observed）由页面转交给 LogsTab 的 @ObjectLink —— 写它只重建 LogsTab，不重建页面其余部分。
  private notify: NotificationHelper = new NotificationHelper();
  // 局域网发现：网络变化监听（阶段 3 批次 1 步骤 5d ⇒ common/NetworkWatcher.ets）
  private netWatcher: NetworkWatcher = new NetworkWatcher();
  @State currentTab: number = 0;
  // 事件日志开关：true 时打印完整事件 JSON（排查用）；常态 false ⇒ 只打轻量摘要
  private debugEventLog: boolean = false;
  // 卡片忙碌态【补丁·待优化】（用户 2026-09-16 提案 / CodeArts MSG6-7 批准）：
  // 点击卡片后该卡片短期内不接受再次点击，等「弹窗已弹出」或「功能已执行」再恢复；
  // 5s 保险丝兜底（日志区分 fired by event / fired by timeout）。仅逻辑，不改视觉。
  @State cardBusyKey: string = '';
  private cardBusyTimer: number = -1;
  @State settingsController: SettingsController = new SettingsController();
  @State systemName: string = '';
  @State isWide: boolean = false;
  // 横屏判定（宽 > 高）
  @State isLandscape: boolean = false;
  // 并排侧栏模式：**仅横屏宽屏**（左侧栏常驻 30%）；竖屏（含平板竖屏）一律走汉堡 + 抽屉
  @State sideBySide: boolean = false;
  @State immersiveSupported: boolean = false;
  @State deviceController: DeviceController = new DeviceController();
  private actionController: DeviceActionController = new DeviceActionController();
  // 连接/配对会话状态机（阶段 2 拆分 ⇒ state/PairSession.ets）：状态与副作用分离，本页只装配 + 转发 + 渲染。
  //   stage: connecting=连接中（**只有 toast，不弹模态**）；prompt=配对确认弹窗（两侧共用，显示验证码）；
  //          awaiting=已发配对帧，等对端确认
  // 副作用（发包/连对端/提示/日志/配对态收敛）全部经下面注入的回调走页面既有实现。
  @State pairSession: PairSession = new PairSession();
  // 插件事件路由表（阶段 2 步骤 4，state/PluginEventBus.ets）：本批先加字段，装配在下一步。
  private eventBus: PluginEventBus = new PluginEventBus();
  // 顶部临时提示（连接中/连接成功/连接失败/配对成功…）
  @State noticeKey: string = '';
  // 手机窄屏侧栏抽屉：**必须在根 Stack（全屏）渲染**——放在内容区会因 padding(16) 内缩，
  // 表现为「面板不贴边 + 遮罩是内缩的直角暗层」（用户实测反馈）。
  @State drawerOpen: boolean = false;
  // 抽屉里「展开 ⌄」只用于**已连接设备列表**（对齐参考稿「我的产品」：先露前几个，点开看全部）
  @State drawerExpanded: boolean = false;
  private noticeTimerId: number = -1;
  // 点击/发包限频（key = "设备:动作" → 上次触发时刻）。手机实测：卡片点太快会连发网络请求 +
  // 连开弹窗，叠加重渲染直接把主线程压死（THREAD_BLOCK_3S/6S → 点击无响应）。
  private actionGateMs: Map<string, number> = new Map();
  // 音量 Slider 的「用户是否真在拖」标志（已随 MprisDialog 下沉，页面不再持有）
  // 插件推来的展示项（目前：电量）
  @State batteryItems: BatteryItem[] = [];
  @State runCommands: RunCommandEntry[] = [];
  @State runCommandDeviceId: string = '';
  @State runCommandDialogOpen: boolean = false;
  @State mprisController: MprisController = new MprisController();
  @State payloadController: PayloadController = new PayloadController();
  private pluginHandlers: PluginEventHandlers = new PluginEventHandlers();
  // 状态栏 / 导航栏安全区高度（EntryAbility 写入，单位 px）
  @StorageProp('statusBarHeightPx') statusBarHeightPx: number = 0;
  @StorageProp('navBarHeightPx') navBarHeightPx: number = 0;
  // 沉浸光感底栏：官方推荐走 HdsTabs + barFloatingStyle（悬浮胶囊 + systemMaterialEffect），
  // 需 HarmonyOS 运行时（@kit.UIDesignKit 属 HMS/商用 SDK）。
  // 卡片等非 TabBar 区域不在沉浸光感生效范围，仍走毛玻璃。
  private tabsController: HdsTabsController = new HdsTabsController();
  private deviceId: string = '';
  private certPem: string = '';
  private keyPem: string = '';
  private router: PacketRouter | undefined = undefined;
  // AP-4 插件框架：注册表驱动，每设备一份实例
  private pluginRegistry: PluginRegistry = new PluginRegistry();
  private pluginHost: PluginHost | undefined = undefined;
  private pageShown: boolean = false;
  private settingsLoaded: boolean = false;
  private settingsApplied: boolean = false;
  private tabs: TabDef[] = [
    { label: $r('app.string.tab_devices') },
    { label: $r('app.string.tab_files') },
    { label: $r('app.string.tab_settings') },
    { label: $r('app.string.tab_logs') }
  ];

  async aboutToAppear(): Promise<void> {
    this.initImmersiveMaterial();
    this.detectScreenWidth();

    // 优先取 UI host context（getContext 已弃用）；页面级 aboutToAppear 时必然可用
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.status = 'no host context';
      return;
    }
    const ctx: Context = hostCtx;

    let deviceId: string = '';
    let certPem: string = '';
    let keyPem: string = '';
    try {
      const pref = await preferences.getPreferences(ctx, 'kdeconnect');
      deviceId = String(await pref.get('deviceId', ''));
      // 已接收文件历史：跨重启保留（与应用设置同一个 Preferences 库）
      this.payloadController.history = await PayloadHistory.load(ctx);
      // 回灌到 payloads：文件页的「历史记录」分区直接读 payloads，不回灌则重启后历史为空
      // （2026-09-17 用户实测「历史文件只有一条」——发送记录既没入库也没回灌）。
      // 注意：历史条目一律置 settled=true —— 它们是**已结束**的旧记录，spool 早被清理，
      // 否则会被归到「收到的文件（待处置）」并诱使用户点「保存」而必然失败。
      this.payloadController.payloads = this.payloadController.history.map((h: PayloadTransfer): PayloadTransfer => {
        const settledHist: PayloadTransfer = {
          transferId: h.transferId,
          deviceId: h.deviceId,
          direction: h.direction,
          state: h.state,
          fileName: h.fileName,
          size: h.size,
          bytesDone: h.bytesDone,
          filePath: h.filePath,
          settled: true
        };
        return settledHist;
      });
      certPem = String(await pref.get('certPem', ''));
      keyPem = String(await pref.get('keyPem', ''));
      // 设备名称：用户改过就用用户的；没改过 → 读**系统设备名称**（设置→关于本机→设备名称，回退市场名/型号）
      this.settingsController.deviceName = String(await pref.get('deviceName', ''));
      this.systemName = systemDeviceName(ctx);
      if (this.settingsController.deviceName.length === 0) {
        this.settingsController.deviceName = this.systemName;
      }
      this.settingsController.themeMode = parseInt(String(await pref.get('themeMode', '0')), 10) || THEME_FOLLOW_SYSTEM;
      this.settingsController.language = String(await pref.get('language', LANG_SYSTEM));
      // AP-3：信任设备（含旧的 rememberedDevices 一次性迁移）—— 经 DeviceController.rehydrateTrust 统一处理
      const loaded: TrustedDevice[] = await TrustStore.load(ctx);
      this.deviceController.rehydrateTrust(loaded);
    } catch (e) {
      this.notify.log('Preferences load failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    // 设置读取完成后再应用（否则 onPageShow 可能早于读取完成，把默认值当成当前值应用 → 表现为"重开恢复默认"）
    this.settingsLoaded = true;
    console.info(`KDC settings loaded: deviceName=${this.settingsController.deviceName} themeMode=${this.settingsController.themeMode} language=${this.settingsController.language}`);
    this.applySettingsIfReady();

    if (deviceId.length < 32 || certPem === '' || keyPem === '') {
      deviceId = util.generateRandomUUID().replace(/-/g, '');
      const cert: CertPair = native.generateCert(deviceId);
      certPem = cert.certPem;
      keyPem = cert.keyPem;
      try {
        const pref = await preferences.getPreferences(ctx, 'kdeconnect');
        await pref.put('deviceId', deviceId);
        await pref.put('certPem', certPem);
        await pref.put('keyPem', keyPem);
        await pref.flush();
      } catch (e) {
        // Persist failed, continue with in-memory values
      }
    }

    this.deviceId = deviceId;
    this.certPem = certPem;
    this.keyPem = keyPem;

    const self = this;
    try {
      native.init((event: NetEvent): void => {
        self.deviceController.handleEvent(event);
      });
    } catch (e) {
      this.status = 'init failed: ' + (e instanceof Error ? e.message : 'unknown');
      return;
    }
    // AP-4：注册插件（能力交由 registry 汇总）+ 建插件宿主
    this.pluginRegistry.register('ping', (): PingPlugin => new PingPlugin());
    // M1 锚点：接收桌面文件。能力必须声明，否则 KDE 会收窄并拒发 share 请求。
    this.pluginRegistry.register('share', (): SharePlugin => new SharePlugin());
    this.pluginRegistry.register('battery', (): BatteryPlugin => new BatteryPlugin());
    this.pluginRegistry.register('clipboard', (): ClipboardPlugin => new ClipboardPlugin());
    this.pluginRegistry.register('findmyphone', (): FindMyPhonePlugin => new FindMyPhonePlugin());
    // P1（MSG112）：远程命令 + 网络状态上报已实现；MPRIS/远程输入/通知仅声明能力（UI 属 P2）
    this.pluginRegistry.register('runcommand', (): RunCommandPlugin => new RunCommandPlugin());
    this.pluginRegistry.register('connectivityreport', (): ConnectivityReportPlugin => new ConnectivityReportPlugin());
    // 系统音量（与 MPRIS 播放器音量分开，用户 2026-09-18 要求）
    this.pluginRegistry.register('systemvolume', (): SystemVolumePlugin => new SystemVolumePlugin());
    this.pluginRegistry.register('mpris', (): MprisPlugin => new MprisPlugin());
    this.pluginRegistry.register('remoteinput', (): RemoteInputPlugin => new RemoteInputPlugin());
    this.pluginRegistry.register('notification', (): NotificationPlugin => new NotificationPlugin());
    this.pluginHost = new PluginHost(this.pluginRegistry, (m: string): void => {
      this.notify.log(m);
    });
    const callbacks: RouterCallbacks = {
      onPairRequest: (id: string, ts: number): void => {
        // 对端发起：交给状态机（内含"双方同时发起"race 检测）；验证码由页面算好写入（字段约定）。
        this.pairSession.onPeerPairRequest(id, ts);
        this.pairSession.code = this.deviceController.computePairCode(id, ts);
      },
      onPaired: (id: string): void => {
        this.deviceController.handlePaired(id);
        this.pairSession.onPeerPaired(id);
      },
      onUnpaired: (id: string): void => {
        this.pairSession.onPeerUnpaired(id);   // 内部 reset + 回调 onUnpaired ⇒ 唯一入口，勿在页面重复调用 handleUnpaired
      },
      onPeerCapabilities: (id: string, incoming: string[], outgoing: string[]): void => {
        this.loadPlugins(id, incoming, outgoing);
      },
      onPluginPacket: (id: string, packetType: string, body: Object): boolean =>
        this.dispatchPluginPacket(id, packetType, body)
    };
    this.router = new PacketRouter(this.deviceId, this.settingsController.deviceName, 'phone',
      (msg: string): void => {
        this.notify.log(msg);
      }, callbacks);
    // 阶段 2 接线：把会话状态机的副作用接回页面既有实现（状态机自身不碰 I/O/UI/持久化）。
    this.pairSession.onLog = (m: string): void => { this.notify.log(m); };
    this.pairSession.onNotice = (kind: string, detail: string, isError: boolean, code: number): void => {
      this.notify.showNotice(kind, detail, isError, code);
    };
    // ★ 发包走 PacketRouter（不按 §3.6 用裸 native.sendPacket）：
    //   router.acceptPair 会回调 onPaired ⇒ 页面 handlePaired 负责 trusted 登记与证书钉扎，绕开就丢 trust 落盘。
    this.pairSession.sendPair = (id: string, pair: boolean, withTs: boolean): boolean => {
      if (this.router === undefined) {
        return false;
      }
      if (!pair) {
        this.router.rejectPair(id);
        return true;
      }
      if (withTs) {
        // 用状态机里**固定**的时间戳（弹窗打开时确定）——保证与展示的验证码一致
        return this.router.requestPair(id, this.pairSession.timestamp);
      }
      return this.router.acceptPair(id);
    };
    this.pairSession.connectToPeer = (id: string, name: string, host: string, port: number): boolean => {
      try {
        native.connectToPeer(host, port);
        return true;
      } catch (e) {
        return false;
      }
    };
    this.pairSession.onPaired = (id: string): void => {
      this.deviceController.handlePaired(id);
      this.deviceController.deviceSection = 0;
      if (id.length > 0) {
        this.deviceController.selectedDeviceId = id;
        this.pruneActionGate();
      }
      this.notify.showNotice('paired', '', false);
    };
    this.pairSession.onUnpaired = (id: string): void => { this.deviceController.handleUnpaired(id); };

    // 阶段 2 步骤 4：插件事件路由装配（清单见 devdocs/PLUGIN_ROUTE_INVENTORY.md）。
    // 兜底与拆分前的"其余 kind 只记日志"逐字一致 —— **绝不静默丢弃**。
    this.eventBus.setLog((m: string): void => { this.notify.log(m); });
    this.eventBus.setFallback((id: string, ev: PluginEvent): void => {
      this.notify.log(`plugin event ${ev.kind} from ${id}`);
    });
    this.eventBus.on('runcommand.list', (id: string, ev: PluginEvent): void => { this.pluginHandlers.onRunCommandList(id, ev); });
    this.eventBus.on('runcommand.output', (id: string, ev: PluginEvent): void => { this.pluginHandlers.onRunCommandOutput(id, ev); });
    this.eventBus.on('clipboard.request', (id: string, ev: PluginEvent): void => { this.pluginHandlers.onClipboardRequest(id, ev); });
    this.eventBus.on('mpris.playerList', (id: string, ev: PluginEvent): void => { this.onMprisPlayerList(id, ev); });
    this.eventBus.on('mpris.playerUpdate', (id: string, ev: PluginEvent): void => { this.onMprisPlayerUpdate(id, ev); });
    this.eventBus.on('systemvolume.sinks', (id: string, ev: PluginEvent): void => { this.onSystemVolumeSinks(id, ev); });
    this.eventBus.on('battery', (id: string, ev: PluginEvent): void => { this.pluginHandlers.onBattery(id, ev); });

    // 阶段 3 批次 1 装配（步骤 5c/5d）：把页面能力注入抽出的模块（模块自身不碰 Context/UI/native）。
    // 5c NotificationHelper：日志与提示文案在模块里，页面只提供"必须有 Context/UI 才能做"的四件事。
    this.notify.resText = (resId: number): string => {
      try {
        const hostCtx: Context | undefined = this.getUIContext().getHostContext();
        if (hostCtx === undefined) {
          return '';
        }
        return hostCtx.resourceManager.getStringSync(resId);
      } catch (e) {
        return '';
      }
    };
    // ⚠️ toast 的 message 必须是**纯字符串**（带格式参数的 $r(...) 会被 PromptAction 拒绝，实测 "toast failed (4)"）
    this.notify.showToast = (message: string, ms: number): void => {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        duration: ms,
        bottom: '96vp'
      });
    };
    // noticeKey 仍是页面 @State（渲染用）⇒ 经回调写入，Helper 不反向持有页面状态
    this.notify.setNoticeKey = (key: string): void => {
      this.noticeKey = key;
    };
    this.notify.logTabVisible = (): boolean => this.currentTab === 3;
    // 5d NetworkWatcher：日志/限频/广播全部走页面既有实现（3s 限频那条历史坑在模块内原样保留）
    this.netWatcher.log = (msg: string): void => {
      this.notify.log(msg);
    };
    this.netWatcher.gate = (key: string, ms: number): boolean => this.actionGate(key, ms);
    this.netWatcher.triggerBroadcast = (): void => {
      this.triggerDiscoveryBroadcast();
    };
    // 阶段 3 批次 2 装配：MprisController + PayloadController 注入
    this.mprisController.log = (m: string): void => { this.notify.log(m); };
    this.mprisController.toast = (m: string): void => { this.notify.toast(m); };
    this.mprisController.resText = (resId: number): string => this.notify.resText(resId);
    this.mprisController.actionGate = (key: string, ms: number): boolean => this.actionGate(key, ms);
    this.mprisController.pluginsFor = (deviceId: string): PluginBase[] =>
      this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(deviceId);
    this.payloadController.log = (m: string): void => { this.notify.log(m); };
    this.payloadController.toast = (m: string): void => { this.notify.toast(m); };
    this.payloadController.resText = (resId: number): string => this.notify.resText(resId);
    this.payloadController.hostFilesDir = (): string => this.ensureKdcDir();
    this.payloadController.pickSaveTarget = (name: string): Promise<string> => this.pickSaveTarget(name);
    this.payloadController.pickDownloadTarget = (name: string): Promise<string> => this.pickDownloadTarget(name);
    this.payloadController.requestWritePermission = (fileName: string): Promise<boolean> => this.ensureWritePermission(fileName);
    this.payloadController.persistHistory = (history: PayloadTransfer[]): Promise<void> => this.persistPayloadHistory(history);
    this.payloadController.clearPersistedHistory = (): Promise<void> => this.clearPayloadHistory();
    this.payloadController.connectedDeviceIds = (): string[] => this.deviceController.connectedDevices.map((d: DeviceItem) => d.id);
    // 阶段 3 批次 3 装配：SettingsController + PluginEventHandlers 注入
    this.settingsController.log = (m: string): void => { this.notify.log(m); };
    this.settingsController.persistEntries = (entries: SettingEntry[]): Promise<void> => this.persistSettings(entries);
    this.settingsController.applyColorMode = (mode: number): void => {
      try {
        const hostCtx: Context | undefined = this.getUIContext().getHostContext();
        if (hostCtx !== undefined) {
          hostCtx.getApplicationContext().setColorMode(colorModeOf(mode));
        }
      } catch (e) {
        this.notify.log('setColorMode failed: ' + (e instanceof Error ? e.message : 'unknown'));
      }
    };
    this.settingsController.applyLang = (lang: string): void => {
      try {
        const hostCtx: Context | undefined = this.getUIContext().getHostContext();
        if (hostCtx !== undefined) {
          hostCtx.getApplicationContext().setLanguage(languageOf(lang));
        }
      } catch (e) {
        this.notify.log('setLanguage failed: ' + (e instanceof Error ? e.message : 'unknown'));
      }
    };
    this.settingsController.restartNative = (): void => {
      try {
        native.stop();
      } catch (e) {
      }
      this.startNative();
    };
    this.pluginHandlers.log = (m: string): void => { this.notify.log(m); };
    this.pluginHandlers.toast = (m: string): void => { this.notify.toast(m); };
    this.pluginHandlers.resText = (resId: number): string => this.notify.resText(resId);
    this.pluginHandlers.commandsOf = (deviceId: string): RunCommandEntry[] => this.commandsOf(deviceId);
    this.pluginHandlers.setRunCommandState = (deviceId: string, commands: RunCommandEntry[]): void => {
      this.runCommandDeviceId = deviceId;
      this.runCommands = commands;
    };
    this.pluginHandlers.setBatteryItems = (items: BatteryItem[]): void => { this.batteryItems = items; };
    this.pluginHandlers.getBatteryItems = (): BatteryItem[] => this.batteryItems;
    // 阶段 3 批次 4 装配：DeviceController 注入
    this.deviceController.log = (m: string): void => { this.notify.log(m); };
    this.deviceController.showNotice = (kind: string, detail: string, isError: boolean, code: number): void => {
      this.notify.showNotice(kind, detail, isError);
    };
    this.deviceController.toast = (m: string): void => { this.notify.toast(m); };
    this.deviceController.sendPacket = (deviceId: string, json: string): boolean => {
      try {
        return native.sendPacket(deviceId, json);
      } catch (e) {
        return false;
      }
    };
    this.deviceController.getPairVerificationCode = (deviceId: string, timestamp: number): string => {
      try {
        return native.getPairVerificationCode(deviceId, timestamp);
      } catch (e) {
        return '';
      }
    };
    this.deviceController.getPeerCertificate = (deviceId: string): string => {
      try {
        return native.getPeerCertificate(deviceId);
      } catch (e) {
        return '';
      }
    };
    this.deviceController.setTrustedCertificate = (deviceId: string, certPem: string): void => {
      try {
        native.setTrustedCertificate(deviceId, certPem);
      } catch (e) {
      }
    };
    this.deviceController.removeTrustedCertificate = (deviceId: string): void => {
      try {
        native.removeTrustedCertificate(deviceId);
      } catch (e) {
      }
    };
    this.deviceController.openPairPrompt = (deviceId: string, deviceName: string, timestamp: number, code: string): void => {
      this.pairSession.openPrompt(deviceId, deviceName, timestamp, code);
    };
    this.deviceController.connectToPeer = (host: string, port: number): void => {
      try {
        native.connectToPeer(host, port);
      } catch (e) {
      }
    };
    this.deviceController.triggerBroadcast = (): void => { this.triggerDiscoveryBroadcast(); };
    this.deviceController.getHostContext = (): Context | undefined => this.getUIContext().getHostContext();
    this.deviceController.routerOnPacket = (deviceId: string, raw: string): void => {
      if (this.router !== undefined) {
        this.router.onPacket(deviceId, raw);
      }
    };
    this.deviceController.routerForgetPeer = (deviceId: string): void => {
      if (this.router !== undefined) {
        this.router.forgetPeer(deviceId);
      }
    };
    // 插件装载兜底（保真原始行为，见未接线副本 connected 分支）：caps 不可知 ⇒ 按「全支持」装载（空 caps）；
    // 真 caps 由 RouterCallbacks.onPeerCapabilities 走 loadPlugins(id, incoming, outgoing) 装载。
    this.deviceController.loadPluginsIfEmpty = (deviceId: string): void => {
      if (this.pluginHost !== undefined && this.pluginHost.pluginsFor(deviceId).length === 0) {
        this.loadPlugins(deviceId, [], []);
        this.notify.log(`plugins loaded for ${deviceId} with unknown caps (fallback)`);
      }
    };
    this.deviceController.onDisconnectedCleanup = (deviceId: string): void => {
      this.payloadController.failInflightReceives(deviceId, 'disconnected');
      this.batteryItems = this.batteryItems.filter((b: BatteryItem) => b.deviceId !== deviceId);
      if (this.pluginHost !== undefined) {
        this.pluginHost.unloadForDevice(deviceId);
      }
      this.mprisController.forget(deviceId);
      this.payloadController.forgetSendQueue(deviceId);
    };
    this.deviceController.onDeviceLostCleanup = (deviceId: string): void => {
      this.mprisController.forget(deviceId);
    };
    this.deviceController.onErrorCleanup = (deviceId: string, errorCode: number, errorMessage: string): void => {
      this.payloadController.failInflightReceives(deviceId, `error ${errorCode}`);
    };
    this.deviceController.onPayloadTransfer = (event: NetEvent): void => { this.payloadController.handlePayloadTransfer(event); };
    this.deviceController.pairSessionOnConnected = (deviceId: string, shownName: string): void => {
      if (this.pairSession.stage === 'connecting' && this.pairSession.deviceId === deviceId) {
        this.notify.showNotice('connected', shownName, false);
      }
      this.pairSession.onConnected(deviceId);
    };
    this.deviceController.pairSessionOnDisconnected = (deviceId: string): void => {
      this.pairSession.onDisconnected(deviceId);
    };
    this.deviceController.pairSessionOnError = (deviceId: string, code: number, msg: string): void => {
      this.pairSession.onError(deviceId, code, msg);
    };
    this.deviceController.actionGate = (key: string, windowMs: number): boolean => this.actionGate(key, windowMs);
    this.deviceController.getDeviceName = (): string => this.settingsController.deviceName;
    // 阶段 3 批次 4 装配：DeviceActionController 注入
    this.actionController.log = (m: string): void => { this.notify.log(m); };
    this.actionController.toast = (m: string): void => { this.notify.toast(m); };
    this.actionController.resText = (resId: number): string => this.notify.resText(resId);
    this.actionController.actionGate = (key: string, windowMs: number): boolean => this.actionGate(key, windowMs);
    this.actionController.pluginsFor = (deviceId: string): PluginBase[] =>
      this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(deviceId);
    this.actionController.commandsOf = (deviceId: string): RunCommandEntry[] => this.commandsOf(deviceId);
    this.actionController.switchTab = (index: number): void => { this.switchTab(index); };
    this.actionController.getSelectedDeviceId = (): string => this.deviceController.selectedDeviceId;
    this.actionController.getConnectedDevices = (): DeviceItem[] => this.deviceController.connectedDevices;
    this.actionController.getDeviceName = (): string => this.settingsController.deviceName;
    this.actionController.setCardBusy = (key: string): void => {
      this.cardBusyKey = key;
      if (this.cardBusyTimer >= 0) {
        clearTimeout(this.cardBusyTimer);
      }
      this.cardBusyTimer = setTimeout((): void => {
        this.cardBusyTimer = -1;
        this.releaseCard(key, 'timeout');
      }, 5000);
    };
    this.actionController.clearCardBusy = (key: string): void => { this.releaseCard(key, 'event'); };
    this.actionController.setRunCommandState = (deviceId: string, commands: RunCommandEntry[], open: boolean): void => {
      this.runCommandDeviceId = deviceId;
      this.runCommands = commands;
      this.runCommandDialogOpen = open;
    };
    this.actionController.openMprisDialog = (deviceId: string): void => {
      const mp: MprisPlugin | undefined = this.mprisController.mprisPluginOf(deviceId);
      if (mp === undefined) {
        return;
      }
      this.mprisController.deviceId = deviceId;
      this.mprisController.put(mp.item());
      this.mprisController.dialogOpen = true;
      this.mprisController.tab = 0;
      this.mprisController.svPrepare();
    };
    this.actionController.pairSessionStart = (deviceId: string, label: string, host: string, port: number): void => {
      this.pairSession.start(deviceId, label, host, port);
    };
    this.actionController.getHostContext = (): Context | undefined => this.getUIContext().getHostContext();
    this.actionController.payloadEnqueueSend = (jobs: SendJob[], targetId: string): void => {
      this.payloadController.enqueueSendJobs(jobs, targetId);
    };
    this.actionController.setSelectedDeviceId = (id: string): void => { this.deviceController.selectedDeviceId = id; };
    this.actionController.setDeviceSection = (section: number): void => { this.deviceController.deviceSection = section; };
    this.actionController.pruneActionGate = (): void => { this.pruneActionGate(); };
    this.actionController.getMprisPluginOf = (deviceId: string): MprisPlugin | undefined => this.mprisController.mprisPluginOf(deviceId);
    this.actionController.getRunCommandDeviceId = (): string => this.runCommandDeviceId;
    // 装配自检：注册数与清单一致（7）。**同时写 hilog**（页面 log() 只进 app 内 LogStore，机器不可见）
    // ⇒ 漏注册/多注册可在 `hdc shell hilog` 里直接机检（devdocs/PLUGIN_ROUTE_INVENTORY.md §5）。
    const routeCount: number = this.eventBus.kinds().length;
    this.notify.log(`plugin routes registered: ${routeCount}`);
    hilog.info(0x0001, 'KDEConnectUI', 'plugin routes registered: %{public}d', routeCount);
    this.startNative();
    this.netWatcher.register();
  }

  // 页面显示后应用主题/语言（setColorMode/setLanguage 要求页面已加载完成）。
  // 必须同时等 Preferences 读取完成，二者任一先到都触发检查，避免用默认值覆盖用户设置。
  onPageShow(): void {
    this.pageShown = true;
    this.applySettingsIfReady();
    // 回前台/首次进入时主动广播一次：对端广播间隔较长，若启动时刚好错过上一轮，
    // 设备页会长时间空着（用户 2026-09-16 反馈「列表里什么都没有」）。
    // 有 3s 门控（actionGate 'net:triggerBroadcast'），不会放大主线程负担。
    this.triggerDiscoveryBroadcast();
  }

  // 点击/发包限频：同一「设备:动作」在窗口内重复触发直接忽略。
  // 用途：卡片连点、ping/查找设备/剪贴板索取这类会真的发网络请求的动作别被连点刷爆。
  // JS→native 同步调用的耗时探针（>100ms 才打 hilog）：
  // 目的 = 把「主线程被 native 卡住」钉到具体调用上（如 triggerBroadcast / start / setCapabilities）。
  private probeNative(name: string, fn: () => void): void {
    const t0: number = Date.now();
    try {
      fn();
    } finally {
      const dt: number = Date.now() - t0;
      if (dt > 100) {
        console.warn(`KDC slow native ${name}: ${dt}ms`);
      }
    }
  }

  private actionGate(key: string, windowMs: number): boolean {
    const now: number = Date.now();
    const last: number | undefined = this.actionGateMs.get(key);
    if (last !== undefined && now - last < windowMs) {
      // 同时打到 hilog（app 自身日志只在页面里，排查连点时看不到）
      console.info(`KDC throttled: ${key} (${now - last}ms < ${windowMs}ms)`);
      return false;
    }
    this.actionGateMs.set(key, now);
    // P2-1② 兜底：条目异常膨胀时整体清空（限频窗最长 3s ⇒ 清空无正确性风险）
    if (this.actionGateMs.size > 64) {
      this.actionGateMs.clear();
    }
    return true;
  }

  private applySettingsIfReady(): void {
    if (!this.pageShown || !this.settingsLoaded || this.settingsApplied) {
      return;
    }
    this.settingsApplied = true;
    // ARKTS_ANALYSIS §8-B（根治）：主题/语言的切换会引发**全量重主题**（字体/颜色/资源重解析）。
    // 启动时它紧跟首帧之后（实测 +1.23s）执行，会与 native 的建链首批发包叠在同一时间窗内。
    // 延后一拍（首帧后再 300ms）执行，把这段开销从"首屏可交互前的窗口"里挪出去。
    setTimeout((): void => {
      this.settingsController.applyTheme(this.settingsController.themeMode, false);
      this.settingsController.applyLanguage(this.settingsController.language, false);
    }, 300);
  }

  aboutToDisappear(): void {
    this.netWatcher.unregister();
    try {
      native.stop();
    } catch (e) {
      // ignore
    }
  }

  // 屏幕宽度 → vp，按 600vp 断点区分手机/平板布局
  private detectScreenWidth(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const vpWidth: number = this.getUIContext().px2vp(d.width);
      const vpHeight: number = this.getUIContext().px2vp(d.height);
      this.isWide = vpWidth >= 600;
      this.isLandscape = vpWidth > vpHeight;
      this.sideBySide = this.isWide && this.isLandscape;
    } catch (e) {
      this.isWide = false;
      this.isLandscape = false;
      this.sideBySide = false;
    }
  }

  // 根容器尺寸变化（含旋屏）→ 重算宽屏/横屏判定，布局随之切换
  private onRootArea(area: Area): void {
    const w: number = Number(area.width);
    const h: number = Number(area.height);
    if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
      return;
    }
    const wide: boolean = w >= 600;
    const land: boolean = w > h;
    const side: boolean = wide && land;
    if (wide !== this.isWide) {
      this.isWide = wide;
    }
    if (land !== this.isLandscape) {
      this.isLandscape = land;
    }
    if (side !== this.sideBySide) {
      this.sideBySide = side;
    }
  }

  // 设备类型动态化（MSG117 §4）：UDP 广播/TCP identity 的 deviceType 决定对端图标与筛选，
  // 原先恒为 'phone' ⇒ 平板在桌面端显示成手机。@ohos.deviceInfo.deviceType 取值
  // phone / tablet / tv / wearable / 2in1 …；KDE 认 phone/tablet/desktop/laptop/tv/wearable，
  // 故只做必要映射，未知一律 phone。
  private peerDeviceType(): string {
    const t: string = deviceInfo.deviceType;
    if (t === 'tablet' || t === 'tv' || t === 'wearable') {
      return t;
    }
    if (t === '2in1' || t === 'pc' || t === 'desktop') {
      return 'desktop';
    }
    return 'phone';
  }

  private startNative(): void {
    try {
      const cfg: NetConfig = {
        deviceId: this.deviceId,
        deviceName: this.settingsController.deviceName,
        deviceType: this.peerDeviceType(),
        certPem: this.certPem,
        keyPem: this.keyPem,
        tcpPort: 0
      };
      // M1 能力协商（单一来源）：核心包（identity/pair）由本层处理，其余由插件注册表汇总；
      // 按 ZCode 建议在 start() 之前设置。native 未导出该符号时 try/catch 兜底。
      try {
        const incoming: string[] = ['kdeconnect.identity', 'kdeconnect.pair']
          .concat(this.pluginRegistry.incomingCapabilities());
        const outgoing: string[] = ['kdeconnect.identity', 'kdeconnect.pair']
          .concat(this.pluginRegistry.outgoingCapabilities());
        this.probeNative('setCapabilities', (): void => {
          native.setCapabilities(incoming, outgoing);
        });
        this.notify.log(`caps: in=${incoming.length} out=${outgoing.length}`);
      } catch (e) {
        this.notify.log('setCapabilities unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      }
      // MSG136 §2 F1：native.start 现在返回 boolean（omp 已让 JsStart 回传 ok）。
      // 旧代码不消费返回值、无条件置 running ⇒ 端口冲突 / UDP bind 失败时 UI 仍显示「运行中」，
      // 用户根本看不到失败。返回 false 时置失败态并记日志（原因见日志：port conflict / UDP bind failure）。
      let started: boolean = false;
      this.probeNative('start', (): void => {
        started = native.start(cfg);
      });
      if (!started) {
        this.status = 'start failed';
        this.notify.log('native.start returned false (port conflict or UDP bind failure)');
        return;
      }
      this.status = 'running';
    } catch (e) {
      this.status = 'start failed: ' + (e instanceof Error ? e.message : 'unknown');
    }
  }

  private async persistSettings(entries: SettingEntry[]): Promise<void> {
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      const pref = await preferences.getPreferences(hostCtx, 'kdeconnect');
      for (const entry of entries) {
        await pref.put(entry.key, entry.value);
      }
      await pref.flush();
    } catch (e) {
      this.notify.log('persist settings failed');
    }
  }

  private useSystemDeviceName(): void {
    const name: string = systemDeviceName(this.getUIContext().getHostContext());
    this.systemName = name;
    this.notify.log(`use system device name: ${name}`);
    this.settingsController.renameDevice(name);
  }


  // 触发一次 UDP identity 广播（native 未导出该符号时静默降级，不写屏幕日志）
  private triggerDiscoveryBroadcast(): void {
    try {
      this.probeNative('triggerBroadcast', (): void => {
        native.triggerBroadcast();
      });
    } catch (e) {
      this.notify.log('triggerBroadcast unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // AP-4：对端 identity → 按能力交集装载插件（每设备一份实例）
  private loadPlugins(deviceId: string, incoming: string[], outgoing: string[]): void {
    if (this.pluginHost === undefined) {
      return;
    }
    this.pluginHost.loadForDevice(deviceId, incoming, outgoing,
      (dev: string, json: string): boolean => native.sendPacket(dev, json),
      (dev: string, ev: PluginEvent): void => {
        this.onPluginEvent(dev, ev);
      });
  }

  // 插件 → UI 事件（电量 / 远程命令 / 剪贴板索取等）
  // 批1 根治（CodeArts MSG16 授权）：插件事件改为**类型化对象**，不再 JSON.stringify/parse。
  // 结构化数据（MPRIS 列表/快照）直接读字段；标量事件读 ev.text（语义与旧 data 字符串一致）。
  /**
   * 插件事件**唯一入口**（阶段 2 步骤 4）：退化为一次路由分发。
   * 各 kind 的处理器在装配期注册（见 aboutToAppear/initPluginRoutes）；未注册 kind 走 bus 兜底（只记日志，绝不静默丢弃）。
   * 路由清单与不变量见 devdocs/PLUGIN_ROUTE_INVENTORY.md。
   */
  private onPluginEvent(deviceId: string, ev: PluginEvent): void {
    this.eventBus.dispatch(deviceId, ev);
  }

  // 媒体控制（方向 1）：类型化对象直读，省掉每事件一次 stringify+parse
  private onMprisPlayerList(deviceId: string, ev: PluginEvent): void {
    this.mprisController.setList(deviceId, ev.mprisList ?? []);
  }

  private onMprisPlayerUpdate(deviceId: string, ev: PluginEvent): void {
    const snap: MprisSnapshot | undefined = ev.mprisSnap;
    if (snap !== undefined) {
      this.mprisController.setSnapshot(deviceId, snap);
    }
  }

  // 系统音量（kdeconnect.systemvolume）：插件推整份行数组（已换算成百分比），UI 只渲染。
  // 单槽过滤（用户 2026-09-19 裁决）：面板一次只服务一台设备。
  private onSystemVolumeSinks(deviceId: string, ev: PluginEvent): void {
    if (deviceId !== this.mprisController.deviceId) {
      return;
    }
    this.mprisController.svSinks = ev.svSinks !== undefined ? ev.svSinks : [];
    this.mprisController.svDeviceId = deviceId;
  }

  // 取某设备已收到的预设命令列表（命令由 RunCommandPlugin 实例持有）
  private commandsOf(deviceId: string): RunCommandEntry[] {
    const list: PluginBase[] = this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(deviceId);
    for (const p of list) {
      if (p instanceof RunCommandPlugin) {
        return p.commandList();
      }
    }
    return [];
  }

  // AP-4：非核心 packet 分发到插件（返回 true 表示已处理）
  private dispatchPluginPacket(deviceId: string, packetType: string, body: Object): boolean {
    if (this.pluginHost === undefined) {
      return false;
    }
    return this.pluginHost.dispatch(deviceId, packetType, body);
  }









  // ---- 连接/配对会话 ----


  // 失败码（上线口径：提示只给错误码，明细进日志）




  private releaseCard(key: string, by: string): void {
    if (this.cardBusyKey !== key) {
      return;
    }
    this.cardBusyKey = '';
    if (this.cardBusyTimer >= 0) {
      clearTimeout(this.cardBusyTimer);
      this.cardBusyTimer = -1;
    }
    console.info(`KDC card released: ${key} (fired by ${by})`);
  }



  // 切底栏页签（HdsTabs 控制器）；失败只记日志，不阻塞
  private switchTab(index: number): void {
    this.currentTab = index;
    try {
      this.tabsController.changeIndex(index);
      this.notify.log(`switch tab -> ${index}`);
    } catch (e) {
      this.notify.log('changeIndex failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }



  // ========== 页面辅助方法（供 PayloadController 注入回调使用） ==========

  private ensureKdcDir(): string {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return '';
    }
    const dir: string = hostCtx.filesDir + '/kdeconnect';
    try {
      fileIo.mkdirSync(dir);
    } catch (e) {
    }
    return dir;
  }

  private async pickSaveTarget(name: string): Promise<string> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return '';
    }
    try {
      const pk: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const uris: string[] = await pk.save({ newFileNames: [name] });
      return uris.length > 0 ? uris[0] : '';
    } catch (e) {
      this.notify.log('save as: picker failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    }
  }

  private async pickDownloadTarget(name: string): Promise<string> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return '';
    }
    try {
      const pk: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const opts: picker.DocumentSaveOptions = {
        newFileNames: [name],
        pickerMode: picker.DocumentPickerMode.DOWNLOAD
      };
      const uris: string[] = await pk.save(opts);
      return uris.length > 0 ? uris[0] : '';
    } catch (e) {
      this.notify.log('export: save picker(DOWNLOAD) failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    }
  }

  private async ensureWritePermission(fileName: string): Promise<boolean> {
    const lower: string = fileName.toLowerCase();
    const imageVideo: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.mp4', '.mov', '.mkv', '.webm', '.3gp'];
    const audio: string[] = ['.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.opus', '.amr'];
    let permName: string = '';
    for (const ext of imageVideo) {
      if (lower.endsWith(ext)) {
        permName = 'ohos.permission.WRITE_IMAGEVIDEO';
        break;
      }
    }
    if (permName === '') {
      for (const ext of audio) {
        if (lower.endsWith(ext)) {
          permName = 'ohos.permission.WRITE_AUDIO';
          break;
        }
      }
    }
    if (permName === '') {
      return true;
    }
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return true;
      }
      const perms: Permissions[] = permName === 'ohos.permission.WRITE_IMAGEVIDEO'
        ? ['ohos.permission.WRITE_IMAGEVIDEO']
        : ['ohos.permission.WRITE_AUDIO'];
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(hostCtx, perms);
      const codes: number[] = result.authResults;
      const granted: boolean = codes.length > 0 && codes[0] === 0;
      this.notify.log(`permission ${permName}: granted=${granted}`);
      return granted;
    } catch (e) {
      this.notify.log('permission request failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return true;
    }
  }

  private async persistPayloadHistory(history: PayloadTransfer[]): Promise<void> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      PayloadHistory.save(hostCtx, history).catch((e: Error): void => {
        this.notify.log('payload history save failed: ' + e.message);
      });
    }
  }

  private async clearPayloadHistory(): Promise<void> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      PayloadHistory.clear(hostCtx).catch((e: Error): void => {
        this.notify.log('payload history clear failed: ' + e.message);
      });
    }
  }




  // P2（MSG145 §2 P2-1）：actionGateMs 只增不减 ⇒ 随「设备 × 动作」缓慢泄漏。
  // ①选择设备时清过期键（限频窗最长 3s，删 5s 前的键无语义风险）；②另有 64 条兜底上限。
  private pruneActionGate(): void {
    const now: number = Date.now();
    const stale: string[] = [];
    this.actionGateMs.forEach((t: number, k: string): void => {
      if (now - t > 5000) {
        stale.push(k);
      }
    });
    for (const k of stale) {
      this.actionGateMs.delete(k);
    }
  }

  // 沉浸光感能力探测（仅记录）。底栏材质由 HdsTabs 的 barFloatingStyle.systemMaterialEffect
  // 提供（官方推荐、自动按设备算力自适应）；卡片等非 TabBar 区域不在生效范围，走毛玻璃。
  private initImmersiveMaterial(): void {
    try {
      this.immersiveSupported = uiMaterial.isImmersiveMaterialSupported();
      console.info('KDC uiMaterial supported=' + this.immersiveSupported);
    } catch (e) {
      this.immersiveSupported = false;
      console.warn('KDC immersive material unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // 底栏图标：名字全部取自 SDK 的 sys.symbol 资源表
  // （`ets-loader/sysResource.js` 的 symbol 段，已逐个核对存在，勿凭记忆猜名字）
  private tabIcon(index: number): Resource {
    if (index === 0) {
      return $r('sys.symbol.house');
    }
    if (index === 1) {
      return $r('sys.symbol.folder');
    }
    if (index === 2) {
      return $r('sys.symbol.gearshape');
    }
    return $r('sys.symbol.text_alignleft');
  }

  // 底栏图标修饰器：显式给字号 —— 本 SDK（API 26）的 BottomTabBarStyle 在 modifier 不带字号时，
  // 个别符号（如 gearshape/text_alignleft）会按自身 intrinsic 尺寸绘制，观感偏大且与胶囊不齐。
  private tabIconModifier(index: number): SymbolGlyphModifier {
    return new SymbolGlyphModifier(this.tabIcon(index)).fontSize(24);
  }

  // 底部页签不再自绘：改用官方 BottomTabBarStyle.of(符号图标, 文案)（对齐参考实现 ohtotptoken），
  // 由 HdsTabs 渲染「图标在上、文字在下」的标准胶囊项；选中态高亮交给系统样式，
  // 避免自绘时 selected 态与沉浸光感材质叠出两套高亮。
  // 各 Tab 的图标仍取本工程的 tabIcon(index)。

  // 汉堡按钮（三条横线自绘，不依赖资源）：放在标题旁边（对齐参考稿）
  @Builder
  menuButton() {
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
      this.openDrawer();
    })
  }

  // ---- 手机侧栏抽屉（全屏渲染；iOS 观感：面板左贴边滑入 + 背景浅色变暗淡入） ----

  private openDrawer(): void {
    animateTo({ duration: 280, curve: Curve.EaseOut }, () => {
      this.drawerOpen = true;
    });
  }

  private closeDrawer(): void {
    animateTo({ duration: 220, curve: Curve.EaseIn }, () => {
      this.drawerOpen = false;
    });
  }

  private pickDrawerSection(index: number): void {
    this.deviceController.deviceSection = index;
    this.closeDrawer();
  }








  @Builder
  drawerOverlay() {
    // 合并裁定 #13：设备抽屉抽为 DrawerOverlay 组件（来自 AtomCode 副本）——
    // 页面只传派生列表与回调，UI/交互细节收敛到组件内。
    DrawerOverlay({
      connectedList: this.deviceController.connectedShown(),
      discoveredList: this.deviceController.discoveredShown(),
      rememberedCount: this.deviceController.offlineKnownShown().length,
      selectedDeviceId: this.deviceController.selectedDeviceId,
      requestedPairIds: this.pairSession.requestedPeers,
      deviceSection: this.deviceController.deviceSection,
      drawerExpanded: this.drawerExpanded,
      onClose: (): void => {
        this.closeDrawer();
      },
      onOpenDevice: (d: DeviceItem): void => {
        this.actionController.openDeviceDetail(d);
        this.closeDrawer();
      },
      onPairRequest: (d: DeviceItem): void => {
        this.deviceController.requestPairWith(d);
        this.closeDrawer();
      },
      onPickSection: (index: number): void => {
        this.pickDrawerSection(index);
      },
      isPaired: (deviceId: string): boolean => {
        return this.deviceController.isPairedId(deviceId);
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景层：渐变 + 两团柔光（光感基底，卡片在其上做磨砂/材质）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [[$r('app.color.bg_grad_top'), 0.0], [$r('app.color.bg_grad_mid'), 0.5],
            [$r('app.color.bg_grad_bottom'), 1.0]]
        })
      Column()
        .width(420)
        .height(420)
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          colors: [[$r('app.color.glow_primary'), 0.0], ['rgba(56, 189, 248, 0.0)', 1.0]]
        })
        .position({ x: '60%', y: -90 })
      Column()
        .width(380)
        .height(380)
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          colors: [[$r('app.color.glow_secondary'), 0.0], ['rgba(129, 140, 248, 0.0)', 1.0]]
        })
        .position({ x: -110, y: '76%' })

      // 内容层：标题 + 状态条 → Tab 内容 → 底部悬浮栏
      Column() {
        // 标题区（对齐参考稿：汉堡按钮紧挨标题左侧）
        Row({ space: 10 }) {
          // 横屏平板用常驻侧栏，不再需要抽屉汉堡；竖屏一律汉堡拉抽屉
          if (!this.sideBySide) {
            this.menuButton()
          }
          Text('KDE Connect')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('HarmonyOS')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(999)
            .border({ width: 1, color: $r('app.color.card_border') })
            .backgroundColor($r('app.color.chip_bg'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: this.getUIContext().px2vp(this.statusBarHeightPx) + 14 })

        // 状态条（单行）
        Row({ space: 10 }) {
          Circle({ width: 10, height: 10 })
            .fill(this.status.startsWith('running') ? $r('app.color.dot_connected') : $r('app.color.danger_text'))
          Text(this.status.startsWith('running') ? $r('app.string.status_running') : this.status)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.deviceId)
            .fontSize(11)
            .fontColor($r('app.color.text_muted'))
            .fontFamily('monospace')
            .maxLines(1)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius(18)
        .backgroundBlurStyle(undefined)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1, color: $r('app.color.card_border') })

        // 内容区 + 底部页签：HdsTabs 悬浮胶囊（官方最佳实践 bpta-spatiality-immersive）
        // barOverlap(true) 使页签悬浮于内容之上，barFloatingStyle 提供悬浮胶囊 +
        // 渐变遮罩 + systemMaterialEffect 沉浸光感（材质等级自适应设备算力）。
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            Column() {
              DevicesTab({
                // 三态互斥派生列表（见 connectedShown/discoveredShown/offlineKnownShown）
                connectedDevices: this.deviceController.connectedShown(),
                discoveredDevices: this.deviceController.discoveredShown(),
                rememberedDevices: this.deviceController.offlineKnownShown(),
                rememberedAll: this.deviceController.rememberedDevices,
                immersive: this.immersiveSupported,
                sideBySide: this.sideBySide,
                requestedPairIds: this.pairSession.requestedPeers,
                batteryItems: this.batteryItems,
                controller: this.deviceController,
                onUnpairDevice: (d: DeviceItem): void => {
                  this.deviceController.unpairDevice(d);
                },
                onManualConnect: (host: string, port: number): void => {
                  this.actionController.manualConnect(host, port);
                },
                selectedDeviceId: this.deviceController.selectedDeviceId,
                onPlaceholderAction: (key: string): void => {
                  // 走卡片忙碌态入口（【补丁·待优化】，视觉无变化）
                  this.actionController.runCardAction(key);
                },
                // 发送文件卡内按钮 = 文件页「选择文件并发送」同一动作
                onSendFilePick: (): void => {
                  this.actionController.pickAndSendFile();
                },
                onOpenDevice: (d: DeviceItem): void => {
                  this.actionController.openDeviceDetail(d);
                },
                onClipboardPaste: (granted: boolean): void => {
                  this.actionController.onClipboardPasteResult(granted);
                },
                onClipboardRequest: (): void => {
                  this.actionController.onDeviceAction('clipboard_request');
                },
                onRefreshDiscovery: (): void => {
                  this.triggerDiscoveryBroadcast();
                },
                onPairDevice: (d: DeviceItem): void => {
                  this.deviceController.requestPairWith(d);
                }
              })
            }
            .width('100%')
            .height('100%')
            .padding({ top: 12, bottom: 108 })
          }
          .tabBar(BottomTabBarStyle.of(
            {
              normal: this.tabIconModifier(0),
              selected: this.tabIconModifier(0)
            },
            this.tabs[0].label)
            .verticalAlign(VerticalAlign.Center))

          TabContent() {
            Column() {
              FilesTab({
                    connectedCount: this.deviceController.connectedDevices.length,
                    immersive: this.immersiveSupported,
                    payloads: this.payloadController.payloads,
                    onSavePayload: (p: PayloadTransfer): void => {
                      this.payloadController.savePayload(p);
                    },
                    onDiscardPayload: (p: PayloadTransfer): void => {
                      this.payloadController.discardPayload(p);
                    },
                    onCancelPayload: (p: PayloadTransfer): void => {
                      this.payloadController.cancelPayload(p);
                    },
                    onSendFile: (): void => {
                      this.actionController.pickAndSendFile();
                    },
                    onOpenReceivedFiles: (): void => {
                      this.payloadController.dialogOpen = true;
                    },
                    onOpenPayload: (tid: number): void => {
                      this.payloadController.detailId = tid;
                      this.payloadController.detailOpen = true;
                    }
                  })
            }
            .padding({ top: 12, bottom: 108 })
          }
          .tabBar(BottomTabBarStyle.of(
            {
              normal: this.tabIconModifier(1),
              selected: this.tabIconModifier(1)
            },
            this.tabs[1].label)
            .verticalAlign(VerticalAlign.Center))

          TabContent() {
            Column() {
              SettingsTab({
                deviceId: this.deviceId,
                deviceName: this.settingsController.deviceName,
                systemName: this.systemName,
                statusText: this.status,
                themeMode: this.settingsController.themeMode,
                language: this.settingsController.language,
                immersive: this.immersiveSupported,
                onRenameDevice: (name: string): void => {
                  this.settingsController.renameDevice(name);
                },
                onUseSystemName: (): void => {
                  this.useSystemDeviceName();
                },
                onThemeChange: (mode: number): void => {
                  this.settingsController.applyTheme(mode, true);
                },
                onLanguageChange: (lang: string): void => {
                  this.settingsController.applyLanguage(lang, true);
                }
              })
            }
            .padding({ top: 12, bottom: 108 })
          }
          .tabBar(BottomTabBarStyle.of(
            {
              normal: this.tabIconModifier(2),
              selected: this.tabIconModifier(2)
            },
            this.tabs[2].label)
            .verticalAlign(VerticalAlign.Center))

          TabContent() {
            Column() {
                LogsTab({
                  logStore: this.notify.logStore,
                  immersive: this.immersiveSupported
                })
            }
            .padding({ top: 12, bottom: 108 })
          }
          .tabBar(BottomTabBarStyle.of(
            {
              normal: this.tabIconModifier(3),
              selected: this.tabIconModifier(3)
            },
            this.tabs[3].label)
            .verticalAlign(VerticalAlign.Center))
        }
        .barPosition(BarPosition.End)
        .vertical(false)
        .barOverlap(true)
        // 以下一组对齐参考实现（ohtotptoken）：blur 底栏 + 固定模式 + 300ms 切换动画
        .barMode(BarMode.Fixed)
        .barBackgroundBlurStyle(BlurStyle.Regular)
        .animationDuration(300)
        // TabBar 自身背景置透明：否则暗色下会在材质层下压出一块深灰底
        .barBackgroundColor(Color.Transparent)
        .barFloatingStyle({
          // 离底边距离：参考稿是固定 28vp；本工程保留「设备导航条高度 + 28」的自适应写法——
          // 平板实测 navBarHeightPx 常为 0，纯固定值会让胶囊贴边（用户 2026-09-15 反馈）。
          barBottomMargin: this.getUIContext().px2vp(this.navBarHeightPx) + 28,
          // 显式给全透明遮罩：覆盖 HdsTabs 默认的底部渐隐（暗色下会呈一条渐黑带）
          gradientMask: { maskColor: '#00000000', maskHeight: 96 },
          // 沉浸光感材质：2026-09-16 做过「关掉它」的对照实验，确认与主线程卡顿无关，
          // 按用户要求恢复（关掉时胶囊观感变平，用户明确要还原）。
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .layoutWeight(1)
        .width('100%')
        .onChange((index: number) => {
          this.currentTab = index;
          // 切回「设备」页签时主动广播一次（3s 门控内自动跳过），让列表尽快有内容
          if (index === 0) {
            this.triggerDiscoveryBroadcast();
          }
          // ARKTS_ANALYSIS §8-A：切到「日志」页签时补一次 flush（页面不可见期间日志只进缓冲、不写 @State）
          if (index === 3) {
            this.notify.flushLog();
          }
        })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      .onAreaChange((_old: Area, area: Area) => {
        this.onRootArea(area);
      })

      // 手机侧栏抽屉（全屏覆盖）：必须在根 Stack 渲染，否则被内容区 padding(16) 内缩
      if (this.drawerOpen) {
        this.drawerOverlay()
      }

      // 配对确认弹窗（需求 4.3）：本侧点已连接行「配对」或对端发起时都走这里；
      // 显示验证码，两端核对一致后确认 → 配对成功。
      // 阶段 3 批次 1 步骤 5a：UI 抽到 components/PairConfirmDialog.ets（纯 UI，状态仍全在 pairSession）。
      // ⚠️ 组件**自带全屏遮罩**，这里不要再包一层 Column/遮罩（否则双遮罩、要点两次才关）。
      if (this.pairSession.stage === 'prompt' || this.pairSession.stage === 'awaiting') {
        PairConfirmDialog({
          peerRequested: this.pairSession.peerRequested,
          peerName: this.pairSession.peerName,
          deviceId: this.pairSession.deviceId,
          // 设备 ID 在弹窗里核对（列表里只显示 IP:端口，用户 2026-09-14）；组件不依赖 Context ⇒ 页面算好传入
          deviceIdLabel: this.notify.resText($r('app.string.settings_device_id').id),
          code: this.pairSession.code,
          awaiting: this.pairSession.stage === 'awaiting',
          canConfirm: this.pairSession.stage === 'prompt',
          onConfirm: (): void => {
            this.pairSession.confirm();
          },
          onCancel: (): void => {
            this.pairSession.cancel();
          }
        })
      }

      // 媒体控制面板（阶段 3 批次 2 步骤 6a-2 ⇒ components/MprisDialog.ets）
      if (this.mprisController.dialogOpen) {
        MprisDialog({
          mpris: this.mprisController,
          deviceName: this.deviceController.displayNameOf(this.mprisController.deviceId)
        })
      }

      // 远程命令弹窗（P1，MSG112 §1）：展示对端下发的预设命令列表，点一条即请求执行。
      // 阶段 3 批次 1 步骤 5b：UI 抽到 components/RunCommandDialog.ets（页面的 runCommand() 仍留本页，
      // 它要经 PluginHost 发请求 + 释放卡片忙碌态）。⚠️ 组件自带遮罩，不要外再包一层。
      if (this.runCommandDialogOpen) {
        RunCommandDialog({
          deviceName: this.deviceController.displayNameOf(this.runCommandDeviceId),
          commands: this.runCommands,
          onPick: (key: string): void => {
            this.actionController.runCommand(key);
          },
          onClose: (): void => {
            this.runCommandDialogOpen = false;
          }
        })
      }

      // 「查看已接收」弹窗（阶段 3 批次 2 步骤 6b-2 ⇒ components/ReceivedFilesDialog.ets）
      if (this.payloadController.dialogOpen) {
        ReceivedFilesDialog({
          payload: this.payloadController
        })
      }

      if (this.payloadController.detailOpen) {
        PayloadDetailDialog({
          fileName: this.payloadController.payloadDetail().fileName.length > 0
            ? this.payloadController.payloadDetail().fileName : `#${this.payloadController.detailId}`,
          sizeText: this.payloadController.fmtBytes(this.payloadController.payloadDetail().size),
          timeText: this.payloadController.timeTextOf(this.payloadController.payloadDetail()),
          stateText: this.payloadController.payloadStateText(this.payloadController.payloadDetail()),
          dirText: this.notify.resText(this.payloadController.payloadDetail().direction === 'receive'
            ? $r('app.string.file_dir_receive').id : $r('app.string.file_dir_send').id),
          onSaveAs: (): void => {
            this.payloadController.saveAsPayload(this.payloadController.payloadDetail());
          },
          onDiscard: (): void => {
            this.payloadController.discardPayload(this.payloadController.payloadDetail());
            this.payloadController.detailOpen = false;
          },
          onClose: (): void => {
            this.payloadController.detailOpen = false;
          }
        })
      }

    }
    .width('100%')
    .height('100%')
    // 兜底底色：暗色下窗口默认背景为黑，若底部安全区未被渐变覆盖会露出一条黑带
    .backgroundColor($r('app.color.bg_grad_bottom'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
