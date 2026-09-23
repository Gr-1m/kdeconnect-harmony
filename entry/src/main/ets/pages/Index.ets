// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import native from 'libkdeconnect_napi.so';
import { NetConfig, CertPair, NetEvent } from 'libkdeconnect_napi.so';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { Context, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { display, SymbolGlyphModifier } from '@kit.ArkUI';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import deviceInfo from '@ohos.deviceInfo';
import { PacketRouter, RouterCallbacks } from '../net/PacketRouter';
import { PluginBase } from '../plugins/PluginBase';
import { PluginEvent, BatteryPayload, RunOutputPayload } from '../plugins/PluginEvent';
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
import { DeviceItem, RememberedDevice, BatteryItem } from '../model/DeviceModels';
import { MprisItem, MprisSnapshot, emptyMprisItem, mprisPlayerText } from '../model/MprisModels';
import { SystemSinkUi } from '../model/SystemVolumeModels';
import { PayloadTransfer, PayloadDirection, PayloadState } from '../model/PayloadModels';
import { TrustedDevice } from '../model/TrustModels';
import { TrustStore } from '../common/TrustStore';
import { PayloadHistory } from '../common/PayloadHistory';
import { PayloadDetailDialog } from '../components/PayloadDetailDialog';
import { LogStore } from '../common/LogStore';
import { colorModeOf, languageOf, LANG_SYSTEM, THEME_FOLLOW_SYSTEM, systemDeviceName } from '../common/AppSettings';
import { DevicesTab } from '../components/DevicesTab';
import { DrawerOverlay } from '../components/DrawerOverlay';
import { MprisProgress } from '../components/MprisProgress';
import { SystemSinkRow } from '../components/SystemSinkRow';
import { FilesTab } from '../components/FilesTab';
import { SettingsTab } from '../components/SettingsTab';
import { LogsTab } from '../components/LogsTab';
import { PairSession } from '../state/PairSession';
import { PluginEventBus } from '../state/PluginEventBus';

// timestamp 仅 pair 请求需要（KDE pair 响应体只含 {"pair": false}）
interface PairRequestBody {
  pair: boolean;
  timestamp?: number;
}

interface PairRequestPacket {
  id: number;
  type: string;
  body: PairRequestBody;
}

// 底部悬浮栏 Tab 定义（设备 / 文件 / 设置 / 日志[开发期]）
interface TabDef {
  label: ResourceStr;
}

// 设置项持久化条目（统一按字符串存 Preferences）
interface SettingEntry {
  key: string;
  value: string;
}

// 发送文件时的 share.request body
interface SendShareBody {
  filename: string;
}

const DEFAULT_DEVICE_NAME: string = 'kdeconnect-harmony';

// 连接/配对会话超时（毫秒）：TCP+TLS 建连 20s；配对请求等对端确认 45s
// （对端 KDE PairingHandler::pairingTimeoutMsec 也是 30s：本侧必须留更长，
//  否则用户还在点对端通知时本侧就先判失败。见 MSG65 §2）
const CONNECT_TIMEOUT_MS: number = 20000;
const PAIR_TIMEOUT_MS: number = 45000;
// 成功提示停留时间
const NOTICE_MS: number = 2500;
// 抽屉收起态最多显示的已连接设备数（超出才出现「展开 ⌄」）
const DRAWER_DEVICE_CAP: number = 2;
// 抽屉面板宽度上限（vp）：大屏上 78% 会撑成一条巨板，故夹住
const DRAWER_WIDTH_LIMIT: ConstraintSizeOptions = { maxWidth: 360 };
// 一次最多选几个文件发送（用户 2026-09-18 拍板改为多选；上限取值与系统文件选择器常见上限一致）
const MAX_PICK_FILES: number = 9;

// 多选发送的单个任务（文件已复制进沙箱，等队列轮到它）
interface SendJob {
  cachePath: string;
  fileName: string;
}

// 注（CodeArts MSG45 §1 授权清理）：`code=110` 有界重试已按裁定 #15 撤除，它遗留下的
// `SendJob.attempt` 字段与 `PAYLOAD_ERR_HANDSHAKE_TIMEOUT` / `MAX_SEND_ATTEMPT` 两个常量在此删除 ——
// 避免"注释引用已不存在的常量"。若将来要恢复重试，依据见 DevEco MSG38（待 native 阶段诊断数据定位）。

@Entry
@Component
struct Index {
  @State status: string = 'booting';
  // 日志状态（批3 #1）：收进 @Observed LogStore，由 LogsTab 以 @ObjectLink 绑定。
  // ⚠️ 这里**必须**挂 @State 才能传给 @ObjectLink（ArkTS 不允许 regular 属性绑定该装饰器）。
  // 但**改 store 的内部字段（text）不会重建页面** —— @Observed 只通知 @ObjectLink 订阅者（LogsTab），
  // 这正是本批要的收益：日志刷新只重建日志组件，页面其余部分不受影响。
  @State logStore: LogStore = new LogStore();
  @State currentTab: number = 0;
  // 日志合并刷新计数（非 @State，避免自身触发重建）：批3 后写日志不再重建页面，
  // 这个计数只代表 flush 次数（用于量化刷新频率），名字随语义改掉，别再叫 buildCount。
  private logFlushCount: number = 0;
  // 事件日志开关：true 时打印完整事件 JSON（排查用）；常态 false ⇒ 只打轻量摘要
  private debugEventLog: boolean = false;
  // 卡片忙碌态【补丁·待优化】（用户 2026-09-16 提案 / CodeArts MSG6-7 批准）：
  // 点击卡片后该卡片短期内不接受再次点击，等「弹窗已弹出」或「功能已执行」再恢复；
  // 5s 保险丝兜底（日志区分 fired by event / fired by timeout）。仅逻辑，不改视觉。
  @State cardBusyKey: string = '';
  private cardBusyTimer: number = -1;
  @State deviceName: string = DEFAULT_DEVICE_NAME;
  // 系统设备名称（只读展示 + 设置页「使用系统名称」）
  @State systemName: string = '';
  @State themeMode: number = THEME_FOLLOW_SYSTEM;
  @State language: string = LANG_SYSTEM;
  // 宽屏（平板/折叠展开）判定：>=600vp 走常驻侧栏，否则走抽屉式侧栏
  @State isWide: boolean = false;
  // 横屏判定（宽 > 高）
  @State isLandscape: boolean = false;
  // 并排侧栏模式：**仅横屏宽屏**（左侧栏常驻 30%）；竖屏（含平板竖屏）一律走汉堡 + 抽屉
  @State sideBySide: boolean = false;
  @State immersiveSupported: boolean = false;
  @State connectedDevices: DeviceItem[] = [];
  @State discoveredDevices: DeviceItem[] = [];
  @State rememberedDevices: RememberedDevice[] = [];
  // 连接/配对会话状态机（阶段 2 拆分 ⇒ state/PairSession.ets）：状态与副作用分离，本页只装配 + 转发 + 渲染。
  //   stage: connecting=连接中（**只有 toast，不弹模态**）；prompt=配对确认弹窗（两侧共用，显示验证码）；
  //          awaiting=已发配对帧，等对端确认
  // 副作用（发包/连对端/提示/日志/配对态收敛）全部经下面注入的回调走页面既有实现。
  @State pairSession: PairSession = new PairSession();
  // 插件事件路由表（阶段 2 步骤 4，state/PluginEventBus.ets）：本批先加字段，装配在下一步。
  private eventBus: PluginEventBus = new PluginEventBus();
  // 顶部临时提示（连接中/连接成功/连接失败/配对成功…）
  @State noticeKey: string = '';
  // 设备 Tab 分区（0 已连接 / 1 发现 / 2 记住 / 3 手动）：@Link 给 DevicesTab，
  // 配对成功后由本页切回「已连接设备」
  @State deviceSection: number = 0;
  // 手机窄屏侧栏抽屉：**必须在根 Stack（全屏）渲染**——放在内容区会因 padding(16) 内缩，
  // 表现为「面板不贴边 + 遮罩是内缩的直角暗层」（用户实测反馈）。
  @State drawerOpen: boolean = false;
  // 抽屉里「展开 ⌄」只用于**已连接设备列表**（对齐参考稿「我的产品」：先露前几个，点开看全部）
  @State drawerExpanded: boolean = false;
  // 抽屉里选中的设备：页面据此展示「设备信息 + 大按钮」（未选中时仍显示已连接列表）
  @State selectedDeviceId: string = '';
  private noticeTimerId: number = -1;
  // 点击/发包限频（key = "设备:动作" → 上次触发时刻）。手机实测：卡片点太快会连发网络请求 +
  // 连开弹窗，叠加重渲染直接把主线程压死（THREAD_BLOCK_3S/6S → 点击无响应）。
  private actionGateMs: Map<string, number> = new Map();
  // 日志刷新节流（缓冲与文本已移入 common/LogStore.ets）：日志可能每秒来十几条（每个 packet 一条），
  // 攒一批再 flush，避免刷新频率跟着日志频率走。
  private logFlushTimer: number = -1;
  private logLastFlushMs: number = 0;   // 上次 flushLog 时刻（P2-2 动态窗用）
  // 音量 Slider 的「用户是否真在拖」标志。
  // 实测坑：Slider 的 onChange 在**程序性**改 value/max 时也会回调（面板刚打开时 length 从 -1
  // 变成真实值 ⇒ 回调被当成 Click/End）→ 误发设置请求。
  // 因此只有先收到 Begin（真拖动才会发）的这一次才算用户操作。
  // （进度条的同类 gate 已随批2 下沉进 MprisProgress 组件内部。）
  private mprisVolDragging: boolean = false;
  // 局域网发现（MSG73/MSG74）：网络变化时触发 native 重新广播 identity
  private netConnection: connection.NetConnection | undefined = undefined;
  private netConnRegistered: boolean = false;
  // AP-2 payload 传输（接收/发送进度与处置状态）
  @State payloads: PayloadTransfer[] = [];
  // 多选发送队列（CodeArts MSG19 §3：**串行**、不并发抢 payload 通道）。
  // 为什么不是"固定间隔 sleep"：那是时间猜测——链路/对端一慢就仍会并发撞通道。
  // 这里改成「上一个 payload 到达终态事件后再发下一个」，与 native 的完成语义对齐（事件驱动）。
  // 依赖：native 为每个 payload 派发终态事件（P3-2 已登记跟踪；若漏派，队列会停在这一批）。
  private sendQueue: SendJob[] = [];
  private sendBusyId: number = -1;   // 正在传输的 transferId（-1 = 空闲）
  private sendInflightJob: SendJob | undefined = undefined;  // 上面那个 transferId 对应的任务（结算用）
  private sendTarget: string = '';   // 本批次目标设备
  private sendOkCount: number = 0;   // 本批次**成功完成**的文件数（在终态里结算，不在下发时计数）
  private sendTotal: number = 0;     // 本批次总数（>0 表示批次进行中）
  // 插件推来的展示项（目前：电量）
  @State batteryItems: BatteryItem[] = [];
  // 对端（kdeconnect.runcommand）下发的预设命令列表：只保存当前设备的，供「远程命令」弹窗展示
  @State runCommands: RunCommandEntry[] = [];
  @State runCommandDeviceId: string = '';
  // 远程命令弹窗显隐
  @State runCommandDialogOpen: boolean = false;
  // 文件页「查看已接收」弹窗（只读列表，展示本次会话收到的文件及其状态）
  @State receivedDialogOpen: boolean = false;
  // 已接收文件历史（跨重启保留；只存终态记录，见 common/PayloadHistory.ets）
  @State receivedHistory: PayloadTransfer[] = [];
  // 「文件详情」弹窗（点击文件行打开）：显示属性 + 另存为/丢弃/取消
  @State payloadDetailOpen: boolean = false;
  @State payloadDetailId: number = 0;
  // 对端音频输出设备（kdeconnect.systemvolume 的**全量快照**，刻度已换算成百分比）：
  // 由 SystemVolumePlugin 推来，UI 只渲染（见 components/SystemSinkRow.ets）。
  @State svSinks: SystemSinkUi[] = [];
  @State svDeviceId: string = '';        // 上面快照属于哪台设备（防切换面板时串数据）
  // 媒体面板的两个 tab（用户 2026-09-18 要求）：0=媒体（播放器控制）1=设备（OutputDevice 列表）
  @State mprisTab: number = 0;
  // 媒体控制面板（方向 1：手机控电脑端播放器）：按设备镜像对端播放器状态
  @State mprisItems: MprisItem[] = [];
  @State mprisDeviceId: string = '';
  @State mprisDialogOpen: boolean = false;
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
  // AP-3：信任设备（Preferences 持久化，UI 用 rememberedDevices 展示）
  private trustedDevices: TrustedDevice[] = [];
  // 信任表是否已从 Preferences 加载完成；加载前连上的设备先排队，加载后再补记
  private trustLoaded: boolean = false;
  private pendingKnown: TrustedDevice[] = [];
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
      this.receivedHistory = await PayloadHistory.load(ctx);
      // 回灌到 payloads：文件页的「历史记录」分区直接读 payloads，不回灌则重启后历史为空
      // （2026-09-17 用户实测「历史文件只有一条」——发送记录既没入库也没回灌）。
      // 注意：历史条目一律置 settled=true —— 它们是**已结束**的旧记录，spool 早被清理，
      // 否则会被归到「收到的文件（待处置）」并诱使用户点「保存」而必然失败。
      this.payloads = this.receivedHistory.map((h: PayloadTransfer): PayloadTransfer => {
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
      this.deviceName = String(await pref.get('deviceName', ''));
      this.systemName = systemDeviceName(ctx);
      if (this.deviceName.length === 0) {
        this.deviceName = this.systemName;
      }
      this.themeMode = parseInt(String(await pref.get('themeMode', '0')), 10) || THEME_FOLLOW_SYSTEM;
      this.language = String(await pref.get('language', LANG_SYSTEM));
      // AP-3：信任设备（含旧的 rememberedDevices 一次性迁移）
      this.trustedDevices = await TrustStore.load(ctx);
      this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
        return r;
      });
      this.log(`trust store: ${this.trustedDevices.length} device(s)`);
      // WP-2 钉扎：把已配对设备的对端证书回灌给 native（内存态），重启后仍能强校验
      for (const t of this.trustedDevices) {
        if (t.certPem.length > 0) {
          try {
            native.setTrustedCertificate(t.id, t.certPem);
          } catch (e) {
            this.log(`pin rehydrate failed: ${t.id}`);
          }
        }
      }
      // 加载完成后才允许写回：否则「启动即连接」时 rememberKnown 会拿着空表 persist，
      // 把已存的已知设备截断（实测丢过条目）。先把这期间连上的设备排队，加载完再补记。
      this.trustLoaded = true;
      for (const p of this.pendingKnown) {
        this.rememberKnown(p.id, p.name);
      }
      this.pendingKnown = [];
    } catch (e) {
      // Preferences load failed, will generate new below
    }
    // 设置读取完成后再应用（否则 onPageShow 可能早于读取完成，把默认值当成当前值应用 → 表现为"重开恢复默认"）
    this.settingsLoaded = true;
    console.info(`KDC settings loaded: deviceName=${this.deviceName} themeMode=${this.themeMode} language=${this.language}`);
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
        self.handleEvent(event);
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
      this.log(m);
    });
    const callbacks: RouterCallbacks = {
      onPairRequest: (id: string, ts: number): void => {
        // 对端发起：交给状态机（内含"双方同时发起"race 检测）；验证码由页面算好写入（字段约定）。
        this.pairSession.onPeerPairRequest(id, ts);
        this.pairSession.code = this.computePairCode(id, ts);
      },
      onPaired: (id: string): void => {
        this.handlePaired(id);          // trust 落盘 + 证书钉扎 + 日志（UI/持久化职责留页面）
        this.pairSession.onPeerPaired(id);   // 状态机收口（幂等：见 PairSession.succeed 的 idle 短路）
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
    this.router = new PacketRouter(this.deviceId, this.deviceName, 'phone',
      (msg: string): void => {
        this.log(msg);
      }, callbacks);
    // 阶段 2 接线：把会话状态机的副作用接回页面既有实现（状态机自身不碰 I/O/UI/持久化）。
    this.pairSession.onLog = (m: string): void => { this.log(m); };
    this.pairSession.onNotice = (kind: string, detail: string, isError: boolean, code: number): void => {
      this.showNotice(kind, detail, isError, code);
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
      this.setPairedFlag(id, true);          // ★ 单一写者（勿在此再内联写 paired）
      // 旧 succeedSession() 的 UI 副作用：跳回「已连接设备」+ 选中该设备 + 清过期限频键 + 成功提示
      this.deviceSection = 0;
      if (id.length > 0) {
        this.selectedDeviceId = id;
        this.pruneActionGate();
      }
      this.showNotice('paired', '', false);
    };
    this.pairSession.onUnpaired = (id: string): void => { this.handleUnpaired(id); };
    this.startNative();
    this.registerNetworkListener();
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
      this.applyTheme(this.themeMode, false);
      this.applyLanguage(this.language, false);
    }, 300);
  }

  aboutToDisappear(): void {
    this.unregisterNetworkListener();
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
        deviceName: this.deviceName,
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
        this.log(`caps: in=${incoming.length} out=${outgoing.length}`);
      } catch (e) {
        this.log('setCapabilities unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
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
        this.log('native.start returned false (port conflict or UDP bind failure)');
        return;
      }
      this.status = 'running';
    } catch (e) {
      this.status = 'start failed: ' + (e instanceof Error ? e.message : 'unknown');
    }
  }

  // 解析持久化的已配对设备列表（JSON 数组 [{id, name}]）
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
      this.log('persist settings failed');
    }
  }

  private async persistTrust(): Promise<void> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.log('persist trust failed: no host context');
      return;
    }
    await TrustStore.save(hostCtx, this.trustedDevices);
  }

  // 自定义设备名：持久化并重启 native 栈，使 identity 广播/握手使用新名称（deviceId/证书不变）
  private renameDevice(name: string): void {
    if (name.length === 0 || name === this.deviceName) {
      return;
    }
    this.deviceName = name;
    const nameEntries: SettingEntry[] = [{ key: 'deviceName', value: name }];
    this.persistSettings(nameEntries);
    this.log(`rename device -> ${name} (restart native)`);
    try {
      native.stop();
    } catch (e) {
      // ignore
    }
    this.startNative();
  }

  // 设置页「使用系统名称」：把设备名恢复为系统设备名称（重新读取一次，避免系统名被改过）
  private useSystemDeviceName(): void {
    const name: string = systemDeviceName(this.getUIContext().getHostContext());
    this.systemName = name;
    this.log(`use system device name: ${name}`);
    this.renameDevice(name);
  }

  private applyTheme(mode: number, persist: boolean): void {
    this.themeMode = mode;
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx !== undefined) {
        hostCtx.getApplicationContext().setColorMode(colorModeOf(mode));
      }
    } catch (e) {
      this.log('setColorMode failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    if (persist) {
      const themeEntries: SettingEntry[] = [{ key: 'themeMode', value: `${mode}` }];
      this.persistSettings(themeEntries);
    }
  }

  private applyLanguage(language: string, persist: boolean): void {
    this.language = language;
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx !== undefined) {
        hostCtx.getApplicationContext().setLanguage(languageOf(language));
      }
    } catch (e) {
      this.log('setLanguage failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    if (persist) {
      const langEntries: SettingEntry[] = [{ key: 'language', value: language }];
      this.persistSettings(langEntries);
    }
  }

  // 局域网发现（CodeArts MSG73/MSG74）：网络变化时通知 native 重新广播 identity。
  // 用户真机反馈「发现设备」长时间为空：对端后启动 / 丢包 / 切网后只能等对端再广播，
  // 这里在 netAvailable 时主动触发一次本侧广播（native.triggerBroadcast，omp 实现后生效）。
  private registerNetworkListener(): void {
    if (this.netConnRegistered) {
      return;
    }
    try {
      const conn: connection.NetConnection = connection.createNetConnection();
      conn.on('netAvailable', (): void => {
        // 网络抖动 / 多网卡（WiFi+蜂窝+多张卡）会连着发 netAvailable，每次都同步调
        // native.triggerBroadcast() 会在主线程上扎堆 —— 用户实测「手动打开 WiFi 那一瞬间 App 就卡住」。
        // 这里先做 3s 限频（对端周期广播 + native 侧 caps 变更重播已能覆盖发现，少发一次不影响发现）。
        if (!this.actionGate('net:triggerBroadcast', 3000)) {
          return;
        }
        this.log('network available — trigger discovery broadcast');
        this.triggerDiscoveryBroadcast();
      });
      conn.on('netLost', (): void => {
        this.log('network lost');
      });
      // 本 SDK（OpenHarmony API 26）只有 callback 形式：register(callback: AsyncCallback<void>)
      conn.register((err: BusinessError): void => {
        if (err) {
          this.log(`net listener register failed: ${err.code}`);
          return;
        }
        this.netConnection = conn;
        this.netConnRegistered = true;
        this.log('net change listener registered');
      });
    } catch (e) {
      this.log('net listener failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  private unregisterNetworkListener(): void {
    const conn: connection.NetConnection | undefined = this.netConnection;
    if (conn === undefined || !this.netConnRegistered) {
      return;
    }
    try {
      conn.unregister((err: BusinessError): void => {
        if (err) {
          return;
        }
      });
    } catch (e) {
      // 忽略：进程退出路径
    }
    this.netConnection = undefined;
    this.netConnRegistered = false;
  }

  // 触发一次 UDP identity 广播（native 未导出该符号时静默降级，不写屏幕日志）
  private triggerDiscoveryBroadcast(): void {
    try {
      this.probeNative('triggerBroadcast', (): void => {
        native.triggerBroadcast();
      });
    } catch (e) {
      this.log('triggerBroadcast unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
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
  private onPluginEvent(deviceId: string, ev: PluginEvent): void {
    const kind: string = ev.kind;
    const data: string = ev.text ?? '';
    if (kind === 'runcommand.list') {
      this.runCommandDeviceId = deviceId;
      this.runCommands = this.commandsOf(deviceId);
      this.log(`run command list <- ${deviceId} (${data})`);
      return;
    }
    if (kind === 'runcommand.output') {
      // 嵌套 payload（裁定表 #6）：读 ev.runOutput 结构化字段
      const ro: RunOutputPayload | undefined = ev.runOutput;
      if (ro === undefined) {
        return;
      }
      const ok: boolean = ro.success;
      const code: number = ro.exitCode;
      const text: string = ro.text;
      const head: string = this.resText(ok
        ? $r('app.string.toast_run_cmd_ok').id : $r('app.string.toast_run_cmd_failed').id);
      this.toastText(text.length > 0 ? `${head} (exit=${code}): ${text}` : `${head} (exit=${code})`);
      this.log(`run command output <- ${deviceId}: success=${ok} exit=${code}`);
      return;
    }
    if (kind === 'clipboard.request') {
      // 对端索取本机剪贴板：三方应用无权读剪贴板，只能提示用户点「粘贴」按钮授权发送
      this.toastText(this.resText($r('app.string.toast_clipboard_requested').id));
      this.log(`clipboard requested by ${deviceId}`);
      return;
    }
    // 媒体控制（方向 1）：类型化对象直读，省掉每事件一次 stringify+parse
    if (kind === 'mpris.playerList') {
      this.setMprisList(deviceId, ev.mprisList ?? []);
      return;
    }
    if (kind === 'mpris.playerUpdate') {
      const snap: MprisSnapshot | undefined = ev.mprisSnap;
      if (snap !== undefined) {
        this.setMprisSnapshot(deviceId, snap);
      }
      return;
    }
    // 系统音量（kdeconnect.systemvolume）：插件推**整份行数组**（已换算成百分比），UI 只渲染。
    // **单槽**（用户 2026-09-19 裁决 / CodeArts MSG21 §3）：面板一次只服务一台设备 ⇒ 只接受
    // 当前面板设备的推送。别的设备推包不得改写它（否则正在看的面板会被刷空）。
    // 不会缺数据：打开面板时 svPrepare() 会主动 requestSinks()，该响应带着自己的 deviceId 回来。
    // （请求-响应同源：插件是"每设备一份实例"，响应只会从被请求的那台设备回来 —— Omp MSG27 §3 提醒点。）
    // 旧实现是 `"<vol>|<muted>"` 字符串打包 + 页面侧 split 解包，与批1 的类型化方向相反，已删除。
    // P3-3（语义澄清，**零行为变更**）：`requestSinks()` 的**响应**与插件主动推送走的是**同一条事件通道**
    // （都是 kind='systemvolume.sinks'，由 SystemVolumePlugin.push() 发出）⇒ 下面的单槽过滤对"响应"同样生效，
    // 不存在"请求-响应串台"（插件本身是**每设备一份实例**，响应只会从被请求的那台设备回来）。
    if (kind === 'systemvolume.sinks') {
      if (deviceId !== this.mprisDeviceId) {
        return;
      }
      this.svSinks = ev.svSinks !== undefined ? ev.svSinks : [];
      return;
    }
    if (kind !== 'battery') {
      this.log(`plugin event ${kind} from ${deviceId}`);
      return;
    }
    // 嵌套 payload（裁定表 #6）：读 ev.battery 结构化字段
    const bp: BatteryPayload | undefined = ev.battery;
    if (bp === undefined) {
      return;
    }
    const charge: number = bp.charge;
    const charging: boolean = bp.charging;
    const text: string = `${charge}%${charging ? ' ⚡' : ''}`;
    const exists: boolean = this.batteryItems.some((b: BatteryItem) => b.deviceId === deviceId);
    const item: BatteryItem = { deviceId: deviceId, text: text };
    if (exists) {
      this.batteryItems = this.batteryItems.map((b: BatteryItem) => b.deviceId === deviceId ? item : b);
    } else {
      this.batteryItems = this.batteryItems.concat([item]);
    }
    this.log(`battery ${text} <- ${deviceId}`);
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

  // ========== 媒体控制（方向 1：手机控电脑端播放器，FEATURE_PLAN_MPRIS §3）==========
  // 当前是否正为该设备打开媒体面板（决定要不要把插件事件写进 @State）
  private isMprisPanelFor(deviceId: string): boolean {
    return this.mprisDialogOpen && this.mprisDeviceId === deviceId;
  }

  // 按设备镜像对端播放器状态：@State mprisItems（对齐 batteryItems 的写法）
  private mprisItemOf(deviceId: string): MprisItem {
    for (const m of this.mprisItems) {
      if (m.deviceId === deviceId) {
        return m;
      }
    }
    return emptyMprisItem(deviceId);
  }

  private putMpris(next: MprisItem): void {
    const exists: boolean = this.mprisItems.some((m: MprisItem) => m.deviceId === next.deviceId);
    if (exists) {
      this.mprisItems = this.mprisItems.map((m: MprisItem) => m.deviceId === next.deviceId ? next : m);
    } else {
      this.mprisItems = this.mprisItems.concat([next]);
    }
  }

  private setMprisList(deviceId: string, list: string[]): void {
    // 前后台分离（用户建议）：面板没开就不写 @State —— 对端会周期推播放器状态，
    // 关着面板还写会白白触发整页重渲染。面板打开时用 MprisPlugin.item() 重新播种，不会丢数据。
    if (!this.isMprisPanelFor(deviceId)) {
      return;
    }
    const cur: MprisItem = this.mprisItemOf(deviceId);
    const next: MprisItem = {
      deviceId: cur.deviceId,
      playerList: list,
      currentPlayer: cur.currentPlayer,
      gotAny: true,
      snapshot: cur.snapshot
    };
    this.putMpris(next);
  }

  private setMprisSnapshot(deviceId: string, snap: MprisSnapshot): void {
    // 同上：关着面板时不写 @State（对端 ~1s 推一次 pos，逐次写会持续触发整页重渲染）
    if (!this.isMprisPanelFor(deviceId)) {
      return;
    }
    const cur: MprisItem = this.mprisItemOf(deviceId);
    const next: MprisItem = {
      deviceId: cur.deviceId,
      playerList: cur.playerList,
      currentPlayer: snap.player.length > 0 ? snap.player : cur.currentPlayer,
      gotAny: true,
      snapshot: snap
    };
    this.putMpris(next);
  }

  private mprisPluginOf(deviceId: string): MprisPlugin | undefined {
    const list: PluginBase[] = this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(deviceId);
    for (const p of list) {
      if (p instanceof MprisPlugin) {
        return p;
      }
    }
    return undefined;
  }

  // 系统音量插件取用（与 MPRIS 分开：播放器不提供音量/无播放器时仍可调对端系统音量）
  private sysVolumePluginOf(deviceId: string): SystemVolumePlugin | undefined {
    const list: PluginBase[] = this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(deviceId);
    for (const p of list) {
      if (p instanceof SystemVolumePlugin) {
        return p;
      }
    }
    return undefined;
  }

  // 当前面板设备的输出设备快照（设备不符 ⇒ 空数组，避免显示上一台设备的行）
  private svSinksForCurrent(): SystemSinkUi[] {
    return this.svDeviceId === this.mprisDeviceId ? this.svSinks : [];
  }

  // 打开面板时：换设备先清空快照，再向对端**请求一次列表**（协议级刷新，
  // 与媒体 tab 的 requestPlayerList/requestStatus 同性质）。
  // 注意：这里**不再**从插件"抄状态"到页面 —— 状态只有插件一份，任何变化它都会推全量快照。
  private svPrepare(): void {
    if (this.svDeviceId !== this.mprisDeviceId) {
      this.svSinks = [];
      this.svDeviceId = this.mprisDeviceId;
    }
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
    if (p !== undefined) {
      p.requestSinks();
    }
  }

  private svSinkSet(name: string, pct: number): void {
    // 60ms 轻门控（用户要求拖动实时同步；Android 端不松手即同步，这里只防刷包）
    if (!this.actionGate(`sysvol:${name}:vol`, 60)) {
      return;
    }
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
    if (p === undefined || !p.setVolume(name, pct)) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private svSinkToggleMute(name: string): void {
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
    if (p === undefined || !p.toggleMute(name)) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  // 「选择输出设备」：把该 sink 设为对端默认输出（协议上单独发 {name, enabled:true}）
  private svSinkSetDefault(name: string): void {
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
    if (p === undefined || !p.setDefault(name)) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  // 面板页脚「刷新」：按当前 tab 决定刷新对象（媒体=播放器列表/状态，设备=输出设备列表）
  private panelRefresh(): void {
    if (this.mprisTab === 1) {
      const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
      if (p === undefined || !p.requestSinks()) {
        this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
      }
      return;
    }
    this.mediaRefresh();
  }

  // 面板读数（build() 里直接调，靠 @State 触发刷新；**不要**用 @Builder 传值，值参数不变会跳过重建）
  private mprisSnap(): MprisSnapshot {
    return this.mprisItemOf(this.mprisDeviceId).snapshot;
  }

  private mprisList(): string[] {
    return this.mprisItemOf(this.mprisDeviceId).playerList;
  }

  // 对端没响应 / 对端没有播放器 → 都走空态
  private mprisEmpty(): boolean {
    const it: MprisItem = this.mprisItemOf(this.mprisDeviceId);
    return !it.gotAny || it.playerList.length === 0;
  }

  // 音量读数（进度条的插值/千分比量程随批2 一起下沉进 MprisProgress 组件，
  // 页面侧不再保留 mprisNowMs / mprisPos / mprisPosPermille / mprisPermilleToMs / mprisMaxPos —— 均已删除）
  private mprisVol(): number {
    const v: number = this.mprisSnap().volume;
    return v > 0 ? v : 0;
  }

  private mprisArtistLine(): ResourceStr {
    const s: MprisSnapshot = this.mprisSnap();
    if (s.artist.length > 0 && s.album.length > 0) {
      return `${s.artist} · ${s.album}`;
    }
    if (s.artist.length > 0) {
      return s.artist;
    }
    if (s.album.length > 0) {
      return s.album;
    }
    return $r('app.string.media_unknown_artist');
  }

  private mprisLoopText(): ResourceStr {
    const cur: string = this.mprisSnap().loopStatus;
    if (cur === 'Track') {
      return $r('app.string.media_loop_track');
    }
    if (cur === 'Playlist') {
      return $r('app.string.media_loop_playlist');
    }
    return $r('app.string.media_loop_none');
  }

  private closeMprisDialog(): void {
    this.mprisDialogOpen = false;
  }

  // P2（MSG132 §2）：设备断链/离线 → 丢掉该设备的面板镜像 + 关面板停 ticker。
  // 过期快照若留着，重连前打开面板会显示旧曲目，并继续用本地插值往前跑（假进度）。
  private forgetMpris(deviceId: string): void {
    if (deviceId.length === 0) {
      return;
    }
    this.mprisItems = this.mprisItems.filter((m: MprisItem) => m.deviceId !== deviceId);
    if (this.mprisDeviceId === deviceId) {
      this.closeMprisDialog();
    }
  }

  // 控制类动作：插件没装载（对端不支持）或发送失败都给明确提示
  private mediaAction(action: string): void {
    // 连点保护：⏮⏯⏭ 每次都会真发包，连点会把主线程和对端一起刷爆
    if (!this.actionGate(`mpris:${this.mprisDeviceId}:${action}`, 400)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined) {
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    let ok: boolean = false;
    if (action === 'toggle') {
      ok = p.togglePlay();
    } else if (action === 'next') {
      ok = p.next();
    } else if (action === 'previous') {
      ok = p.previous();
    }
    if (!ok) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private mediaSetVolume(v: number): void {
    if (!this.actionGate(`mpris:${this.mprisDeviceId}:vol`, 200)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined || !p.setVolume(v)) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private mediaSetPosition(ms: number): void {
    if (!this.actionGate(`mpris:${this.mprisDeviceId}:pos`, 200)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined || !p.setPosition(ms)) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private mediaToggleLoop(): void {
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined || !p.cycleLoopStatus()) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private mediaToggleShuffle(): void {
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined || !p.toggleShuffle()) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private mediaSelectPlayer(name: string): void {
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined) {
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    p.selectPlayer(name);
    p.requestStatus(name);
  }

  private mediaRefresh(): void {
    if (!this.actionGate(`mpris:${this.mprisDeviceId}:refresh`, 1500)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.mprisDeviceId);
    if (p === undefined) {
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    p.requestPlayerList();
    p.requestStatus();
    this.log(`media refresh requested for ${this.mprisDeviceId}`);
  }

  // AP-4：非核心 packet 分发到插件（返回 true 表示已处理）
  private dispatchPluginPacket(deviceId: string, packetType: string, body: Object): boolean {
    if (this.pluginHost === undefined) {
      return false;
    }
    return this.pluginHost.dispatch(deviceId, packetType, body);
  }

  // 验证码由 native 计算（公钥 SPKI DER 排序拼接 + SHA256，ArkTS 无法做 ASN.1 解析）。
  // 无 TLS 链路/无对端证书时 native 返回空串 → UI 显示占位。
  private computePairCode(deviceId: string, timestamp: number): string {
    try {
      const code: string = native.getPairVerificationCode(deviceId, timestamp);
      if (code.length === 0) {
        return '';
      }
      // 8 位 hex → 4 段 2 字符（AB CD EF 12）
      const parts: string[] = [];
      for (let i = 0; i + 1 < code.length; i += 2) {
        parts.push(code.substring(i, i + 2));
      }
      return parts.join(' ');
    } catch (e) {
      this.log('getPairVerificationCode unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    }
  }

  // 已连接设备行「配对」按钮（需求 4.3）：先弹本侧配对确认框（显示验证码），
  // 用户确认后才发请求 → 对端弹配对申请通知 → 两端核对验证码一致 → 配对成功。
  private requestPairWith(d: DeviceItem): void {
    if (this.router === undefined) {
      return;
    }
    const selfTs: number = Math.floor(Date.now() / 1000);
    this.pairSession.openPrompt(d.id, d.name, selfTs, this.computePairCode(d.id, selfTs));
  }

  private displayNameOf(deviceId: string): string {
    const conn: DeviceItem | undefined = this.connectedDevices.find((d: DeviceItem) => d.id === deviceId);
    if (conn !== undefined) {
      return conn.name;
    }
    const disc: DeviceItem | undefined = this.discoveredDevices.find((d: DeviceItem) => d.id === deviceId);
    if (disc !== undefined) {
      return disc.name;
    }
    const rem: RememberedDevice | undefined = this.rememberedDevices.find((r: RememberedDevice) => r.id === deviceId);
    if (rem !== undefined) {
      return rem.name;
    }
    return deviceId;
  }

  // 配对成功回调（本侧请求被对端确认，或本侧接受后）：写入记住列表
  private handlePaired(deviceId: string): void {
    if (deviceId === '') {
      return;
    }
    const name: string = this.displayNameOf(deviceId);
    const exists: boolean = this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId);
    let peerCert: string = '';
    try {
      peerCert = native.getPeerCertificate(deviceId);
    } catch (e) {
      this.log('getPeerCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    if (exists) {
      // 重新配对：条目保留、只刷新名称/证书。**paired 的置位不再内联写**（原来是 `paired: true`），
      // 统一交给下面的 `setPairedFlag()` —— MSG50 §3 收敛：配对态有且只有一个写者。
      this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        if (t.id !== deviceId) {
          return t;
        }
        const next: TrustedDevice = {
          id: t.id,
          name: name.length > 0 ? name : t.name,
          certPem: peerCert.length > 0 ? peerCert : t.certPem,
          pairedAt: t.pairedAt,
          paired: t.paired
        };
        return next;
      });
    } else {
      const entry: TrustedDevice = {
        id: deviceId,
        name: name,
        certPem: peerCert,
        pairedAt: 0,
        paired: false
      };
      this.trustedDevices = this.trustedDevices.concat([entry]);
    }
    // ★ 单一写者：置「已配对」——由 setPairedFlag 负责 trusted↔remembered 同步 + 持久化 + 状态日志
    //（新条目会被它补上 pairedAt；已是已配对则不重复刷时间戳，语义更稳）。
    this.setPairedFlag(deviceId, true);
    // 兜底持久化：setPairedFlag 在"本来就是已配对"时会提前返回，而上面名称/证书的刷新仍需落盘
    //（persistTrust 幂等，故这里保留这一次调用是本方法唯一的持久化点）。
    this.persistTrust();
    this.syncSelectedDevice();
    // WP-2 钉扎：登记对端证书，后续连接强校验（证书不符 → error EACCES + 断链）
    if (peerCert.length > 0) {
      try {
        native.setTrustedCertificate(deviceId, peerCert);
      } catch (e) {
        this.log('setTrustedCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      }
    }
    this.log(`paired with ${deviceId} (cert=${peerCert.length > 0 ? 'stored' : 'unavailable'})`);
    // 会话收口交给状态机（RouterCallbacks.onPaired 里已调 pairSession.onPeerPaired ⇒ 会走 onPaired 回调做 UI 副作用）
  }

  // 对端发 unpair {pair:false} 或本侧解除配对：
  // 需求 3（用户 miaoshu.txt）——**保留条目**（便于后续重新配对），只置 paired=false 并清钉扎。
  private handleUnpaired(deviceId: string): void {
    // 会话收口交给状态机（pairSession.onPeerUnpaired → reset → 回调这里）；本方法只做 trust/钉扎/日志。
    // WP-2：解除钉扎（native 侧不再强校验该设备证书）
    try {
      native.removeTrustedCertificate(deviceId);
    } catch (e) {
      this.log('removeTrustedCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
      // 单一来源（修 AtomCode/用户实测「对端解除配对后本侧 UI 仍显示【已配对】」）：
      // 旧实现这里**自己又实现了一遍**置配对态，且守卫写成 `trustedDevices.length !== before` ——
      // `map()` 不改变数组长度 ⇒ 该分支**恒不执行** ⇒ `rememberedDevices`（行徽标真正读的数据）不更新、
      // 也不持久化，连那行 `unpaired …` 日志都不打（与真机取证：两次对端 unpair、徽标仍为已配对、无该日志，完全吻合）。
      // 现在统一走 `setPairedFlag()`：由它负责 trusted/remembered 同步 + 持久化 + 状态日志，消除这份重复实现。
      this.setPairedFlag(deviceId, false);
      this.log(`unpaired ${deviceId} (kept in remembered list)`);
  }

  private handleEvent(event: NetEvent): void {
    // 事件日志（性能关键路径）：原实现对**每个**事件做整对象 JSON.stringify + 打一行 hilog，
    // 而 packet 字段本身已是数 KB 字符串 ⇒ 每事件一次数 KB 拷贝 + 一次同步 hilog 写。
    // omp（NATIVE_ANALYSIS §2）指出慢 `JsSendPacket`(1.3~5.8s) 疑似「调度延迟或 hilog 同步写阻塞」，
    // 与我 ARKTS_ANALYSIS §5(#2) 指向同一处 ⇒ 收敛为：
    //   ① 常态只打「类型 + deviceId 前 8 位 + packet 长度」（轻量，仍够排查时序）；
    //   ② 需要 packet 原文时把 debugEventLog 置 true（临时排查用）。
    const pktLen: number = event.packet === undefined || event.packet === null ? 0 : event.packet.length;
    if (this.debugEventLog) {
      console.info('KDC net event: ' + JSON.stringify(event));
    } else {
      console.info(`KDC event ${event.type ?? '?'} dev=${(event.deviceId ?? '').substring(0, 8)} pktLen=${pktLen}`);
    }
    switch (event.type) {
      case 'deviceDiscovered': {
        const id: string = event.deviceId ?? '';
        if (id === '' || id === this.deviceId) {
          break;
        }
        const item: DeviceItem = {
          id: id,
          name: event.deviceName ?? id,
          host: event.host ?? '',
          tcpPort: event.tcpPort ?? 0,
          deviceType: '',
          online: true
        };
        // 发现列表按 id 去重更新（对端周期广播 identity 会重复触发）。
        // 连接由用户从发现列表显式发起（与 iOS 一致），不再发现即自动连接。
        // 关键：内容没变就**不写 @State** —— 对端每秒都可能重复广播，每次写都会让整页重渲染，
        // 是本 App 主线程慢性饿死（THREAD_BLOCK_3S/6S）的主要来源之一。
        const known: boolean = this.discoveredDevices.some((d: DeviceItem) => d.id === id);
        if (known) {
          const cur: DeviceItem | undefined = this.discoveredDevices.find((d: DeviceItem) => d.id === id);
          const same: boolean = cur !== undefined && cur.name === item.name && cur.host === item.host
            && cur.tcpPort === item.tcpPort && cur.online;
          if (same) {
            break;
          }
          this.discoveredDevices = this.discoveredDevices.map(
            (d: DeviceItem) => d.id === id ? item : d);
        } else {
          this.discoveredDevices = [item].concat(this.discoveredDevices);
        }
        this.log(`discovered ${id}`);
        break;
      }
      case 'connected': {
        const cid: string = event.deviceId ?? '';
        if (cid !== '') {
          // 真值模型（MSG85）：对端拨入即视为连接，一律进「已连接设备」——
          // 不做抑制/拒连，避免「桌面显示已连接、本机列表为空」的两端不一致。
          const dev: DeviceItem = {
            id: cid,
            name: event.deviceName ?? cid,
            // native 现在会带 host（出向连接还带 tcpPort）—— 别再硬编码空串，
            // 否则「已连接设备」永远不显示地址（入向连接的对端端口是临时端口，native 只给 host）。
            host: event.host ?? '',
            tcpPort: event.tcpPort ?? 0,
            deviceType: '',
            online: true
          };
          // ② 同一设备可能重复触发 connected，先去重再追加。
          //    需求 2：**保留发现列表里的条目**（两列表并存）。
          this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== cid);
          this.connectedDevices = this.connectedDevices.concat([dev]);
          // ②-b 曾经连接过 ⇒ 写入已知设备表（未配对也记住）：断链后进「记住的设备」（离线灰）
          this.rememberKnown(cid, event.deviceName ?? cid);
          // ③ 插件装载兜底（MSG81）：native 不派发 identity 帧时 caps 不可知 → 按「全支持」装载
          if (this.pluginHost !== undefined && this.pluginHost.pluginsFor(cid).length === 0) {
            this.loadPlugins(cid, [], []);
            this.log(`plugins loaded for ${cid} with unknown caps (fallback)`);
          }
          // ④ 本侧发起连接的反馈（手动连接时发起前不知道 deviceId，这里按会话状态收口）
          //    状态迁移交给状态机；**提示是 UI 职责**，仍在页面发（与拆分前逐字一致）。
          if (this.pairSession.stage === 'connecting'
            && (this.pairSession.deviceId === cid || this.pairSession.deviceId === '')) {
            const shownName: string = event.deviceName ?? this.pairSession.peerName;
            this.pairSession.onConnected(cid);
            this.showNotice('connected', shownName, false);
            this.log(`connected ${cid} -> notice 连接成功`);
          }
        }
        this.syncSelectedDevice();
        this.log(`connected ${event.deviceId} role=${event.role}`);
        break;
      }
      case 'disconnected': {
        const did: string = event.deviceId ?? '';
        // 终态兜底：断链后该设备「进行中」的接收传输不可能完成 ⇒ 立即落 failed（否则 UI 永久「接收中」）
        this.failInflightReceives(did, 'disconnected');
        this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== did);
        this.batteryItems = this.batteryItems.filter((b: BatteryItem) => b.deviceId !== did);
        // 断链即清「等待确认」态（否则行上会残留"等待确认"徽标）——由状态机 onDisconnected 统一处理
        // AP-4：断链卸载该设备插件（onDestroy 必达）
        this.pluginHost?.unloadForDevice(did);
        // 媒体面板清账（P2，MSG132 §2）：丢该设备的面板镜像并关面板
        // （插件实例已销毁，再点控制键必然失败；留着快照还会显示过期曲目）
        this.forgetMpris(did);
        // P3（AtomCode 评审条件 / CodeArts MSG21 §2）：断链必须**清空发送队列**，
        // 否则残留任务会在设备重连后自动开传（用户并未再操作，属可见的错误行为）。
        this.forgetSendQueue(did);
        // 会话中的设备断链 → 连接/配对失败（状态机内建；终局三信号之一）
        this.pairSession.onDisconnected(did);
        this.syncSelectedDevice();
        this.log(`disconnected ${event.deviceId}`);
        break;
      }
      case 'deviceLost': {
        // CodeArts MSG78 §2 裁决：超时只置离线（灰显），**不从列表删除**。
        // 但若该设备当前仍是连接态，则不标离线（避免"已连接却显示离线"的状态矛盾）。
        const lid: string = event.deviceId ?? '';
        if (this.connectedDevices.some((d: DeviceItem) => d.id === lid)) {
          this.log(`lost ${lid} ignored (still connected)`);
          break;
        }
        // 同上：已经标过离线就别再写 @State（否则离线设备每秒仍触发整页重渲染）
        const stillOnline: boolean = this.discoveredDevices.some(
          (d: DeviceItem) => d.id === lid && d.online);
        if (!stillOnline) {
          break;
        }
        this.discoveredDevices = this.discoveredDevices.map(
          (d: DeviceItem) => d.id === lid ? { id: d.id, name: d.name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: false } : d);
        // 离线同样清账（P2，MSG132 §2）：面板镜像与弹层都不留过期数据
        this.forgetMpris(lid);
        this.log(`lost ${event.deviceId} (kept in list as offline)`);
        break;
      }
      case 'packetReceived': {
        const raw: string = event.packet ?? '';
        if (event.deviceId !== undefined && raw.length > 0) {
          this.router?.onPacket(event.deviceId, raw);
        }
        this.log(`packet from ${event.deviceId}: ${raw.slice(0, 80)}`);
        break;
      }
      case 'pairingRequest': {
        // 该事件是 TLS 握手层的 identity 帧（非配对请求）。配对请求是
        // packetReceived 里的 kdeconnect.pair 帧，由 PacketRouter.handlePair 应答。
        const pid: string = event.deviceId ?? '';
        if (pid !== '') {
          const name: string = event.deviceName ?? '';
          if (name !== '') {
            // identity 帧带完整设备名，回填到连接/发现列表（connected 事件可能没带）
            this.connectedDevices = this.connectedDevices.map(
              (d: DeviceItem) => d.id === pid ? { id: d.id, name: name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: d.online } : d);
            this.discoveredDevices = this.discoveredDevices.map(
              (d: DeviceItem) => d.id === pid ? { id: d.id, name: name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: d.online } : d);
          }
          this.log(`peer identity: ${name !== '' ? name : pid}`);
        }
        break;
      }
      case 'payloadTransfer': {
        this.handlePayloadTransfer(event);
        break;
      }
      case 'error': {
        // WP-2 限流/钉扎失败给可读提示（errorCode/errorMessage 已对齐 d.ts）
        const em: string = event.errorMessage ?? '';
        // 终态兜底（omp MSG23/24 契约）：native 的 payload FSM 已判 `failed`（如 code=104
        // "control connection closed"），但 `payloadTransfer` 终态事件可能到不了 UI ⇒
        // 这里按 Error 事件把该设备**进行中**的接收传输立即落为 failed，避免永久「接收中」。
        this.failInflightReceives(event.deviceId ?? '', `error: ${em.length > 0 ? em : event.errorCode}`);
        if (em.includes('rate limited')) {
          this.log('连接过于频繁，请稍后重试（rate limited）');
        } else if (em.includes('certificate mismatch')) {
          this.log('对端证书与登记不符，需重新配对（certificate mismatch）');
        } else {
          this.log(`error ${event.errorCode}: ${em}`);
        }
        // 会话进行中报错的处理（修用户实测「电脑端还没接受，本侧就先弹『配对失败 5』」）：
        // 旧条件写成了 `eid === '' || sessionDeviceId === '' || 相等` —— 前两项**放行**了
        // 「native 的无设备错误」与「会话设备暂为空」两种情形 ⇒ **任何**与本次配对无关的瞬时错误
        // （链路换代抖动、另一台设备的 TLS 读失败、无 deviceId 的传输层错误）都会把配对判失败，
        // 而那时我们其实**正在等对端用户点接受**。
        // 新规则（按"谁是权威信号"分层，不再一概而论）：
        //   · 只认**本会话设备**的错误（eid 非空且 === sessionDeviceId）；
        //   · `connecting`（技术握手阶段）→ 报错即失败 ✓（那里错误确实是结论）；
        //   · `awaiting`/`prompt`（**等对端人操作**）→ 错误只记日志、**不判失败** ——
        //     会话终局只由三个明确信号决定：对端拒绝（pair:false）／disconnected／PAIR_TIMEOUT_MS。
        // 会话报错：状态机内建「只认本会话设备 + awaiting/prompt 期间无关错误不判失败」（真机坑固化，勿在外层重复判断）
        this.pairSession.onError(event.deviceId ?? '', event.errorCode ?? 0, em);
        break;
      }
      default:
        this.log(`event: ${event.type}`);
        break;
    }
  }

  // 「解除配对」按钮（已连接设备行/发现设备行共用）：发 unpair {pair:false} + 本侧标记未配对。
  // 用户 2026-09-13 裁决：**链路不用管**——KDE 收到 unpair 后自行处理（可能断链、可能重拨），
  // 我们不再主动 disconnect，也不做任何抑制；`disconnected` 事件到了就把行从列表移除。
  private unpairDevice(d: DeviceItem): void {
    this.log(`unpair ${d.id}`);
    const unpairBody: PairRequestBody = { pair: false };
    const unpairPkt: PairRequestPacket = { id: Date.now(), type: 'kdeconnect.pair', body: unpairBody };
    try {
      const ok: boolean = native.sendPacket(d.id, JSON.stringify(unpairPkt) + '\n');
      this.log(ok ? 'unpair sent' : 'unpair not sent (conn not encrypted?)');
    } catch (e) {
      this.log('unpair send failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    this.handleUnpaired(d.id);
    this.router?.forgetPeer(d.id);
  }

  // 手动连接（可选功能）：host:port 直连，与发现列表「连接」同一条会话状态机
  private manualConnect(host: string, port: number): void {
    if (host.trim().length === 0) {
      this.toastText(this.resText($r('app.string.toast_manual_bad_host').id));
      this.log('manual connect rejected: empty host');
      return;
    }
    if (isNaN(port) || port < 1 || port > 65535) {
      this.toastText(this.resText($r('app.string.toast_manual_bad_port').id));
      this.log(`manual connect rejected: invalid port ${port}`);
      return;
    }
    this.pairSession.start('', `${host}:${port}`, host, port);
  }

  // ---- 连接/配对会话 ----

  private isTrusted(deviceId: string): boolean {
    return this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId && t.paired);
  }

  // 失败码（上线口径：提示只给错误码，明细进日志）

  // 更新某设备的配对态（同时刷新记住列表 + 持久化）
  private setPairedFlag(deviceId: string, paired: boolean): void {
    let changed: boolean = false;
    this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      if (t.id !== deviceId || t.paired === paired) {
        return t;
      }
      changed = true;
      const next: TrustedDevice = {
        id: t.id,
        name: t.name,
        certPem: t.certPem,
        pairedAt: paired ? Date.now() : t.pairedAt,
        paired: paired
      };
      return next;
    });
    if (!changed) {
      return;
    }
    this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
      return r;
    });
    this.persistTrust();
    this.log(`state: ${deviceId} paired=${paired}`);
  }

  // 提示（需求 4.1/4.2 + 用户反馈）：用**系统 toast**（底部居中、系统层级）；
  // 失败只给错误码，明细只进日志（上线口径）。
  // 注意：toast 的 message 用**纯字符串**（带格式参数的 $r(...) 会被 PromptAction 拒绝，实测 "toast failed (4)"）。
  private showNotice(key: string, detail: string, isError: boolean, dupMs: number = 0): void {
    this.noticeKey = key;
    let message: string = this.resText($r('app.string.connect_failed').id);
    if (key === 'connecting') {
      message = `${this.resText($r('app.string.connect_connecting').id)} ${detail}`;
    } else if (key === 'connected') {
      message = `${this.resText($r('app.string.connect_success').id)} ${detail}`;
    } else if (key === 'paired') {
      message = this.resText($r('app.string.pair_success').id);
    } else if (key === 'pairFailed') {
      message = `${this.resText($r('app.string.pair_failed').id)} ${detail}`;
    } else {
      message = `${this.resText($r('app.string.connect_failed').id)} ${detail}`;
    }
    const ms: number = dupMs > 0 ? Math.min(dupMs, 10000) : NOTICE_MS;
    try {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        duration: ms,
        bottom: '96vp'
      });
      this.log(`toast: ${message}`);
    } catch (e) {
      this.log('toast failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // 同步取本地化文案（用于 toast 拼接）
  private resText(resId: number): string {
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return '';
      }
      return hostCtx.resourceManager.getStringSync(resId);
    } catch (e) {
      return '';
    }
  }

  private clearNotice(): void {
    this.noticeKey = '';
  }

  // 剪贴板安全控件回调：拿到临时读权限（PasteButton SUCCESS）后**立刻**读取并发送；
  // 未授权时不得尝试读取（系统要求），只给提示。
  private onClipboardPasteResult(granted: boolean): void {
    if (!granted) {
      this.log('paste button: temporary authorization failed');
      this.toastText(this.resText($r('app.string.toast_clipboard_denied').id));
      return;
    }
    this.onDeviceAction('clipboard');
  }

  // 卡片点击入口（卡片忙碌态：【补丁·待优化】）：
  //   ① 有卡片处于忙碌态 ⇒ 直接忽略本次点击（日志留痕，视觉不变）；
  //   ② 否则置忙碌 + 起 5s 保险丝 + 执行动作；
  //   ③ 释放由**完成事件**驱动：弹窗类等弹窗打开（openMprisDialog/runCommandDialogOpen），
  //      直发类在动作同步返回后立即释放；保险丝只在事件缺失时兜底（fired by timeout）。
  private runCardAction(key: string): void {
    if (this.cardBusyKey.length > 0) {
      console.info(`KDC card busy: ignore tap ${key} (busy=${this.cardBusyKey})`);
      return;
    }
    this.cardBusyKey = key;
    if (this.cardBusyTimer >= 0) {
      clearTimeout(this.cardBusyTimer);
    }
    this.cardBusyTimer = setTimeout((): void => {
      this.cardBusyTimer = -1;
      this.releaseCard(key, 'timeout');
    }, 5000);
    this.onDeviceAction(key);
    // 直发类动作（剪贴板/查找设备/发送文件/远程输入）同步完成 ⇒ 立即释放；弹窗类由弹窗打开时释放
    if (key !== 'media' && key !== 'run_command') {
      this.releaseCard(key, 'event');
    }
  }

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

  // 设备详情页的大按钮动作（计划 B）：能落地的接真实插件，落地不了的给明确提示。
  // 用户要求：点「发送文件」**跳到文件导航**（发送入口在文件页），不直接弹系统选择器。
  private onDeviceAction(key: string): void {
    if (key === 'send_file') {
      this.switchTab(1);
      return;
    }
    const id: string = this.selectedDeviceId;
    // 连点保护（用户 2026-09-15 反馈「点太快就卡」）：卡片动作会真发网络请求 + 开弹窗。
    // 窗口取 300ms：只为挡住抖动式连点；700ms 会让用户「开→取消→马上再开」被误吞（实测被感知成卡顿）。
    if (!this.actionGate(`act:${id}:${key}`, 300)) {
      this.log(`action ${key} throttled (rapid taps)`);
      return;
    }
    const list: PluginBase[] = this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(id);
    if (key === 'clipboard') {
      for (const p of list) {
        if (p instanceof ClipboardPlugin) {
          const ok: boolean = p.sendClipboard();
          this.toastText(this.resText(ok
            ? $r('app.string.toast_clipboard_sent').id
            : $r('app.string.toast_clipboard_failed').id));
          return;
        }
      }
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'clipboard_request') {
      // 卡片整体点击：索取对端剪贴板（对端回复 kdeconnect.clipboard → 插件写入本机剪贴板）
      for (const p of list) {
        if (p instanceof ClipboardPlugin) {
          const ok: boolean = p.requestPeerClipboard();
          this.toastText(this.resText(ok
            ? $r('app.string.toast_clipboard_request_sent').id
            : $r('app.string.toast_clipboard_failed').id));
          return;
        }
      }
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'find_device') {
      // 查找设备：发 `kdeconnect.ping`（对端 KDE 会弹通知/响铃 —— 原「响铃」按钮的行为，用户 2026-09-15 裁决）。
      // 注：`kdeconnect.findmyphone.request` 在 KDE 桌面端不弹通知（用户实测），故不再由按钮发送。
      for (const p of list) {
        if (p instanceof PingPlugin) {
          const ok: boolean = p.sendPing(this.deviceName);
          this.toastText(this.resText(ok
            ? $r('app.string.toast_find_device_sent').id
            : $r('app.string.toast_find_device_failed').id));
          return;
        }
      }
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'run_command') {
      // 远程命令：弹对端预设命令列表（未收到 commandList 时给提示）
      this.runCommandDeviceId = id;
      this.runCommands = this.commandsOf(id);
      this.runCommandDialogOpen = true;
      this.log(`run command dialog: ${this.runCommands.length} entries for ${id}`);
      // 弹窗已弹出 ⇒ 释放该卡片的忙碌态（fired by event）
      this.releaseCard('run_command', 'event');
      return;
    }
    if (key === 'media') {
      // P2-1②（MSG145）：面板开合入口也要限频 —— 快速开合会堆叠弹窗/面板动画（关闭是收敛操作，不需要 gate）。
      if (!this.actionGate(`mpris-open:${id}`, 500)) {
        return;
      }
      // 媒体控制（方向 1，P2）：打开面板并主动拉一次「播放器列表 + 当前播放器状态」。
      // 对端只在状态变化时推包，不主动拉可能长时间停在旧态。
      const mp: MprisPlugin | undefined = this.mprisPluginOf(id);
      if (mp === undefined) {
        this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
        this.log(`media panel unavailable for ${id} (MprisPlugin not loaded)`);
        return;
      }
      this.mprisDeviceId = id;
      this.putMpris(mp.item());
      this.mprisDialogOpen = true;
      this.mprisTab = 0;
      // 打开面板：重置/请求系统音量快照（「设备」tab 的输出设备列表）
      this.svPrepare();
      mp.requestPlayerList();
      mp.requestStatus();
      this.log(`media panel opened for ${id} (players=${this.mprisList().length})`);
      // 弹窗已弹出 ⇒ 释放该卡片的忙碌态（fired by event）
      this.releaseCard('media', 'event');
      return;
    }
    // remote_input：P1 只声明能力，UI 属 P2（MSG112 §4）→ 占位提示
    this.toastPlaceholder(key);
  }

  // 远程命令弹窗里点某条命令 → 请求对端执行
  private runCommand(key: string): void {
    const list: PluginBase[] = this.pluginHost === undefined ? [] : this.pluginHost.pluginsFor(this.runCommandDeviceId);
    this.runCommandDialogOpen = false;
    for (const p of list) {
      if (p instanceof RunCommandPlugin) {
        const ok: boolean = p.run(key);
        this.toastText(this.resText(ok
          ? $r('app.string.toast_run_cmd_sent').id
          : $r('app.string.toast_run_cmd_send_failed').id));
        return;
      }
    }
    this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
  }

  // 切底栏页签（HdsTabs 控制器）；失败只记日志，不阻塞
  private switchTab(index: number): void {
    this.currentTab = index;
    try {
      this.tabsController.changeIndex(index);
      this.log(`switch tab -> ${index}`);
    } catch (e) {
      this.log('changeIndex failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // 设备详情页的大按钮目前只做占位（用户要求：功能暂不实现，先保留版式）
  private toastPlaceholder(key: string): void {
    const base: string = this.resText($r('app.string.toast_not_implemented').id);
    this.toastText(`${base}: ${key}`);
  }

  // 通用 toast（纯字符串；带格式参数的 $r(...) 会被 PromptAction 拒绝）
  private toastText(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        duration: NOTICE_MS,
        bottom: '96vp'
      });
      this.log(`toast: ${message}`);
    } catch (e) {
      this.log('toast failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // 点设备行（发现页 / 已连接列表 / 抽屉）→ 回到该设备的「功能页」（设备信息 + 大按钮）。
  // 未连接的设备（如发现页里离线条目）只提示离线，不改分区，避免落到一个空的详情页。
  private openDeviceDetail(d: DeviceItem): void {
    const online: boolean = this.connectedDevices.some((x: DeviceItem) => x.id === d.id);
    if (!online) {
      this.toastText(this.resText($r('app.string.device_offline').id));
      return;
    }
    this.selectedDeviceId = d.id;
    this.pruneActionGate();   // P2-1①：选设备时清过期限频键
    this.deviceSection = 0;
    this.log(`open device detail: ${d.id}`);
  }

  private toPayloadDirection(v: string): PayloadDirection {
    return v === 'send' ? 'send' : 'receive';
  }

  private toPayloadState(v: string): PayloadState {
    if (v === 'started') {
      return 'started';
    }
    if (v === 'progress') {
      return 'progress';
    }
    if (v === 'finished') {
      return 'finished';
    }
    if (v === 'cancelled') {
      return 'cancelled';
    }
    return 'failed';
  }

  // AP-2：payloadTransfer 事件 → 传输列表 upsert（进度事件 ≤10Hz，不逐条写日志）
  // 终态兜底（omp MSG23/24 契约）：控制连接断开 / Error 事件 ⇒ 该设备「进行中」的接收传输
  // 不可能再完成，立即落为 failed，避免 UI 永久显示「接收中」（用户实测问题）。
  // 说明：native 侧 `135547b` 起 payload FSM 会给出 `code=`/`msg=`，但 `payloadTransfer`
  // 终态事件未必到达；本兜底只改 ArkTS 的展示状态，不动任何传输语义。
  private failInflightReceives(deviceId: string, reason: string): void {
    // P3-1（AtomCode 评审 / CodeArts MSG18）：deviceId 为空时**直接跳过** ——
    // 否则会把所有设备的进行中接收无条件落 failed（Error 事件可能不带 deviceId）。
    if (deviceId.length === 0) {
      return;
    }
    let changed: boolean = false;
    const next: PayloadTransfer[] = this.payloads.map((p: PayloadTransfer): PayloadTransfer => {
      const active: boolean = p.state === 'started' || p.state === 'progress';
      if (p.direction !== 'receive' || !active) {
        return p;
      }
      if (deviceId.length > 0 && p.deviceId !== deviceId) {
        return p;
      }
      changed = true;
      const failed: PayloadTransfer = {
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: 'failed',
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: p.settled
      };
      return failed;
    });
    if (changed) {
      this.payloads = next;
      console.info(`KDC payload inflight -> failed (${reason}) dev=${deviceId.substring(0, 8)}`);
    }
  }

  private handlePayloadTransfer(event: NetEvent): void {
    const tid: number = event.payloadTransferId ?? 0;
    const size: number = event.payloadSize ?? 0;
    // 层间契约（omp MSG23 §4）：`payloadSize > 0` 且 `payloadTransferId == 0` = 「**已宣告但未启动**」
    // （native 侧启动门槛未通过：未信任 / port 缺失 / deviceId 未知 / 帧无 payload 信息）。
    // ⇒ **不得**据 payloadSize 建「接收中」条目，否则会出现永久悬挂（用户实测的「一直接收中」）。
    // native 侧 `135547b` 起会为这种情况派发 Error 事件（"payload not started (why)"），此处只留痕。
    if (tid <= 0) {
      if (size > 0) {
        console.info(`KDC payload declared but not started: size=${size} dev=${(event.deviceId ?? '').substring(0, 8)} (no entry created)`);
      }
      return;
    }
    const state: PayloadState = this.toPayloadState(event.payloadState ?? 'failed');
    const idx: number = this.payloads.findIndex((p: PayloadTransfer) => p.transferId === tid);
    const settled: boolean = idx >= 0 ? this.payloads[idx].settled : false;
    const item: PayloadTransfer = {
      transferId: tid,
      deviceId: event.deviceId ?? '',
      direction: this.toPayloadDirection(event.payloadDirection ?? 'receive'),
      state: state,
      fileName: event.payloadFileName ?? (idx >= 0 ? this.payloads[idx].fileName : ''),
      size: event.payloadSize ?? (idx >= 0 ? this.payloads[idx].size : 0),
      bytesDone: event.payloadBytesDone ?? 0,
      filePath: event.payloadFilePath ?? (idx >= 0 ? this.payloads[idx].filePath : ''),
      settled: settled
    };
    if (idx >= 0) {
      this.payloads = this.payloads.map((p: PayloadTransfer) => p.transferId === tid ? item : p);
    } else {
      this.payloads = [item].concat(this.payloads);
    }
    if (state !== 'progress') {
      this.log(`payload ${state} ${item.direction} #${tid} ${item.fileName}`);
    }
    // 终态记录写入历史（内存 + Preferences），**收发都存**，供跨重启在文件页/「已接收」弹窗查看
    // （2026-09-17：原先只存 receive ⇒ 发送记录重启即丢，用户实测"历史里只剩一条"）
    if (state === 'finished' || state === 'failed' || state === 'cancelled') {
      // 多选发送队列：本批次当前文件到达终态 ⇒ 结算并泵下一个（"串行"的真正落点，见 pumpSendQueue）
      this.onSendPayloadSettled(tid, state, event.errorCode !== undefined ? event.errorCode : 0);
      // 终态记时间（详情弹窗展示"什么时间传过来的"）
      item.timeMs = Date.now();
      this.putReceivedHistory(item);
    }
    // 计划 A（用户/AtomCode 现象② 裁决）：接收完成**自动落盘 + 明确通知**，
    // 不再要求用户到文件页手动点「保存」；授权被拒/失败时给可操作提示（文件页仍可手动保存）。
    if (state === 'finished' && item.direction === 'receive' && !item.settled && item.filePath.length > 0) {
      this.log(`auto-save received #${tid} ${item.fileName}`);
      this.savePayload(item).then((): void => {
        // 通知已在 savePayload 内部发出
      }).catch((e: Error): void => {
        this.log('auto-save failed: ' + e.message);
      });
    }
  }

  // 接收文件的落盘目录：应用沙箱 files/kdeconnect（M1 无需额外存储权限）
  private ensureKdcDir(): string {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return '';
    }
    const dir: string = hostCtx.filesDir + '/kdeconnect';
    try {
      fileIo.mkdirSync(dir);
    } catch (e) {
      // 已存在（EEXIST）忽略
    }
    return dir;
  }

  // 文件名白名单清洗（CodeArts MSG58 §4）：native 的 settle() 只拦 ".."，
  // 这里再去掉路径分隔符/前导点、限长，避免写入意外路径或隐藏文件。
  // P3-11：本方法与 PayloadHistory.safeFileName 是**同一套规则**（历史上各写了一份，存在漂移风险）。
  // 现在只做**转发**，规则本体只保留一份（含控制字符过滤），保证"落库名"与"沙箱名"永远一致。
  private sanitizeFileName(raw: string, transferId: number): string {
    return PayloadHistory.safeFileName(raw, transferId);
  }

  // 「查看已接收」弹窗的数据与展示辅助（文件页入口触发）
  // 列表 = 本次会话的接收记录 ∪ 持久化历史（同 transferId 以内存为准），按 transferId 倒序（新的在前）
  private receivedFiles(): PayloadTransfer[] {
    const merged: PayloadTransfer[] = [];
    for (const p of this.payloads) {
      if (p.direction === 'receive') {
        merged.push(p);
      }
    }
    for (const h of this.receivedHistory) {
      if (!merged.some((m: PayloadTransfer) => m.transferId === h.transferId)) {
        merged.push(h);
      }
    }
    return merged.sort((a: PayloadTransfer, b: PayloadTransfer) => b.transferId - a.transferId);
  }

  // 终态接收记录入库（内存 + Preferences；写失败不影响主流程）
  private putReceivedHistory(item: PayloadTransfer): void {
    const exists: boolean = this.receivedHistory.some((h: PayloadTransfer) => h.transferId === item.transferId);
    this.receivedHistory = exists
      ? this.receivedHistory.map((h: PayloadTransfer) => h.transferId === item.transferId ? item : h)
      : [item].concat(this.receivedHistory);
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      PayloadHistory.save(hostCtx, this.receivedHistory).catch((e: Error): void => {
        this.log('payload history save failed: ' + e.message);
      });
    }
  }

  // 「清除历史」：清掉已结束的接收记录（内存 + 持久化），进行中的传输保留
  private clearReceivedHistory(): void {
    this.receivedHistory = [];
    this.payloads = this.payloads.filter((p: PayloadTransfer) =>
      p.direction !== 'receive' || p.state === 'started' || p.state === 'progress');
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      PayloadHistory.clear(hostCtx).catch((e: Error): void => {
        this.log('payload history clear failed: ' + e.message);
      });
    }
    this.log('received file history cleared');
    this.toastText(this.resText($r('app.string.toast_history_cleared').id));
  }

  private fmtBytes(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  // 状态文案（裁定表 #14，DevEco 独有采纳；口径必须与 components/PayloadRow.ets 一致，改一处要改两处）：
  //   进行中：发送 = 发送中 / 接收 = 接收中（旧实现不分方向，发送中也被写成"接收中"）
  //   完成：  发送 = 已发送 / 接收 = 已保存（已处置）或 已完成；失败/取消两方向同词
  private payloadStateText(p: PayloadTransfer): string {
    const send: boolean = p.direction === 'send';
    if (p.state === 'started' || p.state === 'progress') {
      return this.resText(send ? $r('app.string.files_sending').id : $r('app.string.files_receiving').id);
    }
    if (p.state === 'finished') {
      if (send) {
        return this.resText($r('app.string.files_sent').id);
      }
      return this.resText(p.settled ? $r('app.string.files_saved').id : $r('app.string.files_finished').id);
    }
    return this.resText(p.state === 'failed' ? $r('app.string.files_failed').id : $r('app.string.files_cancelled').id);
  }

  private markPayloadSettled(transferId: number): void {
    this.payloads = this.payloads.map((p: PayloadTransfer) => {
      const next: PayloadTransfer = {
        transferId: p.transferId,
        deviceId: p.deviceId,
        direction: p.direction,
        state: p.state,
        fileName: p.fileName,
        size: p.size,
        bytesDone: p.bytesDone,
        filePath: p.filePath,
        settled: true
      };
      return p.transferId === transferId ? next : p;
    });
  }

  // 保存接收到的文件。用户反馈「APP 从不请求权限」⇒ 这里按文件类型**运行时申请**对应媒体写权限
  // （user_grant，会弹系统权限框），拿到后再调 native.keepPayload（真实沙箱路径，非 URI）。
  // 详情弹窗用：时间显示（无时间戳给 —）
  private timeTextOf(p: PayloadTransfer): string {
    const t: number = p.timeMs ?? 0;
    if (t <= 0) {
      return '—';
    }
    try {
      return new Date(t).toLocaleString();
    } catch (e) {
      return '—';
    }
  }

  // 「文件详情」弹窗用：按 transferId 取当前条目（找不到给一个只读占位，避免 undefined）
  private payloadDetail(): PayloadTransfer {
    for (const p of this.payloads) {
      if (p.transferId === this.payloadDetailId) {
        return p;
      }
    }
    const placeholder: PayloadTransfer = {
      transferId: this.payloadDetailId,
      deviceId: '',
      direction: 'receive',
      state: 'failed',
      fileName: '',
      size: 0,
      bytesDone: 0,
      filePath: '',
      settled: true
    };
    return placeholder;
  }

  // 「文件详情」弹窗里的属性行（标签 + 值）
  @Builder
  infoLine(label: ResourceStr, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width(84)
      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  // 「另存为」：走系统保存面板（用户自选目录，如「下载」）⇒ 保存后在文件管理里可见。
  // 源文件优先用 spool（filePath），否则用沙箱里已保存的副本。
  private async saveAsPayload(p: PayloadTransfer): Promise<void> {
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    let destUri: string = '';
    try {
      const pk: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const uris: string[] = await pk.save({ newFileNames: [name] });
      destUri = uris.length > 0 ? uris[0] : '';
    } catch (e) {
      this.log('save as: picker failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return;
    }
    if (destUri.length === 0) {
      return;
    }
    // 源：优先沙箱副本（本地已有，可靠性最高），其次 spool
    const sandboxCopy: string = `${this.ensureKdcDir()}/${name}`;
    let src: string = sandboxCopy;
    if (p.filePath.length > 0 && !fileIo.accessSync(sandboxCopy)) {
      src = p.filePath;
    }
    let srcFd: fileIo.File | undefined = undefined;
    let dstFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      dstFd = fileIo.openSync(destUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFd.fd, dstFd.fd);
      this.log(`save as -> ${destUri}`);
      this.toastText(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
      this.payloadDetailOpen = false;
    } catch (e) {
      this.log('save as: copy failed: ' + (e instanceof Error ? e.message : 'unknown'));
      this.toastText(this.resText($r('app.string.files_save_failed').id));
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e2) {
          // ignore
        }
      }
      if (dstFd !== undefined) {
        try {
          fileIo.closeSync(dstFd);
        } catch (e3) {
          // ignore
        }
      }
    }
  }

  private async savePayload(p: PayloadTransfer): Promise<void> {
    const dir: string = this.ensureKdcDir();
    if (dir === '') {
      this.log('save failed: no host context');
      this.toastText(this.resText($r('app.string.files_save_failed').id));
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const dest: string = `${dir}/${name}`;
    // 保留写权限申请（用户 2026-09-17 裁决：另存为/导出到公共目录时仍需要它）
    const granted: boolean = await this.ensureWritePermission(name);
    if (!granted) {
      this.log(`save aborted: write permission denied for ${name}`);
      this.toastText(this.resText($r('app.string.files_need_permission').id));
      return;
    }
    // 先在沙箱落一份（本地副本）：① 保证文件不丢；② 它是「另存为」的来源（spool 会被消费掉）
    let sandboxOk: boolean = false;
    try {
      sandboxOk = native.keepPayload(p.transferId, dest);
      this.log(sandboxOk ? `saved(sandbox) -> ${dest}` : 'keepPayload failed');
    } catch (e) {
      this.log('keepPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    // 再尝试导出到**文件管理可见**的公共下载目录（官方 DOWNLOAD 模式）
    const exported: string = await this.exportToDownloads(p, name, dest);
    if (exported.length > 0) {
      this.log(`exported to public dir -> ${exported}`);
      this.markPayloadSettled(p.transferId);
      this.toastText(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
      return;
    }
    if (sandboxOk) {
      this.markPayloadSettled(p.transferId);
      this.toastText(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
      return;
    }
    this.toastText(this.resText($r('app.string.files_save_failed').id));
  }

  // 把接收文件导出到公共下载目录（文件管理可见），成功返回目标 URI；失败返回空串。
  // srcPath 是**沙箱内的副本**（keepPayload 之后 spool 已被消费，不能再当源）。
  private async exportToDownloads(p: PayloadTransfer, name: string, srcPath: string): Promise<string> {
    // 源优先用沙箱副本（keepPayload 之后 spool 已被消费），不存在时退回 spool
    let src: string = srcPath;
    if (src.length === 0) {
      src = p.filePath;
    }
    if (src.length === 0) {
      return '';
    }
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      return '';
    }
    let destUri: string = '';
    try {
      const picker0: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const opts: picker.DocumentSaveOptions = {
        newFileNames: [name],
        pickerMode: picker.DocumentPickerMode.DOWNLOAD
      };
      const uris: string[] = await picker0.save(opts);
      destUri = uris.length > 0 ? uris[0] : '';
    } catch (e) {
      this.log('export: save picker(DOWNLOAD) failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    }
    if (destUri.length === 0) {
      return '';
    }
    let srcFd: fileIo.File | undefined = undefined;
    let dstFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      dstFd = fileIo.openSync(destUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFd.fd, dstFd.fd);
      fileIo.closeSync(srcFd);
      srcFd = undefined;
      fileIo.closeSync(dstFd);
      dstFd = undefined;
      // 保留沙箱副本（供「另存为」再次导出），不丢弃 spool
      this.markPayloadSettled(p.transferId);
      return destUri;
    } catch (e) {
      this.log('export: copy failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return '';
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e3) {
          // ignore
        }
      }
      if (dstFd !== undefined) {
        try {
          fileIo.closeSync(dstFd);
        } catch (e4) {
          // ignore
        }
      }
    }
  }

  // 按扩展名映射需要申请的写入权限（无匹配则不需要权限 → 直接放行）
  private writePermissionFor(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    const imageVideo: string[] = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.mp4', '.mov', '.mkv', '.webm', '.3gp'];
    const audio: string[] = ['.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.opus', '.amr'];
    for (const ext of imageVideo) {
      if (lower.endsWith(ext)) {
        return 'ohos.permission.WRITE_IMAGEVIDEO';
      }
    }
    for (const ext of audio) {
      if (lower.endsWith(ext)) {
        return 'ohos.permission.WRITE_AUDIO';
      }
    }
    return '';
  }

  private async ensureWritePermission(fileName: string): Promise<boolean> {
    const permName: string = this.writePermissionFor(fileName);
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
      this.log(`permission ${permName}: granted=${granted}`);
      return granted;
    } catch (e) {
      this.log('permission request failed: ' + (e instanceof Error ? e.message : 'unknown'));
      // 申请失败（如模拟器不支持）不阻断保存，交给 keepPayload 自行判定
      return true;
    }
  }

  private discardPayload(p: PayloadTransfer): void {
    // 排查埋点（用户实测"丢弃没反应"）：hilog 可见每一步走到哪
    console.info(`KDC discard start #${p.transferId} name=${p.fileName} before=${this.payloads.length}/${this.receivedHistory.length}`);
    try {
      const ok: boolean = native.discardPayload(p.transferId);
      this.log(ok ? `discarded #${p.transferId}` : 'discardPayload failed');
    } catch (e) {
      this.log('discardPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    // 用户要求（2026-09-17）：丢弃 = 从沙箱删除 + 同时从**历史记录列表**里移除（并持久化）
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const sandboxCopy: string = `${this.ensureKdcDir()}/${name}`;
    try {
      if (fileIo.accessSync(sandboxCopy)) {
        fileIo.unlinkSync(sandboxCopy);
        this.log(`unlink sandbox copy -> ${sandboxCopy}`);
      }
    } catch (e2) {
      this.log('unlink sandbox copy failed: ' + (e2 instanceof Error ? e2.message : 'unknown'));
    }
    this.payloads = this.payloads.filter((x: PayloadTransfer) => x.transferId !== p.transferId);
    this.receivedHistory = this.receivedHistory.filter((h: PayloadTransfer) => h.transferId !== p.transferId);
    console.info(`KDC discard done #${p.transferId} after=${this.payloads.length}/${this.receivedHistory.length}`);
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      PayloadHistory.save(hostCtx, this.receivedHistory).catch((e3: Error): void => {
        this.log('history save after discard failed: ' + e3.message);
      });
    }
  }

  private cancelPayload(p: PayloadTransfer): void {
    try {
      native.cancelPayload(p.transferId);
      this.log(`payload cancel requested #${p.transferId}`);
    } catch (e) {
      this.log('cancelPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  // M2：选文件 → 复制进沙箱 → 入队 → 串行下发（发送方向；进度走 payloadTransfer）。
  // 多选（用户 2026-09-18 拍板 / CodeArts MSG19 §3 放行）：一次最多 MAX_PICK_FILES 个，**串行**：
  //   · 选中后**先把每个文件复制进沙箱**（picker 的 URI 授权是临时的，先落地更稳），再逐个入队；
  //   · 真正的串行由 pumpSendQueue() + payload 终态事件驱动（见 handlePayloadTransfer），
  //     **不用固定间隔 sleep** —— 那是时间猜测，无法保证"不并发抢 payload 通道"。
  //   · 沙箱副本名加 `send_<批次时间戳>_<序号>_` 前缀：避免同批次内**同名文件**互相覆盖，也避免
  //     覆盖上一个仍在流式传输中的文件。副本留在 cacheDir（应用缓存目录，系统可在空间紧张时回收）。
  // 发送目标设备（**修复用户实测的「换了 win10dev 却发到 cachyos」**；CodeArts MSG45 §1 授权）：
  // 旧实现写死 `connectedDevices[0]` = 永远第一台连接的设备，与用户选中的设备无关。
  // 语义：发送卡片属于"当前选中设备"的详情页；文件页的发送也以选中设备为准。
  // 只有"恰好一台在线"才允许无歧义地自动选它，其余**不猜**、提示用户先选设备。
  private sendTargetDevice(): DeviceItem | undefined {
    const id: string = this.selectedDeviceId;
    if (id.length > 0) {
      for (const d of this.connectedDevices) {
        if (d.id === id) {
          return d;
        }
      }
    }
    if (this.connectedDevices.length === 1) {
      return this.connectedDevices[0];
    }
    return undefined;
  }

  private async pickAndSendFile(): Promise<void> {
    if (this.connectedDevices.length === 0) {
      this.log('send file: no connected device');
      return;
    }
    const target: DeviceItem | undefined = this.sendTargetDevice();
    if (target === undefined) {
      this.log(`send file: no unambiguous target (selected='${this.selectedDeviceId}' connected=${this.connectedDevices.length})`);
      this.toastText(this.resText($r('app.string.toast_send_no_target').id));
      return;
    }
    this.log(`send file target: ${target.name} (${target.id.substring(0, 8)})`);
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.log('send file: no host context');
      return;
    }
    let uris: string[] = [];
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const options: picker.DocumentSelectOptions = { maxSelectNumber: MAX_PICK_FILES };
      uris = await docPicker.select(options);
    } catch (e) {
      this.log('send file: picker cancelled/failed');
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const batchTs: number = Date.now();
    const jobs: SendJob[] = [];
    for (let i = 0; i < uris.length; i++) {
      const job: SendJob | undefined = this.stageSendJob(hostCtx, uris[i], batchTs, i);
      if (job !== undefined) {
        jobs.push(job);
      }
    }
    if (jobs.length === 0) {
      this.toastText(this.resText($r('app.string.toast_send_file_failed').id));
      return;
    }
    // 入队（允许与上一批排队：pumpSendQueue 会等当前传输结束再继续）
    this.sendTarget = target.id;
    this.sendTotal += jobs.length;
    for (const j of jobs) {
      this.sendQueue.push(j);
    }
    this.log(`send file batch queued: ${jobs.length} (queue=${this.sendQueue.length}) -> ${target.name}`);
    this.pumpSendQueue();
  }

  // 把 picker 返回的一个 URI 复制进沙箱，成功则返回可下发的任务
  private stageSendJob(ctx: Context, srcUri: string, batchTs: number, seq: number): SendJob | undefined {
    let fileName: string = srcUri.substring(srcUri.lastIndexOf('/') + 1);
    try {
      fileName = decodeURIComponent(fileName);
    } catch (e) {
      // URI 未编码时 decodeURIComponent 会抛；忽略，沿用原名
    }
    const cachePath: string = `${ctx.cacheDir}/send_${batchTs}_${seq}_${fileName}`;
    // picker 返回的是 URI：必须经 fd 读，直接 copyFile(uri, path) 会失败（实测 "copy into sandbox failed"）。
    let srcFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(srcFd.fd, cachePath);
    } catch (e) {
      this.log(`send file: copy into sandbox failed (${fileName}): `
        + (e instanceof Error ? e.message : 'unknown'));
      return undefined;
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e) {
          // 忽略关闭失败
        }
      }
    }
    const job: SendJob = { cachePath: cachePath, fileName: fileName };
    return job;
  }

  // 队列泵：空闲时才发队首；**下一个文件由上一个 payload 的终态事件驱动**（见 handlePayloadTransfer）
  private pumpSendQueue(): void {
    if (this.sendBusyId >= 0 || this.sendQueue.length === 0) {
      return;
    }
    // 双保险之二（P3）：入口校验目标仍在线 —— 断链事件可能晚于入队、或晚于上一个终态事件，
    // 一律不对离线设备继续下发（清空并返回，不递归）。
    if (!this.connectedDevices.some((d: DeviceItem) => d.id === this.sendTarget)) {
      this.forgetSendQueue(this.sendTarget);
      return;
    }
    // 注意：**不 shift** —— 队首任务的"归属"一直保留到它的终态事件（onSendPayloadSettled 里结算/重试），
    // 这样失败重试才能把它放回队首，而不是重新走一遍复制沙箱。
    const job: SendJob = this.sendQueue[0];
    try {
      const body: SendShareBody = { filename: job.fileName };
      const tid: number = native.sendPayload(this.sendTarget, 'kdeconnect.share.request',
        JSON.stringify(body), job.cachePath);
      if (tid > 0) {
        this.sendBusyId = tid;
        this.sendInflightJob = job;
        this.log(`send file #${tid}: ${job.fileName} (queued=${this.sendQueue.length})`);
        return;
      }
      this.log(`send file: sendPayload returned 0 (${job.fileName})`);
    } catch (e) {
      this.log(`sendPayload error (${job.fileName}): ` + (e instanceof Error ? e.message : 'unknown'));
    }
    // 连"下发"都没成功（同步失败）：丢弃该文件，继续泵下一个（不阻塞整批）
    this.sendQueue.shift();
    this.pumpSendQueue();
  }

  // 断链时清空发送队列（P3）。只清"发给该设备"的批次：断的是别的设备时不影响当前批次。
  // 双保险之一（另一个在 pumpSendQueue 入口做在线校验）—— 队列不能对着离线设备继续发。
  private forgetSendQueue(deviceId: string): void {
    if (deviceId.length === 0 || this.sendTarget !== deviceId) {
      return;
    }
    const dropped: number = this.sendQueue.length + (this.sendBusyId >= 0 ? 1 : 0);
    this.sendQueue = [];
    this.sendBusyId = -1;
    this.sendInflightJob = undefined;
    this.sendTarget = '';
    this.sendOkCount = 0;
    this.sendTotal = 0;
    this.log(`send queue cleared on disconnect (dropped=${dropped})`);
  }

  // 当前批次是否有文件在传（供 payload 终态回调判断"该不该继续泵"）
  private onSendPayloadSettled(transferId: number, state: PayloadState, code: number): void {
    if (transferId !== this.sendBusyId) {
      return;   // 不是本队列在传的那一个（例如接收方向、或历史条目）
    }
    const job: SendJob | undefined = this.sendInflightJob;
    this.sendBusyId = -1;
    this.sendInflightJob = undefined;
    // 队首恒为这一个（pump 时不 shift）⇒ 在这里结算：成功/最终失败都移出队列，重试则放回队首
    if (this.sendQueue.length > 0) {
      this.sendQueue.shift();
    }
    if (state === 'finished') {
      this.sendOkCount++;
      this.log(`send file done: ${job !== undefined ? job.fileName : '?'} (${this.sendOkCount}/${this.sendTotal})`);
    } else {
      this.log(`send file failed: ${job !== undefined ? job.fileName : '?'} state=${state} code=${code}`);
    }
    // 裁定表 #15（合并裁定）：code=110「兜底重试一次」已撤除——Omp MSG38 判断：阶段未定位前
    // 加重试会把真因掩盖成偶发。恢复条件：native 阶段诊断（46c55d4）的复跑数据定位后，
    // 若确认是「对端尚未就绪」的固有窗口，再以**有界**重试回归并如实计数。
    this.pumpSendQueue();
    if (this.sendBusyId < 0 && this.sendQueue.length === 0 && this.sendTotal > 0) {
      // 整批结束：一条汇总提示（CodeArts MSG19 §3：「逐条 toast 或一条汇总」——取后者，避免刷屏）
      const head: string = this.resText($r('app.string.toast_send_batch_done').id);
      this.toastText(`${head} (${this.sendOkCount}/${this.sendTotal})`);
      this.log(`send file batch done: ${this.sendOkCount}/${this.sendTotal}`);
      this.sendOkCount = 0;
      this.sendTotal = 0;
    }
  }

  private log(line: string): void {
    // 缓冲与文本都在 LogStore 里（批3 #1）：这里只负责"什么时候 flush"
    this.logStore.append(line);
    // 合并刷新：窗口内的多条日志攒成一次写入，避免日志频率直接驱动刷新频率。
    // P2（MSG145 §2 P2-2）：原实现让「低频期首条」也要等满 900ms（用户体感：卡一下才出日志）。
    // 改为动态窗：距上次 flush 已空闲 ≥900ms ⇒ 视为新批次，100ms 短窗让首条尽快出现；
    // 高频期（距上次 flush <900ms）保持 900ms 节拍不变 —— 即**不会**退回「逐条渲染」。
    if (this.logFlushTimer < 0) {
      const idleMs: number = Date.now() - this.logLastFlushMs;
      const waitMs: number = idleMs >= 900 ? 100 : 900;
      this.logFlushTimer = setTimeout((): void => {
        this.logFlushTimer = -1;
        this.flushLog();
      }, waitMs);
    }
  }

  private flushLog(): void {
    if (this.logStore.isEmpty()) {
      return;
    }
    // ARKTS_ANALYSIS §8-A、批3 #1：日志页不可见时不 flush。
    // 写 LogStore 只会重建 LogsTab（不再整页重建），所以这**已不是正确性要求**，只是省 CPU；
    // 切回日志页时由 tabs onChange 补一次 flush（否则期间攒的行要等下一次日志才出现）。
    if (this.currentTab !== 3) {
      return;
    }
    this.logStore.flush();
    this.logLastFlushMs = Date.now();
    // 开屏卡顿排查（MSG8 §4 问题 1/#1）：每次 flushLog 都会写 @State logText ⇒ 触发一次整页重建。
    // 这里计数并在首屏窗口内打印，用来量化「开屏期日志驱动的重建次数」。build() 里不能写任意语句，
    // 所以计数放在这个真正触发重建的点上。
    this.logFlushCount++;
    if (this.logFlushCount <= 3 || this.logFlushCount % 50 === 0) {
      console.info(`KDC logflush #${this.logFlushCount} @${Date.now()}`);
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
    this.deviceSection = index;
    this.closeDrawer();
  }

  private isPairedId(deviceId: string): boolean {
    return this.rememberedDevices.some((r: RememberedDevice) => r.id === deviceId && r.paired);
  }

  // 「已连接设备」分区只展示选中设备的详情/功能页：默认自动选中第一台已连接设备；
  // 连接断开或选中设备不在列表里时重新收口（没有已连接设备则清空选中 → 页面给选设备提示）
  private syncSelectedDevice(): void {
    const live: DeviceItem[] = this.connectedShown();
    if (live.length === 0) {
      // 功能卡片规则（【根治】，CodeArts MSG6 §3 裁决 / MSG13 §3-2）：
      // 设备**短暂离线**（抖动/重连）时**保留**已配对设备的详情页 —— 只有两种情况才收起：
      //   ① 用户主动切换/取消选中；② 该设备被解除配对（paired=false）。
      // 这样连接的抖动不会再让"功能卡片闪一下就没"。
      if (this.selectedDeviceId.length > 0 && this.isPairedId(this.selectedDeviceId)) {
        return;
      }
      this.selectedDeviceId = '';
      return;
    }
    const stillThere: boolean = live.some((d: DeviceItem) => d.id === this.selectedDeviceId);
    if (!stillThere) {
      this.selectedDeviceId = live[0].id;
      this.deviceSection = 0;
    }
  }

  // ---- 三态互斥列表（用户 2026-09-14 规则，对齐蓝牙/星闪的已知设备模型）----
  // 已连接 = 已配对且在线；发现 = 未配对且在线（实时连接 ∪ 广播发现）；记住的设备 = 已知
  // （配对过或曾经连接过）但当前离线。**同一设备只会出现在其中一个列表**；三个列表前的
  // 状态灯颜色也不同（已连接=绿 / 发现=蓝 / 记住=离线灰）。
  private liveIds(): string[] {
    const out: string[] = [];
    for (const d of this.connectedDevices) {
      if (d.online) {
        out.push(d.id);
      }
    }
    return out;
  }

  private connectedShown(): DeviceItem[] {
    const out: DeviceItem[] = [];
    for (const d of this.connectedDevices) {
      if (d.online && this.isPairedId(d.id)) {
        out.push(d);
      }
    }
    return out;
  }

  private discoveredShown(): DeviceItem[] {
    const out: DeviceItem[] = [];
    for (const d of this.connectedDevices) {
      // 已连接但未配对：仍算「发现」（配对入口在发现列表），配对成功后自然转入已连接
      if (d.online && !this.isPairedId(d.id) && !out.some((x: DeviceItem) => x.id === d.id)) {
        out.push(d);
      }
    }
    for (const d of this.discoveredDevices) {
      if (d.online && !this.isPairedId(d.id) && !out.some((x: DeviceItem) => x.id === d.id)) {
        out.push(d);
      }
    }
    return out;
  }

  private offlineKnownShown(): RememberedDevice[] {
    const live: string[] = this.liveIds();
    const out: RememberedDevice[] = [];
    for (const r of this.rememberedDevices) {
      if (!live.includes(r.id)) {
        out.push(r);
      }
    }
    return out;
  }

  // 「曾经连接过」的设备写入已知设备表（paired 标记保持原值；未配对设备也记住 ⇒
  // 断链后进「记住的设备」列表，与蓝牙/星闪一致：连过的设备不会凭空消失）
  private rememberKnown(id: string, name: string): void {
    if (id === '') {
      return;
    }
    // 信任表尚未加载完成 → 先排队（防止用空表覆写持久化数据）
    if (!this.trustLoaded) {
      const pending: TrustedDevice = { id: id, name: name, certPem: '', pairedAt: 0, paired: false };
      this.pendingKnown = this.pendingKnown.concat([pending]);
      return;
    }
    const existing: TrustedDevice | undefined = this.trustedDevices.find((t: TrustedDevice) => t.id === id);
    if (existing !== undefined) {
      if (name.length > 0 && existing.name !== name) {
        this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
          if (t.id !== id) {
            return t;
          }
          const next: TrustedDevice = {
            id: t.id,
            name: name,
            certPem: t.certPem,
            pairedAt: t.pairedAt,
            paired: t.paired
          };
          return next;
        });
        this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
          const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
          return r;
        });
        this.persistTrust();
      }
      return;
    }
    const entry: TrustedDevice = {
      id: id,
      name: name.length > 0 ? name : id,
      certPem: '',
      pairedAt: 0,
      paired: false
    };
    this.trustedDevices = this.trustedDevices.concat([entry]);
    this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
      return r;
    });
    this.persistTrust();
    this.log(`remember known device ${id} (connected once)`);
  }

  @Builder
  drawerOverlay() {
    // 合并裁定 #13：设备抽屉抽为 DrawerOverlay 组件（来自 AtomCode 副本）——
    // 页面只传派生列表与回调，UI/交互细节收敛到组件内。
    DrawerOverlay({
      connectedList: this.connectedShown(),
      discoveredList: this.discoveredShown(),
      rememberedCount: this.offlineKnownShown().length,
      selectedDeviceId: this.selectedDeviceId,
      requestedPairIds: this.pairSession.requestedPeers,
      deviceSection: this.deviceSection,
      drawerExpanded: this.drawerExpanded,
      onClose: (): void => {
        this.closeDrawer();
      },
      onOpenDevice: (d: DeviceItem): void => {
        this.openDeviceDetail(d);
        this.closeDrawer();
      },
      onPairRequest: (d: DeviceItem): void => {
        this.requestPairWith(d);
        this.closeDrawer();
      },
      onPickSection: (index: number): void => {
        this.pickDrawerSection(index);
      },
      isPaired: (deviceId: string): boolean => {
        return this.isPairedId(deviceId);
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
                connectedDevices: this.connectedShown(),
                discoveredDevices: this.discoveredShown(),
                rememberedDevices: this.offlineKnownShown(),
                rememberedAll: this.rememberedDevices,
                immersive: this.immersiveSupported,
                sideBySide: this.sideBySide,
                requestedPairIds: this.pairSession.requestedPeers,
                batteryItems: this.batteryItems,
                deviceSection: this.deviceSection,
                onUnpairDevice: (d: DeviceItem): void => {
                  this.unpairDevice(d);
                },
                onManualConnect: (host: string, port: number): void => {
                  this.manualConnect(host, port);
                },
                selectedDeviceId: this.selectedDeviceId,
                onPlaceholderAction: (key: string): void => {
                  // 走卡片忙碌态入口（【补丁·待优化】，视觉无变化）
                  this.runCardAction(key);
                },
                // 发送文件卡内按钮 = 文件页「选择文件并发送」同一动作
                onSendFilePick: (): void => {
                  this.pickAndSendFile();
                },
                onOpenDevice: (d: DeviceItem): void => {
                  this.openDeviceDetail(d);
                },
                onClipboardPaste: (granted: boolean): void => {
                  this.onClipboardPasteResult(granted);
                },
                onClipboardRequest: (): void => {
                  this.onDeviceAction('clipboard_request');
                },
                onRefreshDiscovery: (): void => {
                  this.triggerDiscoveryBroadcast();
                },
                onPairDevice: (d: DeviceItem): void => {
                  this.requestPairWith(d);
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
                    connectedCount: this.connectedDevices.length,
                    immersive: this.immersiveSupported,
                    payloads: this.payloads,
                    onSavePayload: (p: PayloadTransfer): void => {
                      this.savePayload(p);
                    },
                    onDiscardPayload: (p: PayloadTransfer): void => {
                      this.discardPayload(p);
                    },
                    onCancelPayload: (p: PayloadTransfer): void => {
                      this.cancelPayload(p);
                    },
                    onSendFile: (): void => {
                      this.pickAndSendFile();
                    },
                    onOpenReceivedFiles: (): void => {
                      this.receivedDialogOpen = true;
                    },
                    onOpenPayload: (tid: number): void => {
                      this.payloadDetailId = tid;
                      this.payloadDetailOpen = true;
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
                deviceName: this.deviceName,
                systemName: this.systemName,
                statusText: this.status,
                themeMode: this.themeMode,
                language: this.language,
                immersive: this.immersiveSupported,
                onRenameDevice: (name: string): void => {
                  this.renameDevice(name);
                },
                onUseSystemName: (): void => {
                  this.useSystemDeviceName();
                },
                onThemeChange: (mode: number): void => {
                  this.applyTheme(mode, true);
                },
                onLanguageChange: (lang: string): void => {
                  this.applyLanguage(lang, true);
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
                  logStore: this.logStore,
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
            this.flushLog();
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
      // 显示验证码，两端核对一致后确认 → 配对成功
      if (this.pairSession.stage === 'prompt' || this.pairSession.stage === 'awaiting') {
        Column() {
          Column({ space: 14 }) {
            Text(this.pairSession.peerRequested
              ? $r('app.string.pair_dialog_title')
              : $r('app.string.pair_dialog_title_outgoing'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.pairSession.peerName)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 设备 ID 在弹窗里核对（列表里只显示 IP:端口，用户 2026-09-14）
            if (this.pairSession.deviceId.length > 0) {
              Text(`${this.resText($r('app.string.settings_device_id').id)}: ${this.pairSession.deviceId}`)
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
                .fontFamily('monospace')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            Column({ space: 4 }) {
              Text($r('app.string.pair_dialog_code_label'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
              Text(this.pairSession.code.length > 0 ? this.pairSession.code : '-- -- -- --')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.accent_text'))
                .fontFamily('monospace')
              if (this.pairSession.code.length === 0) {
                Text($r('app.string.pair_code_unavailable'))
                  .fontSize(10)
                  .fontColor($r('app.color.text_muted'))
              }
            }
            Text($r('app.string.pair_dialog_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
            if (this.pairSession.stage === 'awaiting') {
              Text($r('app.string.pair_waiting'))
                .fontSize(12)
                .fontColor($r('app.color.accent_text'))
                .textAlign(TextAlign.Center)
              Text($r('app.string.pair_waiting_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
            }
            Row({ space: 10 }) {
              Button(this.pairSession.peerRequested ? $r('app.string.pair_reject') : $r('app.string.action_cancel'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.danger_bg'))
                .fontColor($r('app.color.danger_text'))
                .borderRadius(12)
                .onClick(() => {
                  this.pairSession.cancel();
                })
              if (this.pairSession.stage === 'prompt') {
                Button(this.pairSession.peerRequested ? $r('app.string.pair_accept') : $r('app.string.pair_action'))
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(14)
                  .backgroundColor($r('app.color.accent'))
                  .borderRadius(12)
                  .onClick(() => {
                    this.pairSession.confirm();
                  })
              }
            }
            .width('100%')
          }
          .width('86%')
          .padding(20)
          .borderRadius(20)
          // 弹层不用毛玻璃（手机实测：BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，
          // 叠上面板每秒重绘就把主线程拖死 → THREAD_BLOCK_3S/6S、点击无响应）。用更实的底色替代。
          .backgroundColor($r('app.color.dialog_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.dialog_mask'))
      }

      // 媒体控制面板（P2 方向 1，FEATURE_PLAN_MPRIS §3.3）：控电脑端播放器。
      // 读数一律走 this.mprisXxx() 方法直读 @State（**不用 @Builder 传值**：值参数不变会跳过重建，
      // 会出现「点了图标不变/置灰不刷新」；这是本项目已踩过的坑）。
      if (this.mprisDialogOpen) {
        Column() {
          Column({ space: 12 }) {
            Text($r('app.string.media_dialog_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.displayNameOf(this.mprisDeviceId))
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 两个 tab（用户 2026-09-18 要求）：0=媒体（播放器控制）1=设备（OutputDevice）
            Row({ space: 8 }) {
              Text($r('app.string.media_tab_player'))
                .fontSize(13)
                .fontWeight(this.mprisTab === 0 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.mprisTab === 0 ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(10)
                .backgroundColor(this.mprisTab === 0 ? $r('app.color.accent_soft') : Color.Transparent)
                .onClick(() => {
                  this.mprisTab = 0;
                })
              Text($r('app.string.media_tab_devices'))
                .fontSize(13)
                .fontWeight(this.mprisTab === 1 ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.mprisTab === 1 ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(10)
                .backgroundColor(this.mprisTab === 1 ? $r('app.color.accent_soft') : Color.Transparent)
                .onClick(() => {
                  this.mprisTab = 1;
                })
            }
            .width('100%')
            if (this.mprisTab === 0) {

            if (this.mprisEmpty()) {
              Text($r('app.string.media_empty'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Text($r('app.string.media_empty_hint'))
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
                .textAlign(TextAlign.Center)
            } else {
              // 多播放器：横向 chips 切换（单个时隐藏）
              if (this.mprisList().length > 1) {
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(this.mprisList(), (pl: string) => {
                      Text(mprisPlayerText(pl))
                        .fontSize(11)
                        .fontColor(pl === this.mprisSnap().player
                          ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                        .borderRadius(999)
                        .backgroundColor(pl === this.mprisSnap().player
                          ? $r('app.color.accent_text') : $r('app.color.chip_bg'))
                        .onClick(() => {
                          this.mediaSelectPlayer(pl);
                        })
                    }, (pl: string) => pl)
                  }
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .align(Alignment.Start)
                .width('100%')
              }

              // 曲目信息（封面本期不做：对端封面要走 payload 传输，属规划 Phase 2）
              Row({ space: 12 }) {
                Column() {
                  SymbolGlyph($r('sys.symbol.music_fill'))
                    .fontSize(24)
                    .fontColor([$r('app.color.accent_text')])
                }
                .width(56)
                .height(56)
                .borderRadius(14)
                .backgroundColor($r('app.color.chip_bg'))
                .justifyContent(FlexAlign.Center)

                Column({ space: 4 }) {
                  Text(this.mprisSnap().title.length > 0
                    ? this.mprisSnap().title : $r('app.string.media_unknown_track'))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(this.mprisArtistLine())
                    .fontSize(11)
                    .fontColor($r('app.color.text_muted'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')

              // 进度：批2 根治 —— 抽成 MprisProgress 组件，**插值时钟（1s）落在组件局部 @State**，
              // 面板打开期间不再每秒整页重建（原来 ticker 写页面级 mprisNowMs）。
              MprisProgress({
                lengthMs: this.mprisSnap().length,
                posMs: this.mprisSnap().pos,
                posAtMs: this.mprisSnap().posAt,
                isPlaying: this.mprisSnap().isPlaying,
                canSeek: this.mprisSnap().canSeek,
                onSeek: (ms: number): void => {
                  this.mediaSetPosition(ms);
                }
              })

              // 控制键（按 can* 置灰；播放/暂停统一发 PlayPause，由对端决定方向）
              Row({ space: 20 }) {
                Column() {
                  SymbolGlyph($r('sys.symbol.backward_end_fill'))
                    .fontSize(24)
                    .fontColor([this.mprisSnap().canGoPrevious
                      ? $r('app.color.text_primary') : $r('app.color.text_muted')])
                }
                .width(46)
                .height(46)
                .borderRadius(23)
                .backgroundColor($r('app.color.chip_bg'))
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.mediaAction('previous');
                })

                Column() {
                  SymbolGlyph(this.mprisSnap().isPlaying
                    ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
                    .fontSize(28)
                    .fontColor([$r('app.color.accent_text')])
                }
                .width(58)
                .height(58)
                .borderRadius(29)
                .backgroundColor($r('app.color.chip_bg'))
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.mediaAction('toggle');
                })

                Column() {
                  SymbolGlyph($r('sys.symbol.forward_end_fill'))
                    .fontSize(24)
                    .fontColor([this.mprisSnap().canGoNext
                      ? $r('app.color.text_primary') : $r('app.color.text_muted')])
                }
                .width(46)
                .height(46)
                .borderRadius(23)
                .backgroundColor($r('app.color.chip_bg'))
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.mediaAction('next');
                })
              }

              // 音量（对端未报 volume 时禁用）
              Row({ space: 8 }) {
                SymbolGlyph(this.mprisVol() > 0
                  ? $r('sys.symbol.speaker_wave_3_fill') : $r('sys.symbol.speaker_slash_fill'))
                  .fontSize(16)
                  .fontColor([$r('app.color.text_secondary')])
                Slider({ value: this.mprisVol(), min: 0, max: 100, step: 1 })
                  .layoutWeight(1)
                  .enabled(this.mprisSnap().volume >= 0)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    if (mode === SliderChangeMode.Begin) {
                      this.mprisVolDragging = true;
                      return;
                    }
                    if (mode === SliderChangeMode.Moving) {
                      return;
                    }
                    if (!this.mprisVolDragging) {
                      return;
                    }
                    this.mprisVolDragging = false;
                    this.mediaSetVolume(value);
                  })
                Text(`${this.mprisVol()}`)
                  .fontSize(10)
                  .fontColor($r('app.color.text_muted'))
                  .width(24)
              }
              .width('100%')

              // 循环（None → Track → Playlist 三态）/ 随机
              Row({ space: 10 }) {
                Row({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.repeat'))
                    .fontSize(15)
                    .fontColor([this.mprisSnap().loopStatus !== 'None'
                      ? $r('app.color.accent_text') : $r('app.color.text_muted')])
                  Text(this.mprisLoopText())
                    .fontSize(11)
                    .fontColor(this.mprisSnap().loopStatus !== 'None'
                      ? $r('app.color.accent_text') : $r('app.color.text_muted'))
                }
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(999)
                .backgroundColor($r('app.color.chip_bg'))
                .onClick(() => {
                  this.mediaToggleLoop();
                })

                Row({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.shuffle'))
                    .fontSize(15)
                    .fontColor([this.mprisSnap().shuffle
                      ? $r('app.color.accent_text') : $r('app.color.text_muted')])
                  Text($r('app.string.media_shuffle'))
                    .fontSize(11)
                    .fontColor(this.mprisSnap().shuffle
                      ? $r('app.color.accent_text') : $r('app.color.text_muted'))
                }
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(999)
                .backgroundColor($r('app.color.chip_bg'))
                .onClick(() => {
                  this.mediaToggleShuffle();
                })
              }
              .width('100%')
            }

            } else {
              // 「设备」tab：对端音频输出设备（OutputDevice）列表 —— 每个 sink 一行，可分别调音量/静音。
              // 数据是插件推的**全量快照**（SystemSinkUi，刻度已换算成百分比）：UI 不做换算、不做兜底猜测，
              // 也不持有第二份状态；打开面板时只向对端请求一次列表（协议级刷新）。
              if (this.svSinksForCurrent().length === 0) {
                Text($r('app.string.media_no_output'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Text($r('app.string.media_no_output_hint'))
                  .fontSize(11)
                  .fontColor($r('app.color.text_muted'))
                  .textAlign(TextAlign.Center)
              } else {
                ForEach(this.svSinksForCurrent(), (s: SystemSinkUi) => {
                  SystemSinkRow({
                    sink: s,
                    onVolumeChange: (name: string, pct: number): void => {
                      this.svSinkSet(name, pct);
                    },
                    onToggleMute: (name: string): void => {
                      this.svSinkToggleMute(name);
                    },
                    onSelect: (name: string): void => {
                      this.svSinkSetDefault(name);
                    }
                  })
                }, (s: SystemSinkUi) => s.name)
              }
            }

            // 共用页脚（两个 tab 都是刷新/关闭）：旧实现把这两个按钮放在「媒体」tab 内部，
            // 切到「设备」tab 后就**没有关闭入口**了 —— 已按「tab 只切内容、页脚共用」修正。
            Row({ space: 10 }) {
              Button($r('app.string.media_refresh'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(12)
                .onClick(() => {
                  this.panelRefresh();
                })
              Button($r('app.string.action_cancel'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(12)
                .onClick(() => {
                  this.closeMprisDialog();
                })
            }
            .width('100%')
          }
          .width('86%')
          .padding(20)
          .borderRadius(20)
          // 弹层不用毛玻璃（手机实测：BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，
          // 叠上面板每秒重绘就把主线程拖死 → THREAD_BLOCK_3S/6S、点击无响应）。用更实的底色替代。
          .backgroundColor($r('app.color.dialog_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
          // onClick 为同类型手势竞争（非冒泡）：卡片自身也绑一个空点击把空白区域的点击消费掉，
          // 否则点卡片内的空白处会被外层遮罩的 onClick 抢走 → 弹窗被误关。空白处=只关「卡外」。
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.dialog_mask'))
        .onClick(() => {
          this.closeMprisDialog();
        })
      }

      // 远程命令弹窗（P1，MSG112 §1）：展示对端下发的预设命令列表，点一条即请求执行
      if (this.runCommandDialogOpen) {
        Column() {
          Column({ space: 12 }) {
            Text($r('app.string.run_command_dialog_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.displayNameOf(this.runCommandDeviceId))
              .fontSize(12)
              .fontColor($r('app.color.text_muted'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.runCommands.length === 0) {
              Text($r('app.string.run_command_empty'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
              Text($r('app.string.run_command_empty_hint'))
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
            } else {
              Scroll() {
                Column({ space: 8 }) {
                  ForEach(this.runCommands, (c: RunCommandEntry) => {
                    Column({ space: 2 }) {
                      Text(c.name)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      if (c.command.length > 0) {
                        Text(c.command)
                          .fontSize(10)
                          .fontColor($r('app.color.text_muted'))
                          .fontFamily('monospace')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                      }
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Start)
                    .padding({ left: 12, right: 12, top: 15, bottom: 15 })
                    .borderRadius(12)
                    .backgroundColor($r('app.color.chip_bg'))
                    .onClick(() => {
                      this.runCommand(c.key);
                    })
                  }, (c: RunCommandEntry) => c.key)
                }
                .width('100%')
              }
              .width('100%')
              .constraintSize({ maxHeight: 320 })
              .align(Alignment.TopStart)
              .scrollBar(BarState.Off)
            }
            Button($r('app.string.action_cancel'))
              .width('100%')
              .height(42)
              .fontSize(14)
              .backgroundColor($r('app.color.chip_bg'))
              .fontColor($r('app.color.text_secondary'))
              .borderRadius(12)
              .onClick(() => {
                this.runCommandDialogOpen = false;
              })
          }
          .width('86%')
          .padding(20)
          .borderRadius(20)
          // 弹层不用毛玻璃（手机实测：BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，
          // 叠上面板每秒重绘就把主线程拖死 → THREAD_BLOCK_3S/6S、点击无响应）。用更实的底色替代。
          .backgroundColor($r('app.color.dialog_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
          // 同媒体面板：卡片自身消费点击，只有点「卡外」的遮罩才关弹窗
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.dialog_mask'))
        .onClick(() => {
          this.runCommandDialogOpen = false;
        })
      }

      // 「查看已接收」弹窗（文件页入口）：只读列出本次会话收到的文件 + 大小 + 状态。
      // 结构与其它弹层一致（卡片自身消费点击，只有点卡外遮罩才关）。
      if (this.receivedDialogOpen) {
        Column() {
          Column({ space: 12 }) {
            Text($r('app.string.files_received_dialog_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            if (this.receivedFiles().length === 0) {
              Text($r('app.string.files_received_empty'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            } else {
              Scroll() {
                Column({ space: 8 }) {
                  ForEach(this.receivedFiles(), (p: PayloadTransfer) => {
                    Row({ space: 10 }) {
                      Text(p.fileName)
                        .fontSize(12)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(this.fmtBytes(p.size))
                        .fontSize(11)
                        .fontColor($r('app.color.text_muted'))
                      Text(this.payloadStateText(p))
                        .fontSize(11)
                        .fontColor($r('app.color.accent_text'))
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 15, bottom: 15 })
                    .borderRadius(12)
                    .backgroundColor($r('app.color.chip_bg'))
                  }, (p: PayloadTransfer) => `recv_${p.transferId}`)
                }
                .width('100%')
              }
              .width('100%')
              .constraintSize({ maxHeight: 320 })
              .align(Alignment.TopStart)
              .scrollBar(BarState.Off)
            }
            Row({ space: 10 }) {
              Button($r('app.string.files_history_clear'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.danger_bg'))
                .fontColor($r('app.color.danger_text'))
                .borderRadius(12)
                .enabled(this.receivedFiles().length > 0)
                .onClick(() => {
                  this.clearReceivedHistory();
                })
              Button($r('app.string.action_close'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(12)
                .onClick(() => {
                  this.receivedDialogOpen = false;
                })
            }
            .width('100%')
          }
          .width('86%')
          .padding(20)
          .borderRadius(20)
          .backgroundColor($r('app.color.dialog_bg'))
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.dialog_mask'))
        .onClick(() => {
          this.receivedDialogOpen = false;
        })
      }

      if (this.payloadDetailOpen) {
        // 合并裁定 #13：「文件详情」弹窗抽为 components/PayloadDetailDialog.ets（来自 DevEco，行为保持）
        PayloadDetailDialog({
          fileName: this.payloadDetail().fileName.length > 0
            ? this.payloadDetail().fileName : `#${this.payloadDetailId}`,
          sizeText: this.fmtBytes(this.payloadDetail().size),
          timeText: this.timeTextOf(this.payloadDetail()),
          stateText: this.payloadStateText(this.payloadDetail()),
          dirText: this.resText(this.payloadDetail().direction === 'receive'
            ? $r('app.string.file_dir_receive').id : $r('app.string.file_dir_send').id),
          onSaveAs: (): void => {
            this.saveAsPayload(this.payloadDetail());
          },
          onDiscard: (): void => {
            this.discardPayload(this.payloadDetail());
            this.payloadDetailOpen = false;
          },
          onClose: (): void => {
            this.payloadDetailOpen = false;
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
