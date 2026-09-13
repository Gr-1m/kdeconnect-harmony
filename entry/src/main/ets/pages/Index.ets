import native from 'libkdeconnect_napi.so';
import { NetConfig, CertPair, NetEvent } from 'libkdeconnect_napi.so';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { Context, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { PacketRouter, RouterCallbacks } from '../net/PacketRouter';
import { PluginBase } from '../plugins/PluginBase';
import { PluginRegistry } from '../plugins/PluginRegistry';
import { PluginHost } from '../plugins/PluginHost';
import { PingPlugin } from '../plugins/PingPlugin';
import { SharePlugin } from '../plugins/SharePlugin';
import { BatteryPlugin } from '../plugins/BatteryPlugin';
import { ClipboardPlugin } from '../plugins/ClipboardPlugin';
import { FindMyPhonePlugin } from '../plugins/FindMyPhonePlugin';
import { DeviceItem, RememberedDevice, BatteryItem } from '../model/DeviceModels';
import { PayloadTransfer, PayloadDirection, PayloadState } from '../model/PayloadModels';
import { TrustedDevice } from '../model/TrustModels';
import { TrustStore } from '../common/TrustStore';
import { colorModeOf, languageOf, LANG_SYSTEM, THEME_FOLLOW_SYSTEM, systemDeviceName } from '../common/AppSettings';
import { DevicesTab } from '../components/DevicesTab';
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

@Entry
@Component
struct Index {
  @State status: string = 'booting';
  @State logText: string = '';
  @State currentTab: number = 0;
  @State deviceName: string = DEFAULT_DEVICE_NAME;
  // 系统设备名称（只读展示 + 设置页「使用系统名称」）
  @State systemName: string = '';
  @State themeMode: number = THEME_FOLLOW_SYSTEM;
  @State language: string = LANG_SYSTEM;
  // 宽屏（平板/折叠展开）判定：>=600vp 走常驻侧栏，否则走抽屉式侧栏
  @State isWide: boolean = false;
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
  // 局域网发现（MSG73/MSG74）：网络变化时触发 native 重新广播 identity
  private netConnection: connection.NetConnection | undefined = undefined;
  private netConnRegistered: boolean = false;
  // AP-2 payload 传输（接收/发送进度与处置状态）
  @State payloads: PayloadTransfer[] = [];
  // 插件推来的展示项（目前：电量）
  @State batteryItems: BatteryItem[] = [];
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
  }

  private applySettingsIfReady(): void {
    if (!this.pageShown || !this.settingsLoaded || this.settingsApplied) {
      return;
    }
    this.settingsApplied = true;
    this.applyTheme(this.themeMode, false);
    this.applyLanguage(this.language, false);
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
      this.isWide = vpWidth >= 600;
    } catch (e) {
      this.isWide = false;
    }
  }

  private startNative(): void {
    try {
      const cfg: NetConfig = {
        deviceId: this.deviceId,
        deviceName: this.deviceName,
        deviceType: 'phone',
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
        native.setCapabilities(incoming, outgoing);
        this.log(`caps: in=${incoming.length} out=${outgoing.length}`);
      } catch (e) {
        this.log('setCapabilities unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      }
      native.start(cfg);
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
      native.triggerBroadcast();
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
      (dev: string, kind: string, data: string): void => {
        this.onPluginEvent(dev, kind, data);
      });
  }

  // 插件 → UI 事件（电量等）
  private onPluginEvent(deviceId: string, kind: string, data: string): void {
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
    // 验证事件桥是否端到端到达 ArkTS（验证后可删）
    console.info('KDC net event: ' + JSON.stringify(event));
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
        const known: boolean = this.discoveredDevices.some((d: DeviceItem) => d.id === id);
        if (known) {
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
        this.log(`connected ${event.deviceId} role=${event.role}`);
        break;
      }
      case 'disconnected': {
        const did: string = event.deviceId ?? '';
        this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== did);
        this.batteryItems = this.batteryItems.filter((b: BatteryItem) => b.deviceId !== did);
        // 断链即清「等待确认」态（否则行上会残留"等待确认"徽标）
        this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== did);
        // AP-4：断链卸载该设备插件（onDestroy 必达）
        this.pluginHost?.unloadForDevice(did);
        // 会话中的设备断链 → 连接/配对失败
        if (did !== '' && this.sessionDeviceId === did) {
          if (this.sessionState === 'connecting') {
            this.failConnect('disconnected', Index.ERR_DISCONNECTED);
          } else if (this.sessionState === 'awaiting' || this.sessionState === 'prompt') {
            this.failPairing('disconnected', Index.ERR_DISCONNECTED);
          }
        }
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
        this.discoveredDevices = this.discoveredDevices.map(
          (d: DeviceItem) => d.id === lid ? { id: d.id, name: d.name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType, online: false } : d);
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

  // 设备详情页的大按钮动作（计划 B）：能落地的接真实插件，落地不了的给明确提示。
  // 用户要求：点「发送文件」**跳到文件导航**（发送入口在文件页），不直接弹系统选择器。
  private onDeviceAction(key: string): void {
    if (key === 'send_file') {
      this.switchTab(1);
      return;
    }
    const id: string = this.selectedDeviceId;
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
    if (key === 'ring') {
      for (const p of list) {
        if (p instanceof PingPlugin) {
          const ok: boolean = p.sendPing('KDE Connect HarmonyOS');
          this.toastText(this.resText(ok
            ? $r('app.string.toast_ping_sent').id
            : $r('app.string.toast_ping_failed').id));
          return;
        }
      }
      this.toastText(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    if (key === 'battery') {
      const b: BatteryItem | undefined = this.batteryItems.find((x: BatteryItem) => x.deviceId === id);
      const value: string = b === undefined ? this.resText($r('app.string.toast_battery_none').id) : b.text;
      this.toastText(`${this.resText($r('app.string.action_battery').id)}: ${value}`);
      return;
    }
    // find_phone：协议方向是「桌面 → 手机」（本机没有可发的 request）；media：MPRIS 待字段表（计划 C）
    this.toastPlaceholder(key);
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
  private handlePayloadTransfer(event: NetEvent): void {
    const tid: number = event.payloadTransferId ?? 0;
    if (tid <= 0) {
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
  private async savePayload(p: PayloadTransfer): Promise<void> {
    const dir: string = this.ensureKdcDir();
    if (dir === '') {
      this.log('save failed: no host context');
      this.toastText(this.resText($r('app.string.files_save_failed').id));
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const dest: string = `${dir}/${name}`;
    const granted: boolean = await this.ensureWritePermission(name);
    if (!granted) {
      this.log(`save aborted: write permission denied for ${name}`);
      this.toastText(this.resText($r('app.string.files_need_permission').id));
      return;
    }
    try {
      const ok: boolean = native.keepPayload(p.transferId, dest);
      this.log(ok ? `saved -> ${dest}` : 'keepPayload failed');
      if (ok) {
        this.markPayloadSettled(p.transferId);
        this.toastText(`${this.resText($r('app.string.files_auto_saved').id)}: ${name}`);
      } else {
        this.toastText(this.resText($r('app.string.files_save_failed').id));
      }
    } catch (e) {
      this.log('keepPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
      this.toastText(this.resText($r('app.string.files_save_failed').id));
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
    try {
      const ok: boolean = native.discardPayload(p.transferId);
      this.log(ok ? `discarded #${p.transferId}` : 'discardPayload failed');
      this.markPayloadSettled(p.transferId);
    } catch (e) {
      this.log('discardPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
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
    this.logText = (this.logText + `[${t}] ${line}\n`).split('\n').slice(-50).join('\n');
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

  // 底部页签（自绘，供 HdsTabs 作 CustomBuilder 用）：整条悬浮胶囊由 HdsTabs 提供，
  // 激活态只做「变色 + 内缩半透明高亮」，不加边框/分隔线，视觉上保持一整个胶囊。
  // 版式对齐参考稿（我的华为底栏）：**图标在上、文字在下**。
  @Builder
  tabBuilder(index: number) {    Column({ space: 2 }) {
      SymbolGlyph(this.tabIcon(index))
        .fontSize(20)
        .fontColor([this.currentTab === index ? $r('app.color.accent_text') : $r('app.color.text_secondary')])
      Text(this.tabs[index].label)
        .fontSize(11)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTab === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .maxLines(1)
    }
    .width('100%')
    .margin({ left: 4, right: 4 })
    .padding({ top: 4, bottom: 4 })
    .borderRadius(16)
    .backgroundColor(this.currentTab === index ? $r('app.color.accent_soft') : Color.Transparent)
  }

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

  // 抽屉里实际渲染的已连接设备：收起态只取前 drawerDeviceCap 台，展开态全部
  private visibleDrawerDevices(): DeviceItem[] {
    if (this.drawerExpanded || this.connectedDevices.length <= DRAWER_DEVICE_CAP) {
      return this.connectedDevices;
    }
    return this.connectedDevices.slice(0, DRAWER_DEVICE_CAP);
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
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
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
            if (this.connectedDevices.length === 0) {
              Text($r('app.string.drawer_pick_device_hint'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
                .width('100%')
                .padding({ top: 4, bottom: 4 })
            }
            ForEach(this.visibleDrawerDevices(), (d: DeviceItem) => {
              this.drawerDeviceRow(d)
            }, (d: DeviceItem) => d.id)

            // 「展开 ⌄」只作用于**已连接设备列表**（设备多时先收起、点开看全部）；
            // 下面三个分区入口（发现/记住/手动）常驻可见可点，不参与收起
            if (this.connectedDevices.length > DRAWER_DEVICE_CAP) {
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

            this.drawerSectionRow(1, $r('app.string.discovered_devices'), this.discoveredDevices.length)
            this.drawerSectionRow(2, $r('app.string.remembered_devices'), this.rememberedDevices.length)
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
      .height('100%')
      .padding({
        left: 16,
        right: 16,
        top: this.getUIContext().px2vp(this.statusBarHeightPx) + 16,
        bottom: 16
      })
      .backgroundColor($r('app.color.bar_bg'))
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
          this.menuButton()
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
        .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 1, color: $r('app.color.card_border') })

        // 内容区 + 底部页签：HdsTabs 悬浮胶囊（官方最佳实践 bpta-spatiality-immersive）
        // barOverlap(true) 使页签悬浮于内容之上，barFloatingStyle 提供悬浮胶囊 +
        // 渐变遮罩 + systemMaterialEffect 沉浸光感（材质等级自适应设备算力）。
        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            Column() {
              DevicesTab({
                connectedDevices: this.connectedDevices,
                discoveredDevices: this.discoveredDevices,
                rememberedDevices: this.rememberedDevices,
                immersive: false,
                isWide: this.isWide,
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
                  this.onDeviceAction(key);
                },
                onOpenDevice: (d: DeviceItem): void => {
                  this.openDeviceDetail(d);
                },
                onClipboardPaste: (granted: boolean): void => {
                  this.onClipboardPasteResult(granted);
                },
                onRefreshDiscovery: (): void => {
                  this.triggerDiscoveryBroadcast();
                },
                onPairDevice: (d: DeviceItem): void => {
                  this.requestPairWith(d);
                }
              })
            }
            .padding({ top: 12, bottom: 92 })
          }
          .tabBar(this.tabBuilder(0))

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
                    }
                  })
            }
            .padding({ top: 12, bottom: 92 })
          }
          .tabBar(this.tabBuilder(1))

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
            .padding({ top: 12, bottom: 92 })
          }
          .tabBar(this.tabBuilder(2))

          TabContent() {
            Column() {
              LogsTab({
                logText: this.logText,
                immersive: false
              })
            }
            .padding({ top: 12, bottom: 92 })
          }
          .tabBar(this.tabBuilder(3))
        }
        .barPosition(BarPosition.End)
        .vertical(false)
        .barOverlap(true)
        .scrollable(false)
        .animationDuration(200)
        // TabBar 自身背景置透明：否则暗色下会在材质层下压出一块深灰底
        .barBackgroundColor(Color.Transparent)
        .barFloatingStyle({
          barWidth: { smallWidth: 300, mediumWidth: 420, largeWidth: 520 },
          barBottomMargin: this.getUIContext().px2vp(this.navBarHeightPx) + 12,
          // 显式给全透明遮罩：覆盖 HdsTabs 默认的底部渐隐（暗色下会呈一条渐黑带）
          gradientMask: { maskColor: '#00000000', maskHeight: 96 },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .layoutWeight(1)
        .width('100%')
        .onChange((index: number) => {
          this.currentTab = index;
        })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })

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
          .backgroundColor($r('app.color.card_bg'))
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
          .border({ width: 1, color: $r('app.color.card_border') })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#99000000')
        .transition(TransitionEffect.OPACITY)
      }

    }
    .width('100%')
    .height('100%')
    // 兜底底色：暗色下窗口默认背景为黑，若底部安全区未被渐变覆盖会露出一条黑带
    .backgroundColor($r('app.color.bg_grad_bottom'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
