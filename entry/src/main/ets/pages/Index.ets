import native from 'libkdeconnect_napi.so';
import { NetConfig, CertPair, NetEvent } from 'libkdeconnect_napi.so';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { PacketRouter } from '../net/PacketRouter';
import { DeviceItem, RememberedDevice } from '../model/DeviceModels';
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

const DEFAULT_DEVICE_NAME: string = 'kdeconnect-harmony';

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
      this.loadRememberedDevices(String(await pref.get('rememberedDevices', '[]')));
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
      native.init((event: NetEvent) => self.handleEvent(event));
    } catch (e) {
      this.status = 'init failed: ' + (e instanceof Error ? e.message : 'unknown');
      return;
    }
    this.router = new PacketRouter(this.deviceId, this.deviceName, 'phone',
      (msg: string) => this.log(msg),
      (id: string) => this.handlePaired(id),
      (id: string) => this.handleUnpaired(id));
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
      native.start(cfg);
      this.status = 'running';
    } catch (e) {
      this.status = 'start failed: ' + (e instanceof Error ? e.message : 'unknown');
    }
  }

  // 解析持久化的已配对设备列表（JSON 数组 [{id, name}]）
  private loadRememberedDevices(raw: string): void {
    try {
      const parsed: Array<Record<string, string>> = JSON.parse(raw) as Array<Record<string, string>>;
      const arr: RememberedDevice[] = [];
      for (const it of parsed) {
        const id: string = it['id'] ?? '';
        if (id !== '') {
          arr.push({ id: id, name: it['name'] ?? id });
        }
      }
      this.rememberedDevices = arr;
    } catch (e) {
      this.rememberedDevices = [];
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
      this.log('persist settings failed');
    }
  }

  private async persistRememberedDevices(): Promise<void> {
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return;
      }
      const pref = await preferences.getPreferences(hostCtx, 'kdeconnect');
      await pref.put('rememberedDevices', JSON.stringify(this.rememberedDevices));
      await pref.flush();
    } catch (e) {
      this.log('persist remembered failed');
    }
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

  // PacketRouter 配对接受回调（骨架阶段为自动接受；AP-1 将改为确认 UI 后触发）
  private handlePaired(deviceId: string): void {
    if (deviceId === '') {
      return;
    }
    let name: string = deviceId;
    const conn: DeviceItem | undefined = this.connectedDevices.find((d: DeviceItem) => d.id === deviceId);
    if (conn !== undefined) {
      name = conn.name;
    } else {
      const disc: DeviceItem | undefined = this.discoveredDevices.find((d: DeviceItem) => d.id === deviceId);
      if (disc !== undefined) {
        name = disc.name;
      }
    }
    const exists: boolean = this.rememberedDevices.some((r: RememberedDevice) => r.id === deviceId);
    if (!exists) {
      const item: RememberedDevice = { id: deviceId, name: name };
      this.rememberedDevices = this.rememberedDevices.concat([item]);
      this.persistRememberedDevices();
      this.log(`paired with ${deviceId}`);
    }
  }

  // 对端发 unpair {pair:false} 或本侧解除配对时移出记住列表
  private handleUnpaired(deviceId: string): void {
    const before: number = this.rememberedDevices.length;
    this.rememberedDevices = this.rememberedDevices.filter((r: RememberedDevice) => r.id !== deviceId);
    if (this.rememberedDevices.length !== before) {
      this.persistRememberedDevices();
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
        }
        this.log(`connected ${event.deviceId} role=${event.role}`);
        break;
      }
      case 'disconnected': {
        const did: string = event.deviceId ?? '';
        this.connectedDevices = this.connectedDevices.filter((d: DeviceItem) => d.id !== did);
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
      case 'error':
        this.log(`error ${event.errorCode}: ${event.errorMessage}`);
        break;
      default:
        this.log(`event: ${event.type}`);
        break;
    }
  }

  // 发现列表「连接」按钮：向对端发起 TCP（配对确认 UI 为 AP-1，当前由 PacketRouter 骨架自动接受）
  private connectDevice(d: DeviceItem): void {
    if (d.host === '' || d.tcpPort <= 0) {
      this.log('connect skipped: no address');
      return;
    }
    this.log(`connectToPeer ${d.host}:${d.tcpPort}`);
    try {
      native.connectToPeer(d.host, d.tcpPort);
      this.log('connectToPeer ok');
    } catch (e) {
      this.log('connectToPeer failed: ' + (e instanceof Error ? e.message : 'unknown'));
    }
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

  // 手动连接（可选功能）：host:port 直连
  private manualConnect(host: string, port: number): void {
    this.log(`manual connectToPeer ${host}:${port}`);
    try {
      native.connectToPeer(host, port);
      this.log('connectToPeer ok');
    } catch (e) {
      this.log('connectToPeer failed: ' + (e instanceof Error ? e.message : 'unknown'));
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
                onDisconnectDevice: (d: DeviceItem) => this.disconnectDevice(d),
                onConnectDevice: (d: DeviceItem) => this.connectDevice(d),
                onManualConnect: (host: string, port: number) => this.manualConnect(host, port)
              })
            }
            .padding({ bottom: 92 })
          }
          .tabBar(this.tabBuilder(0))

          TabContent() {
            Column() {
              FilesTab({
                connectedCount: this.connectedDevices.length,
                immersive: false
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
                onRenameDevice: (name: string) => this.renameDevice(name),
                onThemeChange: (mode: number) => this.applyTheme(mode, true),
                onLanguageChange: (lang: string) => this.applyLanguage(lang, true)
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
        .barFloatingStyle({
          barWidth: { smallWidth: 300, mediumWidth: 420, largeWidth: 520 },
          barBottomMargin: this.getUIContext().px2vp(this.navBarHeightPx) + 12,
          gradientMask: { maskColor: $r('app.color.mask_fade'), maskHeight: 96 },
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
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
