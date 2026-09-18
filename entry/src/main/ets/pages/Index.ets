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
import { DeviceItem, RememberedDevice, BatteryItem } from '../model/DeviceModels';
import { MprisItem, MprisSnapshot, emptyMprisItem, mprisDisplayPos, mprisTimeText, mprisPlayerText } from '../model/MprisModels';
import { PayloadTransfer, PayloadDirection, PayloadState } from '../model/PayloadModels';
import { TrustedDevice } from '../model/TrustModels';
import { TrustStore } from '../common/TrustStore';
import { PayloadHistory } from '../common/PayloadHistory';
import { colorModeOf, languageOf, LANG_SYSTEM, THEME_FOLLOW_SYSTEM, systemDeviceName } from '../common/AppSettings';
import { DevicesTab } from '../components/DevicesTab';
import { MprisProgress } from '../components/MprisProgress';
import { FilesTab } from '../components/FilesTab';
import { SettingsTab } from '../components/SettingsTab';
import { LogsTab } from '../components/LogsTab';

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

@Entry
@Component
struct Index {
  @State status: string = 'booting';
  @State logText: string = '';
  @State currentTab: number = 0;
  // 开屏卡顿排查用：build() 调用计数（非 @State，避免自身触发重建）
  private buildCount: number = 0;
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
  @State connectedDevices: DeviceItem[] = [];
  @State discoveredDevices: DeviceItem[] = [];
  @State rememberedDevices: RememberedDevice[] = [];
  // 本侧已发起、等待对端确认的设备
  @State requestedPairIds: string[] = [];
  // 连接/配对会话（用户 miaoshu.txt 需求 4）：
  //   connecting = 连接中（**只有 toast，不弹模态**）
  //   prompt     = 配对确认弹窗（本侧点已连接行「配对」发起，或对端发起；均显示验证码）
  //   awaiting   = 已发配对帧，等对端确认
  // 连接反馈统一走顶部 notice；配对反馈走弹窗 + 成功 notice。
  @State sessionState: string = 'idle';
  @State sessionDeviceId: string = '';
  @State sessionName: string = '';
  @State sessionTarget: string = '';
  @State sessionTimestamp: number = 0;
  // 弹窗里显示的验证码（进入 prompt 时算一次，避免渲染期调 native）
  @State sessionCode: string = '';
  // 对端先发起了配对请求（弹窗按钮为 拒绝/接受；否则为 取消/配对）
  @State sessionPeerRequested: boolean = false;
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
  private sessionTimerId: number = -1;
  private noticeTimerId: number = -1;
  // 媒体面板的 1s 插值时钟（仅面板打开时运行，关闭/退出必清）
  private mprisTickerId: number = -1;
  // 点击/发包限频（key = "设备:动作" → 上次触发时刻）。手机实测：卡片点太快会连发网络请求 +
  // 连开弹窗，叠加重渲染直接把主线程压死（THREAD_BLOCK_3S/6S → 点击无响应）。
  private actionGateMs: Map<string, number> = new Map();
  // 日志缓冲：日志可能每秒来十几条（每个 packet 一条），逐条写 @State 会触发同频整页重渲染。
  // 改为先入缓冲、定时合并刷新（见 log()/flushLog()）。
  private logBuf: string[] = [];
  private logFlushTimer: number = -1;
  private logLastFlushMs: number = 0;   // 上次 flushLog 时刻（P2-2 动态窗用）
  // 进度/音量 Slider 的「用户是否真在拖」标志。
  // 实测坑：Slider 的 onChange 在**程序性**改 value/max 时也会回调（面板刚打开时 length 从 -1
  // 变成真实值 ⇒ 回调被当成 Click/End）→ 误发 SetPosition(1)，把对端播放位置拽回开头。
  // 因此只有先收到 Begin（真拖动才会发）的这一次才算用户操作。
  private mprisSeekDragging: boolean = false;
  private mprisVolDragging: boolean = false;
  // 局域网发现（MSG73/MSG74）：网络变化时触发 native 重新广播 identity
  private netConnection: connection.NetConnection | undefined = undefined;
  private netConnRegistered: boolean = false;
  // AP-2 payload 传输（接收/发送进度与处置状态）
  @State payloads: PayloadTransfer[] = [];
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
  // 系统音量（kdeconnect.systemvolume）读数：与 MPRIS 播放器音量分开显示
  @State sysVolume: number = -1;        // -1 = 未知/不可用
  @State sysMuted: boolean = false;
  @State sysVolumeDeviceId: string = '';
  // 媒体控制面板（方向 1：手机控电脑端播放器）：按设备镜像对端播放器状态
  @State mprisItems: MprisItem[] = [];
  @State mprisDeviceId: string = '';
  @State mprisDialogOpen: boolean = false;
  // 本地时钟（1s ticker 驱动）：进度条位置由 mprisDisplayPos() 用「收包时刻 + 经过时间」插值，
  // 否则对端只在变化时推 pos，播放中进度条会一动不动。
  @State mprisNowMs: number = 0;
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
        this.handlePairRequest(id, ts);
      },
      onPaired: (id: string): void => {
        this.handlePaired(id);
      },
      onUnpaired: (id: string): void => {
        this.handleUnpaired(id);
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
    this.startNative();
    this.registerNetworkListener();
  }

  // 页面显示后应用主题/语言（setColorMode/setLanguage 要求页面已加载完成）。
  // 必须同时等 Preferences 读取完成，二者任一先到都触发检查，避免用默认值覆盖用户设置。
  onPageShow(): void {
    this.pageShown = true;
    this.applySettingsIfReady();
    // 回到前台：媒体面板还开着就恢复插值时钟（onPageHide 会把它停掉）
    if (this.mprisDialogOpen) {
      this.startMprisTicker();
    }
    // 回前台/首次进入时主动广播一次：对端广播间隔较长，若启动时刚好错过上一轮，
    // 设备页会长时间空着（用户 2026-09-16 反馈「列表里什么都没有」）。
    // 有 3s 门控（actionGate 'net:triggerBroadcast'），不会放大主线程负担。
    this.triggerDiscoveryBroadcast();
  }

  onPageHide(): void {
    // 退后台：停插值时钟，别在后台每秒唤醒 UI（用户建议「实时同步的前后台分开」）
    this.stopMprisTicker();
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
    // 媒体面板的插值时钟必须清掉（否则页面销毁后仍在跑）
    this.stopMprisTicker();
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
      const parts: string[] = data.split('|');
      const ok: boolean = parts.length > 0 && parts[0] === '1';
      const code: string = parts.length > 1 ? parts[1] : '?';
      const text: string = parts.length > 2 ? parts[2] : '';
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
    // 系统音量（kdeconnect.systemvolume）：<volume 0-100 或 ?>|<muted 1|0>
    if (kind === 'sysvolume') {
      const sp: string[] = data.split('|');
      const v: number = sp.length > 0 && sp[0] !== '?' ? Number.parseInt(sp[0], 10) : -1;
      this.sysVolume = Number.isFinite(v) ? v : -1;
      this.sysMuted = sp.length > 1 && sp[1] === '1';
      this.sysVolumeDeviceId = deviceId;
      return;
    }
    if (kind !== 'battery') {
      this.log(`plugin event ${kind} from ${deviceId}`);
      return;
    }
    const parts: string[] = data.split('|');
    const charge: string = parts.length > 0 ? parts[0] : '?';
    const charging: boolean = parts.length > 1 && parts[1] === '1';
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

  private sysVolumeSet(v: number): void {
    if (!this.actionGate(`sysvol:${this.mprisDeviceId}:vol`, 200)) {
      return;
    }
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
    if (p === undefined || !p.setVolume(v)) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  private sysVolumeToggleMute(): void {
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.mprisDeviceId);
    if (p === undefined || !p.toggleMute()) {
      this.toastText(this.resText($r('app.string.toast_media_action_failed').id));
    }
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

  // 进度条位置：由「收包时的 pos + 本地经过时间」插值（1s ticker 驱动刷新）。
  // 注意量程用**千分比**而不是毫秒：曲目长度常达 1e6 ms（如 1129000），
  // Slider 拿百万量程 + step=1000 时布局/刻度计算代价很大，手机快速连点开合面板会卡死主线程
  // （实测 THREAD_BLOCK_3S，且只有带 Slider 的媒体面板会卡、无 Slider 的远程命令弹窗不卡）。
  private mprisPosPermille(): number {
    const len: number = this.mprisSnap().length;
    if (len <= 0) {
      return 0;
    }
    const pos: number = mprisDisplayPos(this.mprisSnap(), this.mprisNowMs);
    return Math.round(pos * 1000 / len);
  }

  private mprisPos(): number {
    return mprisDisplayPos(this.mprisSnap(), this.mprisNowMs);
  }

  // 千分比 → 毫秒（拖动结束回传对端时用）
  private mprisPermilleToMs(permille: number): number {
    const len: number = this.mprisSnap().length;
    return len > 0 ? Math.round(permille * len / 1000) : 0;
  }

  private mprisMaxPos(): number {
    const len: number = this.mprisSnap().length;
    return len > 0 ? 1000 : 1;
  }

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

  private startMprisTicker(): void {
    // 批2 根治：插值时钟已下沉到 MprisProgress 组件（组件局部 @State + 自己的 1s ticker），
    // 这里**不再**写页面级 mprisNowMs —— 否则面板打开期间每秒整页重建。
    // 保留方法体为空以兼容既有调用点（onPageShow / openMprisDialog）。
  }

  private stopMprisTicker(): void {
    if (this.mprisTickerId >= 0) {
      clearInterval(this.mprisTickerId);
      this.mprisTickerId = -1;
    }
  }

  private closeMprisDialog(): void {
    this.mprisDialogOpen = false;
    this.stopMprisTicker();
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

  // AP-1：对端发起配对请求 → 弹确认框（不做任何自动接受）
  // 对端发起配对请求 → 弹配对确认框（与「已连接行点配对」同一个弹窗，需求 4.3 统一）
  private handlePairRequest(deviceId: string, timestamp: number): void {
    if (deviceId === '') {
      return;
    }
    this.openPairDialog(deviceId, this.displayNameOf(deviceId), true, timestamp);
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
    this.openPairDialog(d.id, d.name, false, Math.floor(Date.now() / 1000));
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
    this.requestedPairIds = this.requestedPairIds.filter((id: string) => id !== deviceId);
    const name: string = this.displayNameOf(deviceId);
    const exists: boolean = this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId);
    let peerCert: string = '';
    try {
      peerCert = native.getPeerCertificate(deviceId);
    } catch (e) {
      this.log('getPeerCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    if (exists) {
      // 重新配对：把该条目重置为「已配对」（需求 3：解除配对时条目保留，重新配对成功后复用）
      this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        if (t.id !== deviceId) {
          return t;
        }
        const next: TrustedDevice = {
          id: t.id,
          name: name.length > 0 ? name : t.name,
          certPem: peerCert.length > 0 ? peerCert : t.certPem,
          pairedAt: Date.now(),
          paired: true
        };
        return next;
      });
    } else {
      const entry: TrustedDevice = {
        id: deviceId,
        name: name,
        certPem: peerCert,
        pairedAt: Date.now(),
        paired: true
      };
      this.trustedDevices = this.trustedDevices.concat([entry]);
    }
    this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
      return r;
    });
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
    // 会话命中该设备 → 配对成功：提示并自动跳回「已连接设备」
    if (this.sessionDeviceId === deviceId && this.sessionState !== 'idle') {
      this.succeedSession();
      this.log('pair success -> switch to connected devices');
    }
  }

  // 对端发 unpair {pair:false} 或本侧解除配对：
  // 需求 3（用户 miaoshu.txt）——**保留条目**（便于后续重新配对），只置 paired=false 并清钉扎。
  private handleUnpaired(deviceId: string): void {
    this.requestedPairIds = this.requestedPairIds.filter((id: string) => id !== deviceId);
    if (this.sessionDeviceId === deviceId && this.sessionState !== 'idle') {
      this.clearSessionTimer();
      this.sessionState = 'idle';
      this.sessionCode = '';
      this.sessionPeerRequested = false;
    }
    // WP-2：解除钉扎（native 侧不再强校验该设备证书）
    try {
      native.removeTrustedCertificate(deviceId);
    } catch (e) {
      this.log('removeTrustedCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
    }
    const before: number = this.trustedDevices.length;
    this.trustedDevices = this.trustedDevices.map((t: TrustedDevice) => {
      if (t.id !== deviceId) {
        return t;
      }
      const next: TrustedDevice = {
        id: t.id,
        name: t.name,
        certPem: t.certPem,
        pairedAt: t.pairedAt,
        paired: false
      };
      return next;
    });
    if (this.trustedDevices.length !== before || true) {
      this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        const r: RememberedDevice = { id: t.id, name: t.name, paired: t.paired };
        return r;
      });
      this.persistTrust();
      this.log(`unpaired ${deviceId} (kept in remembered list)`);
    }
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
          if (this.sessionState === 'connecting'
            && (this.sessionDeviceId === cid || this.sessionDeviceId === '')) {
            this.clearSessionTimer();
            this.sessionDeviceId = cid;
            this.sessionName = event.deviceName ?? this.sessionName;
            this.sessionState = 'idle';
            this.showNotice('connected', event.deviceName ?? this.sessionName, false);
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
        // 断链即清「等待确认」态（否则行上会残留"等待确认"徽标）
        this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== did);
        // AP-4：断链卸载该设备插件（onDestroy 必达）
        this.pluginHost?.unloadForDevice(did);
        // 媒体面板清账（P2，MSG132 §2）：丢该设备的面板镜像并关面板
        // （插件实例已销毁，再点控制键必然失败；留着快照还会显示过期曲目）
        this.forgetMpris(did);
        // 会话中的设备断链 → 连接/配对失败
        if (did !== '' && this.sessionDeviceId === did) {
          if (this.sessionState === 'connecting') {
            this.failConnect('disconnected', Index.ERR_DISCONNECTED);
          } else if (this.sessionState === 'awaiting' || this.sessionState === 'prompt') {
            this.failPairing('disconnected', Index.ERR_DISCONNECTED);
          }
        }
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
        // 会话进行中报错 → 直接判定失败（提示只给错误码，明细已在日志里）
        const eid: string = event.deviceId ?? '';
        if (eid === '' || this.sessionDeviceId === '' || this.sessionDeviceId === eid) {
          const code: number = event.errorCode ?? Index.ERR_OTHER;
          if (this.sessionState === 'connecting') {
            this.failConnect(em.length > 0 ? em : `error ${code}`, code);
          } else if (this.sessionState === 'awaiting' || this.sessionState === 'prompt') {
            this.failPairing(em.length > 0 ? em : `error ${code}`, code);
          }
        }
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
    this.startSession('', `${host}:${port}`, host, port);
  }

  // ---- 连接/配对会话 ----

  private isTrusted(deviceId: string): boolean {
    return this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId && t.paired);
  }

  // 失败码（上线口径：提示只给错误码，明细进日志）
  private static readonly ERR_TIMEOUT: number = 1;
  private static readonly ERR_DISCONNECTED: number = 2;
  private static readonly ERR_SEND: number = 3;
  private static readonly ERR_ADDRESS: number = 4;
  private static readonly ERR_OTHER: number = 0;

  private clearSessionTimer(): void {
    if (this.sessionTimerId !== -1) {
      clearTimeout(this.sessionTimerId);
      this.sessionTimerId = -1;
    }
  }

  // stage: 'connect' → 连接超时；'pair' → 配对超时
  private armSessionTimer(ms: number, reason: string, stage: string, code: number): void {
    this.clearSessionTimer();
    this.sessionTimerId = setTimeout((): void => {
      this.sessionTimerId = -1;
      if (stage === 'pair') {
        this.failPairing(reason, code);
      } else {
        this.failConnect(reason, code);
      }
    }, ms);
  }

  // 统一入口（需求 4.1/4.2）：**不弹模态**，只给提示；设备连上后自然出现在「已连接设备」
  private startSession(id: string, name: string, host: string, port: number): void {
    if (this.sessionState === 'connecting') {
      this.log(`session busy (connecting), ignore ${host}:${port}`);
      return;
    }
    // port === 0 = 端口未知（native 只被对端拨入过时拿不到 tcpPort：KDE 只在 UDP 广播里带它）。
    // 交给 native 自己按 1716–1764 探测（connectToPeer(host, 0)），不要再判 no address。
    if (host === '') {
      this.failConnect('no address', Index.ERR_ADDRESS);
      return;
    }
    const portText: string = port > 0 ? `${port}` : '端口探测中';
    this.clearSessionTimer();
    this.sessionDeviceId = id;
    this.sessionName = name.length > 0 ? name : `${host}:${portText}`;
    this.sessionTarget = port > 0 ? `${host}:${port}` : host;
    this.sessionState = 'connecting';
    this.log(`connect ${this.sessionTarget}${port > 0 ? '' : ' (port unknown, native probe)'}`);
    this.showNotice('connecting', this.sessionTarget, false, 0);
    try {
      native.connectToPeer(host, port);
    } catch (e) {
      this.failConnect('connectToPeer failed: ' + (e instanceof Error ? e.message : 'unknown'), Index.ERR_OTHER);
      return;
    }
    this.armSessionTimer(CONNECT_TIMEOUT_MS, 'connect timeout', 'connect', Index.ERR_TIMEOUT);
  }

  // 连接失败（需求 4.1 + 上线口径）：UI 只给错误码，明细写日志
  private failConnect(reason: string, code: number): void {
    this.clearSessionTimer();
    this.sessionState = 'idle';
    this.showNotice('failed', `${code}`, true);
    this.log(`connect failed: ${reason} (code=${code})`);
  }

  // 打开配对确认弹窗（需求 4.3：配对统一在「已连接设备」里点「配对」，弹窗显示验证码）
  private openPairDialog(deviceId: string, name: string, peerRequested: boolean, timestamp: number): void {
    this.clearSessionTimer();
    this.sessionDeviceId = deviceId;
    if (name.length > 0) {
      this.sessionName = name;
    }
    this.sessionPeerRequested = peerRequested;
    this.sessionTimestamp = timestamp;
    this.sessionCode = this.computePairCode(deviceId, timestamp);
    this.sessionState = 'prompt';
    this.noticeKey = '';
    this.log(peerRequested
      ? `pair confirm dialog (peer requested, ts=${timestamp})`
      : `pair confirm dialog opened for ${deviceId}`);
  }

  // 弹窗确认：对端先请求 → 发接受帧（不带 timestamp）；本侧发起 → 发带 timestamp 的请求
  private confirmPairInSession(): void {
    const id: string = this.sessionDeviceId;
    if (id === '' || this.router === undefined) {
      return;
    }
    if (this.sessionPeerRequested) {
      this.router.acceptPair(id);
      this.sessionState = 'idle';
      this.sessionCode = '';
      return;
    }
    if (!this.sendPairRequest(id)) {
      this.sessionState = 'idle';
      this.sessionCode = '';
      this.showNotice('pairFailed', `${Index.ERR_SEND}`, true);
      this.log('pairing failed: pair request not sent (code=3)');
      return;
    }
    this.sessionState = 'awaiting';
    this.armSessionTimer(PAIR_TIMEOUT_MS, 'pair not confirmed', 'pair', Index.ERR_TIMEOUT);
  }

  // 弹窗取消/拒绝：本侧发起 → 仅收起弹窗；对端请求 → 回 {pair:false}
  private cancelPairDialog(): void {
    const id: string = this.sessionDeviceId;
    const wasPeerRequest: boolean = this.sessionPeerRequested;
    this.clearSessionTimer();
    this.sessionState = 'idle';
    this.sessionCode = '';
    this.sessionPeerRequested = false;
    if (id !== '') {
      this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== id);
      if (wasPeerRequest && this.router !== undefined) {
        this.router.rejectPair(id);
        this.log(`pairing rejected: ${id}`);
        return;
      }
    }
    this.log('pair dialog cancelled by user');
  }

  // 发 pair:true 并记录本侧等待态。返回是否真的发出。
  private sendPairRequest(deviceId: string): boolean {
    if (this.router === undefined) {
      return false;
    }
    const ok: boolean = this.router.requestPair(deviceId, this.sessionTimestamp);
    if (ok && !this.requestedPairIds.includes(deviceId)) {
      this.requestedPairIds = this.requestedPairIds.concat([deviceId]);
    }
    return ok;
  }

  // 配对失败/超时：**同时把该设备的配对态置为未配对**（用户实测反馈：
  // 对端拒绝或超时后仍显示「已配对」是错误的）——状态必须反映真实结果。
  private failPairing(reason: string, code: number): void {
    this.clearSessionTimer();
    const id: string = this.sessionDeviceId;
    this.sessionState = 'idle';
    this.sessionCode = '';
    this.sessionPeerRequested = false;
    if (id !== '') {
      this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== id);
      this.setPairedFlag(id, false);
    }
    this.showNotice('pairFailed', `${code}`, true);
    this.log(`pairing failed: ${reason} (code=${code})${id !== '' ? ' (' + id + ')' : ''}`);
  }

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

  // 成功：提示 + 自动跳回「已连接设备」
  private succeedSession(): void {
    this.clearSessionTimer();
    const id: string = this.sessionDeviceId;
    this.sessionState = 'idle';
    this.sessionCode = '';
    this.sessionPeerRequested = false;
    this.deviceSection = 0;
    if (id !== '') {
      // 配对成功后顺带选中该设备 → 直接落到它的「功能页」（设备信息 + 大按钮），
      // 不再依赖用户之前是否在抽屉里选过设备
      this.selectedDeviceId = id;
      this.pruneActionGate();   // P2-1①：选设备时清过期限频键
      this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== id);
    }
    this.showNotice('paired', '', false);
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
      this.mprisNowMs = Date.now();
      this.mprisDialogOpen = true;
      this.startMprisTicker();
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
  private sanitizeFileName(raw: string, transferId: number): string {
    let name: string = raw;
    name = name.replace(new RegExp('/', 'g'), '_');
    name = name.replace(new RegExp('\\\\', 'g'), '_');
    while (name.startsWith('.')) {
      name = name.substring(1);
    }
    if (name.length === 0) {
      name = `transfer_${transferId}`;
    }
    if (name.length > 128) {
      name = name.substring(0, 128);
    }
    return name;
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

  private payloadStateText(p: PayloadTransfer): string {
    if (p.state === 'started' || p.state === 'progress') {
      return this.resText($r('app.string.files_receiving').id);
    }
    if (p.state === 'finished') {
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

  // M2：选文件 → 复制进沙箱 → native.sendPayload（发送方向；进度走 payloadTransfer）
  private async pickAndSendFile(): Promise<void> {
    if (this.connectedDevices.length === 0) {
      this.log('send file: no connected device');
      return;
    }
    const target: DeviceItem = this.connectedDevices[0];
    if (this.connectedDevices.length > 1) {
      this.log(`send file: multiple devices, using ${target.name}`);
    }
    const hostCtx: Context | undefined = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.log('send file: no host context');
      return;
    }
    let uris: string[] = [];
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(hostCtx);
      const options: picker.DocumentSelectOptions = { maxSelectNumber: 1 };
      uris = await docPicker.select(options);
    } catch (e) {
      this.log('send file: picker cancelled/failed');
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const srcUri: string = uris[0];
    let fileName: string = srcUri.substring(srcUri.lastIndexOf('/') + 1);
    try {
      fileName = decodeURIComponent(fileName);
    } catch (e) {
      // URI 未编码时 decodeURIComponent 会抛；忽略，沿用原名
    }
    const cachePath: string = `${hostCtx.cacheDir}/${fileName}`;
    // picker 返回的是 URI：必须经 fd 读，直接 copyFile(uri, path) 会失败（实测 "copy into sandbox failed"）。
    let srcFd: fileIo.File | undefined = undefined;
    try {
      srcFd = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(srcFd.fd, cachePath);
    } catch (e) {
      this.log('send file: copy into sandbox failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return;
    } finally {
      if (srcFd !== undefined) {
        try {
          fileIo.closeSync(srcFd);
        } catch (e) {
          // 忽略关闭失败
        }
      }
    }
    try {
      const body: SendShareBody = { filename: fileName };
      const transferId: number = native.sendPayload(target.id, 'kdeconnect.share.request',
        JSON.stringify(body), cachePath);
      this.log(transferId > 0
        ? `send file #${transferId}: ${fileName} -> ${target.name}`
        : 'send file: sendPayload returned 0 (failed)');
    } catch (e) {
      this.log('sendPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
    }
  }

  private log(line: string): void {
    const t: string = new Date().toTimeString().substring(0, 8);
    this.logBuf.push(`[${t}] ${line}`);
    if (this.logBuf.length > 200) {
      this.logBuf.splice(0, this.logBuf.length - 200);
    }
    // 合并刷新：窗口内的多条日志攒成一次 @State 写入，避免日志频率直接驱动渲染频率。
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
    if (this.logBuf.length === 0) {
      return;
    }
    // ARKTS_ANALYSIS §8-A（根治）：日志页不可见时不写 @State。
    // 写 logText 会触发**整页重建**；开屏/日常操作期大量日志都发生在别的页签上，
    // 这些重建纯属浪费（用户看不到日志）。切回日志页时由 tabs onChange 补一次 flush。
    if (this.currentTab !== 3) {
      return;
    }
    this.logText = this.logBuf.slice(-50).join('\n');
    this.logLastFlushMs = Date.now();
    // 开屏卡顿排查（MSG8 §4 问题 1/#1）：每次 flushLog 都会写 @State logText ⇒ 触发一次整页重建。
    // 这里计数并在首屏窗口内打印，用来量化「开屏期日志驱动的重建次数」。build() 里不能写任意语句，
    // 所以计数放在这个真正触发重建的点上。
    this.buildCount++;
    if (this.buildCount <= 3 || this.buildCount % 50 === 0) {
      console.info(`KDC logflush #${this.buildCount} @${Date.now()}`);
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

  // 清空日志（含缓冲，否则下一次 flush 会把旧行又贴回来）
  private clearLog(): void {
    this.logBuf = [];
    this.logText = '';
  }

  // 沉浸光感能力探测（仅记录）。底栏材质由 HdsTabs 的 barFloatingStyle.systemMaterialEffect
  // 提供（官方推荐、自动按设备算力自适应）；卡片等非 TabBar 区域不在生效范围，走毛玻璃。
  private initImmersiveMaterial(): void {
    try {
      const supported: boolean = uiMaterial.isImmersiveMaterialSupported();
      console.info('KDC uiMaterial supported=' + supported);
    } catch (e) {
      // 环境不支持（如 QEMU 模拟器）时静默降级，不进屏幕日志
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

  // 抽屉里实际渲染的已连接设备：收起态只取前 drawerDeviceCap 台，展开态全部
  private visibleDrawerDevices(): DeviceItem[] {
    const list: DeviceItem[] = this.connectedShown();
    if (this.drawerExpanded || list.length <= DRAWER_DEVICE_CAP) {
      return list;
    }
    return list.slice(0, DRAWER_DEVICE_CAP);
  }

  // 抽屉里的设备行（对齐参考稿「我的产品」列表：方图 + 名称 + 副标题 + 状态标签，
  // 选中行整行高亮）。点击 = 选中该设备并收起抽屉，页面随即展示该设备详情 + 大按钮。
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

      Text(this.isPairedId(d.id) ? $r('app.string.remembered_hint') : $r('app.string.remembered_unpaired'))
        .fontSize(10)
        .fontColor(this.isPairedId(d.id) ? $r('app.color.dot_remembered') : $r('app.color.text_muted'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor($r('app.color.chip_bg'))
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.selectedDeviceId === d.id ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick(() => {
      // 必须走 openDeviceDetail：它同时负责「选中设备 + 切到已连接设备分区（功能页）」。
      // 原来只置 selectedDeviceId，若当前停在发现/记忆/手动分区，点完页面不变 → 用户反馈"点了没反应"
      this.openDeviceDetail(d);
      this.closeDrawer();
    })
  }

  // 发现列表展示用：IP:端口（端口未知时只给 IP；地址未知给占位文案）
  private addressOf(d: DeviceItem): ResourceStr {
    if (d.host === '') {
      return $r('app.string.address_pending');
    }
    return d.tcpPort > 0 ? `${d.host}:${d.tcpPort}` : d.host;
  }

  // 抽屉里的「发现设备」行：点击/配对按钮 = 发起配对（配对成功才转入「已连接」）
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
        // 发现行只显示 IP:端口（设备 ID 在配对弹窗里核对）
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
            this.requestPairWith(d);
            this.closeDrawer();
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .onClick(() => {
      this.requestPairWith(d);
      this.closeDrawer();
    })
  }

  // 抽屉里「展开 ⌄」之后露出的分区入口（发现 / 记住 / 手动）：
  // 这三个页面本身不变，只是入口挪到展开区（对齐参考稿的「展开」折叠）。
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
      this.pickDrawerSection(index);
    })
  }

  @Builder
  drawerOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 遮罩：浅色变暗（不用纯黑/材质层——暗色主题下会糊成"黑方块"）；全屏淡入淡出
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#40000000')
        .onClick(() => {
          this.closeDrawer();
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))

      // 面板：左贴屏边、右侧圆角、滑入/滑出
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text($r('app.string.tab_devices'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
            .padding(8)
            .onClick(() => {
              this.closeDrawer();
            })
        }
        .width('100%')

        Scroll() {
          Column({ space: 6 }) {
            Text($r('app.string.connected_devices'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            if (this.connectedShown().length === 0) {
              Text($r('app.string.drawer_pick_device_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
                .width('100%')
                .padding({ top: 4, bottom: 4 })
            }
            ForEach(this.visibleDrawerDevices(), (d: DeviceItem) => {
              this.drawerDeviceRow(d)
            }, (d: DeviceItem) => `conn-${d.id}`)

            // 「展开 ⌄」只作用于**已连接设备列表**（设备多时先收起、点开看全部）；
            // 下面三个分区入口（发现/记住/手动）常驻可见可点，不参与收起
            if (this.connectedShown().length > DRAWER_DEVICE_CAP) {
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

            // 发现设备：未配对的在线设备（含已连上但未配对的）—— 配对入口在发现列表里
            // （用户 2026-09-14 裁决：只有配对成功才进「已连接」，故配对按钮留在发现列表）
            Text($r('app.string.discovered_devices'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 10, bottom: 4 })
            if (this.discoveredShown().length === 0) {
              Text($r('app.string.discovered_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
                .width('100%')
                .padding({ top: 4, bottom: 4 })
            }
            ForEach(this.discoveredShown(), (d: DeviceItem) => {
              this.drawerPairRow(d)
            }, (d: DeviceItem) => `disc-${d.id}`)

            this.drawerSectionRow(2, $r('app.string.remembered_devices'), this.offlineKnownShown().length)
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
      .width('78%')
      .constraintSize(DRAWER_WIDTH_LIMIT)
      .height('100%')
      .padding({
        left: 16,
        right: 16,
        top: this.getUIContext().px2vp(this.statusBarHeightPx) + 16,
        bottom: 16
      })
      // 抽屉：恢复毛玻璃，并换用更实的 drawer_bg（用户反馈去掉模糊后太透、文字看不清）
      .backgroundColor($r('app.color.drawer_bg'))
      .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
      .borderRadius({ topRight: 22, bottomRight: 22 })
      .border({ width: 1, color: $r('app.color.bar_border') })
      .alignItems(HorizontalAlign.Start)
      .clip(true)
      .transition(TransitionEffect.translate({ x: -400 }).animation({ duration: 280, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
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
                immersive: false,
                sideBySide: this.sideBySide,
                requestedPairIds: this.requestedPairIds,
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
                    immersive: false,
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
                immersive: false,
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
                  logText: this.logText,
                  immersive: false,
                  onClearLogs: (): void => {
                    this.clearLog();
                  }
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
      if (this.sessionState === 'prompt' || this.sessionState === 'awaiting') {
        Column() {
          Column({ space: 14 }) {
            Text(this.sessionPeerRequested
              ? $r('app.string.pair_dialog_title')
              : $r('app.string.pair_dialog_title_outgoing'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.sessionName)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 设备 ID 在弹窗里核对（列表里只显示 IP:端口，用户 2026-09-14）
            if (this.sessionDeviceId.length > 0) {
              Text(`${this.resText($r('app.string.settings_device_id').id)}: ${this.sessionDeviceId}`)
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
              Text(this.sessionCode.length > 0 ? this.sessionCode : '-- -- -- --')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.accent_text'))
                .fontFamily('monospace')
              if (this.sessionCode.length === 0) {
                Text($r('app.string.pair_code_unavailable'))
                  .fontSize(10)
                  .fontColor($r('app.color.text_muted'))
              }
            }
            Text($r('app.string.pair_dialog_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
            if (this.sessionState === 'awaiting') {
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
              Button(this.sessionPeerRequested ? $r('app.string.pair_reject') : $r('app.string.action_cancel'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.danger_bg'))
                .fontColor($r('app.color.danger_text'))
                .borderRadius(12)
                .onClick(() => {
                  this.cancelPairDialog();
                })
              if (this.sessionState === 'prompt') {
                Button(this.sessionPeerRequested ? $r('app.string.pair_accept') : $r('app.string.pair_action'))
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(14)
                  .backgroundColor($r('app.color.accent'))
                  .borderRadius(12)
                  .onClick(() => {
                    this.confirmPairInSession();
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
          .backgroundColor('#F2111A36')
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#99000000')
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

            Row({ space: 10 }) {
              Button($r('app.string.media_refresh'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(12)
                .onClick(() => {
                  this.mediaRefresh();
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

            // ★ 系统音量（用户 2026-09-18 要求）：**常显**，与上面的「播放器音量」分成两块。
            // 播放器不提供音量属性（Firefox 的 MPRIS 就没有）或根本没有播放器时，这里仍可调对端系统音量。
            Row({ space: 8 }) {
              Text($r('app.string.sys_volume'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
              Slider({
                value: this.sysVolumeDeviceId === this.mprisDeviceId && this.sysVolume >= 0 ? this.sysVolume : 0,
                min: 0,
                max: 100,
                step: 1
              })
                .layoutWeight(1)
                .enabled(this.sysVolumeDeviceId === this.mprisDeviceId && this.sysVolume >= 0)
                .onChange((value: number, mode: SliderChangeMode) => {
                  // 只认松手（End/Click）：拖动过程不打点，Begin/Moving 一律跳过
                  if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                    return;
                  }
                  this.sysVolumeSet(value);
                })
              Text(this.sysVolumeDeviceId === this.mprisDeviceId && this.sysVolume >= 0 ? `${this.sysVolume}` : '—')
                .fontSize(10)
                .fontColor($r('app.color.text_muted'))
                .width(28)
              Button(this.sysMuted ? $r('app.string.sys_unmute') : $r('app.string.sys_mute'))
                .fontSize(11)
                .height(30)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor(this.sysMuted ? $r('app.color.danger_text') : $r('app.color.text_secondary'))
                .borderRadius(8)
                .onClick(() => {
                  this.sysVolumeToggleMute();
                })
            }
            .width('100%')
          }
          .width('86%')
          .padding(20)
          .borderRadius(20)
          // 弹层不用毛玻璃（手机实测：BACKGROUND_THICK 在弹层上会让整屏重算背景模糊，
          // 叠上面板每秒重绘就把主线程拖死 → THREAD_BLOCK_3S/6S、点击无响应）。用更实的底色替代。
          .backgroundColor('#F2111A36')
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
        .backgroundColor('#99000000')
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
          .backgroundColor('#F2111A36')
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
          // 同媒体面板：卡片自身消费点击，只有点「卡外」的遮罩才关弹窗
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#99000000')
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
          .backgroundColor('#F2111A36')
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#99000000')
        .onClick(() => {
          this.receivedDialogOpen = false;
        })
      }

      // 「文件详情」弹窗（点击文件行触发）：属性 + 另存为 / 丢弃 / 取消。
      // 另存为走系统保存面板（用户自选目录 ⇒ 文件管理里可见）；丢弃走 native discardPayload。
      if (this.payloadDetailOpen) {
        Column() {
          Column({ space: 12 }) {
            Text(this.payloadDetail().fileName.length > 0
              ? this.payloadDetail().fileName : `#${this.payloadDetailId}`)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.infoLine($r('app.string.file_attr_size'), this.fmtBytes(this.payloadDetail().size))
            this.infoLine($r('app.string.file_attr_time'), this.timeTextOf(this.payloadDetail()))
            this.infoLine($r('app.string.file_attr_state'), this.payloadStateText(this.payloadDetail()))
            this.infoLine($r('app.string.file_attr_dir'), this.resText(this.payloadDetail().direction === 'receive'
              ? $r('app.string.file_dir_receive').id : $r('app.string.file_dir_send').id))
            Row({ space: 10 }) {
              Button($r('app.string.file_action_save_as'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.accent'))
                .borderRadius(12)
                .onClick(() => {
                  this.saveAsPayload(this.payloadDetail());
                })
              Button($r('app.string.files_action_discard'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.danger_bg'))
                .fontColor($r('app.color.danger_text'))
                .borderRadius(12)
                .onClick(() => {
                  this.discardPayload(this.payloadDetail());
                  this.payloadDetailOpen = false;
                })
              Button($r('app.string.action_cancel'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.chip_bg'))
                .fontColor($r('app.color.text_secondary'))
                .borderRadius(12)
                .onClick(() => {
                  this.payloadDetailOpen = false;
                })
            }
            .width('100%')
          }
          .width('80%')
          .padding(20)
          .borderRadius(20)
          .backgroundColor('#F2111A36')
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#99000000')
        .onClick(() => {
          this.payloadDetailOpen = false;
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
