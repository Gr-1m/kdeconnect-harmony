import native from 'libkdeconnect_napi.so';
import { NetConfig, CertPair, NetEvent } from 'libkdeconnect_napi.so';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { display } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { PacketRouter, RouterCallbacks } from '../net/PacketRouter';
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
import { colorModeOf, languageOf, LANG_SYSTEM, THEME_FOLLOW_SYSTEM } from '../common/AppSettings';
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

@Entry
@Component
struct Index {
  @State status: string = 'booting';
  @State logText: string = '';
  @State currentTab: number = 0;
  @State deviceName: string = DEFAULT_DEVICE_NAME;
  @State themeMode: number = THEME_FOLLOW_SYSTEM;
  @State language: string = LANG_SYSTEM;
  // 宽屏（平板/折叠展开）判定：>=600vp 走常驻侧栏，否则走抽屉式侧栏
  @State isWide: boolean = false;
  @State connectedDevices: DeviceItem[] = [];
  @State discoveredDevices: DeviceItem[] = [];
  @State rememberedDevices: RememberedDevice[] = [];
  // AP-1 配对确认：对端请求待确认的设备（空串 = 无弹窗）
  @State pendingPairId: string = '';
  @State pendingPairName: string = '';
  // 对端 pair 包里的 timestamp（秒）：与对端用同一值算验证码
  @State pendingPairTimestamp: number = 0;
  @State pendingPairCode: string = '';
  // 本侧已发起、等待对端确认的设备
  @State requestedPairIds: string[] = [];
  // 连接/配对会话（发现列表「连接」与手动连接共用一条状态机）：
  // idle → connecting → prompt（等用户确认配对）→ awaiting（已发请求，等对端确认）
  //   → idle（成功，跳回「已连接设备」）| failed（连接/配对失败，弹窗给出原因）
  @State sessionState: string = 'idle';
  @State sessionDeviceId: string = '';
  @State sessionName: string = '';
  @State sessionTarget: string = '';
  @State sessionError: string = '';
  @State sessionTimestamp: number = 0;
  // 会话弹窗里显示的验证码（进入 prompt/awaiting 时算一次，避免渲染期调 native）
  @State sessionCode: string = '';
  // 对端先发起了配对请求（此时弹窗上的「配对」按钮同时充当接受）
  @State sessionPeerRequested: boolean = false;
  // 配对/连接成功后的短暂提示
  @State sessionNotice: string = '';
  // 设备 Tab 分区（0 已连接 / 1 发现 / 2 记住 / 3 手动）：@Link 给 DevicesTab，
  // 配对成功后由本页切回「已连接设备」
  @State deviceSection: number = 0;
  private sessionTimerId: number = -1;
  private noticeTimerId: number = -1;
  // 失败发生在哪个阶段：connect（TCP/TLS 未建立）| pair（配对未完成）
  private sessionStage: string = 'connect';
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
      this.deviceName = String(await pref.get('deviceName', DEFAULT_DEVICE_NAME));
      this.themeMode = parseInt(String(await pref.get('themeMode', '0')), 10) || THEME_FOLLOW_SYSTEM;
      this.language = String(await pref.get('language', LANG_SYSTEM));
      // AP-3：信任设备（含旧的 rememberedDevices 一次性迁移）
      this.trustedDevices = await TrustStore.load(ctx);
      this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        const r: RememberedDevice = { id: t.id, name: t.name };
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
  private handlePairRequest(deviceId: string, timestamp: number): void {
    if (deviceId === '') {
      return;
    }
    // 本侧刚连上该设备（会话弹窗已在屏幕上）：不再叠加第二个弹窗，
    // 弹窗上的「配对」按钮即接受（对端先请求时本侧同帧回 pair:true 是标准做法）。
    if (this.sessionDeviceId === deviceId && this.sessionState === 'prompt') {
      this.sessionPeerRequested = true;
      this.sessionTimestamp = timestamp;
      this.sessionCode = this.computePairCode(deviceId, timestamp);
      this.log(`peer requested pairing first (${deviceId}) — confirm in dialog`);
      return;
    }
    this.pendingPairId = deviceId;
    this.pendingPairName = this.displayNameOf(deviceId);
    this.pendingPairTimestamp = timestamp;
    this.pendingPairCode = this.computePairCode(deviceId, timestamp);
    this.log(`pair request from ${this.pendingPairName} (ts=${timestamp}) — awaiting confirmation`);
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

  // 用户在确认框点「接受」
  private acceptPairing(): void {
    const id: string = this.pendingPairId;
    if (id === '' || this.router === undefined) {
      return;
    }
    this.router.acceptPair(id);
    this.pendingPairId = '';
    this.pendingPairName = '';
  }

  // 用户在确认框点「拒绝」
  private rejectPairing(): void {
    const id: string = this.pendingPairId;
    if (id === '' || this.router === undefined) {
      return;
    }
    this.router.rejectPair(id);
    this.pendingPairId = '';
    this.pendingPairName = '';
    this.log(`pairing rejected: ${id}`);
  }

  // 已连接设备行「配对」按钮：本侧发起请求，等待对端确认
  private requestPairWith(d: DeviceItem): void {
    if (this.router === undefined) {
      return;
    }
    const ts: number = Math.floor(Date.now() / 1000);
    this.router.requestPair(d.id, ts);
    if (!this.requestedPairIds.includes(d.id)) {
      this.requestedPairIds = this.requestedPairIds.concat([d.id]);
    }
    this.log(`pair request sent: ${d.name}`);
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
    if (this.pendingPairId === deviceId) {
      this.pendingPairId = '';
      this.pendingPairName = '';
    }
    const name: string = this.displayNameOf(deviceId);
    const exists: boolean = this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId);
    if (!exists) {
      // AP-3：把对端证书一并入库（钉扎判定在 native，这里只存展示/后续迁移用）
      let peerCert: string = '';
      try {
        peerCert = native.getPeerCertificate(deviceId);
      } catch (e) {
        this.log('getPeerCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      }
      const entry: TrustedDevice = {
        id: deviceId,
        name: name,
        certPem: peerCert,
        pairedAt: Date.now()
      };
      this.trustedDevices = this.trustedDevices.concat([entry]);
      this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        const r: RememberedDevice = { id: t.id, name: t.name };
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
    }
    // 会话命中该设备 → 配对成功：提示并自动跳回「已连接设备」
    if (this.sessionDeviceId === deviceId && this.sessionState !== 'idle' && this.sessionState !== 'failed') {
      this.succeedSession();
      this.log('pair success -> switch to connected devices');
    }
  }

  // 对端发 unpair {pair:false} 或本侧解除配对时移出记住列表
  private handleUnpaired(deviceId: string): void {
    this.requestedPairIds = this.requestedPairIds.filter((id: string) => id !== deviceId);
    if (this.pendingPairId === deviceId) {
      this.pendingPairId = '';
      this.pendingPairName = '';
    }
    // 会话中的设备被解除/断开：直接收起弹窗（属于用户显式动作，不算失败）
    if (this.sessionDeviceId === deviceId && this.sessionState !== 'idle') {
      this.dismissSession();
    }
    const before: number = this.trustedDevices.length;
    this.trustedDevices = this.trustedDevices.filter((t: TrustedDevice) => t.id !== deviceId);
    if (this.trustedDevices.length !== before) {
      // WP-2：解除钉扎（必须在 TrustStore 移除之前调用）
      try {
        native.removeTrustedCertificate(deviceId);
      } catch (e) {
        this.log('removeTrustedCertificate unavailable: ' + (e instanceof Error ? e.message : 'unknown'));
      }
      this.rememberedDevices = this.trustedDevices.map((t: TrustedDevice) => {
        const r: RememberedDevice = { id: t.id, name: t.name };
        return r;
      });
      this.persistTrust();
      this.log(`unpaired ${deviceId}`);
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
          deviceType: ''
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
          const dev: DeviceItem = {
            id: cid,
            name: event.deviceName ?? cid,
            host: '',
            tcpPort: 0,
            deviceType: ''
          };
          // 同一设备可能重复触发 connected，先去重再追加；并从发现列表移入连接列表
          this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== cid);
          this.connectedDevices = this.connectedDevices.concat([dev]);
          this.discoveredDevices = this.discoveredDevices.filter((d: DeviceItem) => d.id !== cid);
          // 会话：连接阶段完成 → 已配对直接跳过去；未配对则弹配对确认
          if (this.sessionState === 'connecting') {
            if (this.isTrusted(cid)) {
              this.sessionDeviceId = cid;
              this.sessionName = event.deviceName ?? this.sessionName;
              this.succeedSession();
              this.log(`connected ${cid} (already paired) -> switch to connected devices`);
            } else {
              this.promptPairing(cid, event.deviceName ?? '');
            }
          }
        }
        this.log(`connected ${event.deviceId} role=${event.role}`);
        break;
      }
      case 'disconnected': {
        const did: string = event.deviceId ?? '';
        this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== did);
        this.batteryItems = this.batteryItems.filter((b: BatteryItem) => b.deviceId !== did);
        // AP-4：断链卸载该设备插件（onDestroy 必达）
        this.pluginHost?.unloadForDevice(did);
        // 会话中的设备断链 → 连接/配对失败（未建连就被拒时 native 也可能只派发 disconnected）
        if (did !== '' && this.sessionDeviceId === did && this.sessionState !== 'idle') {
          this.failSession('disconnected');
        }
        this.log(`disconnected ${event.deviceId}`);
        break;
      }
      case 'deviceLost': {
        const lid: string = event.deviceId ?? '';
        this.discoveredDevices = this.discoveredDevices.filter((d: DeviceItem) => d.id !== lid);
        this.log(`lost ${event.deviceId}`);
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
              (d: DeviceItem) => d.id === pid ? { id: d.id, name: name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType } : d);
            this.discoveredDevices = this.discoveredDevices.map(
              (d: DeviceItem) => d.id === pid ? { id: d.id, name: name, host: d.host, tcpPort: d.tcpPort, deviceType: d.deviceType } : d);
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
        // 会话进行中报错 → 直接判定失败（否则用户等到超时才看到结果）
        if (this.sessionState === 'connecting' || this.sessionState === 'awaiting'
          || this.sessionState === 'prompt') {
          const eid: string = event.deviceId ?? '';
          if (eid === '' || this.sessionDeviceId === '' || this.sessionDeviceId === eid) {
            this.failSession(em.length > 0 ? em : `error ${event.errorCode}`);
          }
        }
        break;
      }
      default:
        this.log(`event: ${event.type}`);
        break;
    }
  }

  // 发现列表「连接」按钮：走与手动连接相同的会话（连接中 → 配对弹窗 → 跳已连接）
  private connectDevice(d: DeviceItem): void {
    if (d.host === '' || d.tcpPort <= 0) {
      this.log('connect skipped: no address');
      return;
    }
    this.startSession(d.id, d.name, d.host, d.tcpPort);
  }

  // 连接列表「断开」按钮：先发 unpair {pair:false} 清除 KDE 配对记录再断开
  // （否则断开后再连会命中 KDE 残留配对态 → "pairing error Timed out"）
  private disconnectDevice(d: DeviceItem): void {
    this.log(`disconnect ${d.id} (unpair first)`);
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
    // 短延迟确保 unpair 帧先发出（sendPacket 为同步直写内核缓冲区，close 后内核仍会发尽）
    setTimeout(() => {
      try {
        native.disconnect(d.id);
        this.log('disconnect ok');
      } catch (e) {
        this.log('disconnect failed: ' + (e instanceof Error ? e.message : 'unknown'));
      }
    }, 200);
  }

  // 手动连接（可选功能）：host:port 直连，与发现列表「连接」同一条会话状态机
  private manualConnect(host: string, port: number): void {
    this.startSession('', `${host}:${port}`, host, port);
  }

  // ---- 连接/配对会话 ----

  private isTrusted(deviceId: string): boolean {
    return this.trustedDevices.some((t: TrustedDevice) => t.id === deviceId);
  }

  private clearSessionTimer(): void {
    if (this.sessionTimerId !== -1) {
      clearTimeout(this.sessionTimerId);
      this.sessionTimerId = -1;
    }
  }

  private armSessionTimer(ms: number, reason: string): void {
    this.clearSessionTimer();
    this.sessionTimerId = setTimeout((): void => {
      this.sessionTimerId = -1;
      this.failSession(reason);
    }, ms);
  }

  // 统一入口：立即弹「连接中」模态（点击连接即时有反馈），连接完成后再切配对确认
  private startSession(id: string, name: string, host: string, port: number): void {
    if (this.sessionState === 'connecting' || this.sessionState === 'awaiting') {
      this.log(`session busy (${this.sessionState}), ignore ${host}:${port}`);
      return;
    }
    this.clearSessionTimer();
    this.sessionDeviceId = id;
    this.sessionName = name.length > 0 ? name : `${host}:${port}`;
    this.sessionTarget = `${host}:${port}`;
    this.sessionError = '';
    this.sessionPeerRequested = false;
    this.sessionTimestamp = Math.floor(Date.now() / 1000);
    this.sessionState = 'connecting';
    this.sessionStage = 'connect';
    this.log(`connect ${this.sessionTarget}`);
    try {
      native.connectToPeer(host, port);
    } catch (e) {
      this.failSession('connectToPeer failed: ' + (e instanceof Error ? e.message : 'unknown'));
      return;
    }
    this.armSessionTimer(CONNECT_TIMEOUT_MS, 'connect timeout');
  }

  // 已连接但未配对 → 弹配对确认（显示验证码，与对端同一 timestamp 计算）
  private promptPairing(deviceId: string, name: string): void {
    this.clearSessionTimer();
    this.sessionDeviceId = deviceId;
    if (name.length > 0) {
      this.sessionName = name;
    }
    this.sessionTimestamp = Math.floor(Date.now() / 1000);
    this.sessionCode = this.computePairCode(deviceId, this.sessionTimestamp);
    this.sessionState = 'prompt';
    this.sessionStage = 'pair';
    this.log(`connected ${deviceId} — awaiting pair confirmation`);
  }

  // 弹窗「配对」：发 pair:true（若对端已先请求，本帧同时充当接受）
  private confirmPairInSession(): void {
    const id: string = this.sessionDeviceId;
    if (id === '' || this.router === undefined) {
      return;
    }
    this.router.requestPair(id, this.sessionTimestamp);
    if (!this.requestedPairIds.includes(id)) {
      this.requestedPairIds = this.requestedPairIds.concat([id]);
    }
    this.sessionState = 'awaiting';
    this.armSessionTimer(PAIR_TIMEOUT_MS, 'pair not confirmed');
  }

  // 弹窗「取消」：仅关闭会话，保留已建立的连接（之后可从「已连接设备」再配对）
  private cancelSession(): void {
    this.clearSessionTimer();
    const id: string = this.sessionDeviceId;
    this.sessionState = 'idle';
    this.sessionError = '';
    this.sessionPeerRequested = false;
    this.sessionCode = '';
    if (id !== '') {
      this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== id);
    }
    this.log('connect/pair session cancelled by user');
  }

  private failSession(reason: string): void {
    this.clearSessionTimer();
    const id: string = this.sessionDeviceId;
    this.sessionState = 'failed';
    this.sessionError = reason;
    this.sessionCode = '';
    this.sessionPeerRequested = false;
    if (id !== '') {
      this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== id);
    }
    this.log(`session failed: ${reason}${id !== '' ? ' (' + id + ')' : ''}`);
  }

  private dismissSession(): void {
    this.sessionState = 'idle';
    this.sessionError = '';
    this.sessionCode = '';
  }

  // 成功：提示 + 自动跳回「已连接设备」分区
  private succeedSession(): void {
    this.clearSessionTimer();
    const id: string = this.sessionDeviceId;
    this.sessionState = 'idle';
    this.sessionError = '';
    this.sessionCode = '';
    this.sessionPeerRequested = false;
    this.deviceSection = 0;
    if (id !== '') {
      this.requestedPairIds = this.requestedPairIds.filter((x: string) => x !== id);
    }
    this.showNotice('ok');
  }

  // 会话弹窗标题（按状态切换）
  private sessionTitle(): ResourceStr {
    if (this.sessionState === 'failed') {
      return this.sessionStage === 'connect' ? $r('app.string.connect_failed') : $r('app.string.pair_failed');
    }
    if (this.sessionState === 'prompt' || this.sessionState === 'awaiting') {
      return $r('app.string.pair_dialog_title_outgoing');
    }
    return $r('app.string.connect_connecting');
  }

  private showNotice(kind: string): void {
    this.sessionNotice = kind;
    if (this.noticeTimerId !== -1) {
      clearTimeout(this.noticeTimerId);
    }
    this.noticeTimerId = setTimeout((): void => {
      this.noticeTimerId = -1;
      this.sessionNotice = '';
    }, NOTICE_MS);
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

  private savePayload(p: PayloadTransfer): void {
    const dir: string = this.ensureKdcDir();
    if (dir === '') {
      this.log('save failed: no host context');
      return;
    }
    const name: string = this.sanitizeFileName(p.fileName, p.transferId);
    const dest: string = `${dir}/${name}`;
    try {
      const ok: boolean = native.keepPayload(p.transferId, dest);
      this.log(ok ? `saved -> ${dest}` : 'keepPayload failed');
      if (ok) {
        this.markPayloadSettled(p.transferId);
      }
    } catch (e) {
      this.log('keepPayload error: ' + (e instanceof Error ? e.message : 'unknown'));
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
    const fileName: string = srcUri.substring(srcUri.lastIndexOf('/') + 1);
    const cachePath: string = `${hostCtx.cacheDir}/${fileName}`;
    try {
      // picker 返回的 URI 直接交给 native 读不到（沙箱外），先复制进 cacheDir
      await fileIo.copyFile(srcUri, cachePath);
    } catch (e) {
      this.log('send file: copy into sandbox failed');
      return;
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

  // 底部页签（自绘，供 HdsTabs 作 CustomBuilder 用）：整条悬浮胶囊由 HdsTabs 提供，
  // 激活态只做「变色 + 内缩半透明高亮」，不加边框/分隔线，视觉上保持一整个胶囊。
  @Builder
  tabBuilder(index: number) {
    Column() {
      Text(this.tabs[index].label)
        .fontSize(13)
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentTab === index ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
        .maxLines(1)
    }
    .width('100%')
    .margin({ left: 4, right: 4 })
    .padding({ top: 6, bottom: 6 })
    .borderRadius(16)
    .backgroundColor(this.currentTab === index ? $r('app.color.accent_soft') : Color.Transparent)
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
        // 标题区
        Row({ space: 10 }) {
          Text('KDE Connect')
            .fontSize(28)
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
                onDisconnectDevice: (d: DeviceItem): void => {
                  this.disconnectDevice(d);
                },
                onConnectDevice: (d: DeviceItem): void => {
                  this.connectDevice(d);
                },
                onManualConnect: (host: string, port: number): void => {
                  this.manualConnect(host, port);
                },
                onPairDevice: (d: DeviceItem): void => {
                  this.requestPairWith(d);
                }
              })
            }
            .padding({ bottom: 92 })
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
            .padding({ bottom: 92 })
          }
          .tabBar(this.tabBuilder(1))

          TabContent() {
            Column() {
              SettingsTab({
                deviceId: this.deviceId,
                deviceName: this.deviceName,
                statusText: this.status,
                themeMode: this.themeMode,
                language: this.language,
                immersive: false,
                onRenameDevice: (name: string): void => {
                  this.renameDevice(name);
                },
                onThemeChange: (mode: number): void => {
                  this.applyTheme(mode, true);
                },
                onLanguageChange: (lang: string): void => {
                  this.applyLanguage(lang, true);
                }
              })
            }
            .padding({ bottom: 92 })
          }
          .tabBar(this.tabBuilder(2))

          TabContent() {
            Column() {
              LogsTab({
                logText: this.logText,
                immersive: false
              })
            }
            .padding({ bottom: 92 })
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

      // AP-1 配对确认弹窗（模态；必须明确接受/拒绝；验证码 AP-1b 接 native 对端证书后填真实值）
      if (this.pendingPairId !== '') {
        Column() {
          Column({ space: 14 }) {
            Text($r('app.string.pair_dialog_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.pendingPairName)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Column({ space: 4 }) {
              Text($r('app.string.pair_dialog_code_label'))
                .fontSize(12)
                .fontColor($r('app.color.text_muted'))
              Text(this.pendingPairCode.length > 0 ? this.pendingPairCode : '-- -- -- --')
                .fontSize(28)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.accent_text'))
                .fontFamily('monospace')
              if (this.pendingPairCode.length === 0) {
                Text($r('app.string.pair_code_unavailable'))
                  .fontSize(10)
                  .fontColor($r('app.color.text_muted'))
              }
            }
            Text($r('app.string.pair_dialog_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
            Row({ space: 10 }) {
              Button($r('app.string.pair_reject'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.danger_bg'))
                .fontColor($r('app.color.danger_text'))
                .borderRadius(12)
                .onClick(() => {
                  this.rejectPairing();
                })
              Button($r('app.string.pair_accept'))
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor($r('app.color.accent'))
                .borderRadius(12)
                .onClick(() => {
                  this.acceptPairing();
                })
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

      // 连接/配对会话弹窗：点「连接」立刻可见（连接中 → 配对确认 → 等待对端 → 失败）
      if (this.sessionState !== 'idle') {
        Column() {
          Column({ space: 14 }) {
            Text(this.sessionTitle())
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.sessionName)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.sessionState === 'connecting') {
              Text(this.sessionTarget)
                .fontSize(11)
                .fontColor($r('app.color.text_muted'))
                .fontFamily('monospace')
            }
            if (this.sessionState === 'prompt' || this.sessionState === 'awaiting') {
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
            }
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
            if (this.sessionState === 'failed') {
              Text(this.sessionError.length > 0 ? this.sessionError : 'unknown')
                .fontSize(12)
                .fontColor($r('app.color.danger_text'))
                .textAlign(TextAlign.Center)
            }
            Row({ space: 10 }) {
              if (this.sessionState === 'prompt') {
                Button($r('app.string.action_cancel'))
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(14)
                  .backgroundColor($r('app.color.danger_bg'))
                  .fontColor($r('app.color.danger_text'))
                  .borderRadius(12)
                  .onClick(() => {
                    this.cancelSession();
                  })
                Button($r('app.string.pair_action'))
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(14)
                  .backgroundColor($r('app.color.accent'))
                  .borderRadius(12)
                  .onClick(() => {
                    this.confirmPairInSession();
                  })
              } else if (this.sessionState === 'failed') {
                Button($r('app.string.action_close'))
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(14)
                  .backgroundColor($r('app.color.card_bg'))
                  .fontColor($r('app.color.text_primary'))
                  .borderRadius(12)
                  .onClick(() => {
                    this.dismissSession();
                  })
              } else {
                Button($r('app.string.action_cancel'))
                  .layoutWeight(1)
                  .height(42)
                  .fontSize(14)
                  .backgroundColor($r('app.color.danger_bg'))
                  .fontColor($r('app.color.danger_text'))
                  .borderRadius(12)
                  .onClick(() => {
                    this.cancelSession();
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

      // 配对成功提示（跳转「已连接设备」后的短反馈）
      if (this.sessionNotice !== '') {
        Column() {
          Text($r('app.string.pair_success'))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(999)
            .backgroundColor($r('app.color.card_bg'))
            .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
            .border({ width: 1, color: $r('app.color.card_border') })
        }
        .width('100%')
        .padding({ top: this.getUIContext().px2vp(this.statusBarHeightPx) + 64 })
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    // 兜底底色：暗色下窗口默认背景为黑，若底部安全区未被渐变覆盖会露出一条黑带
    .backgroundColor($r('app.color.bg_grad_bottom'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
