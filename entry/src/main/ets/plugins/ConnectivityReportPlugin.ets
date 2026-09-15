import { radio } from '@kit.TelephonyKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { connection } from '@kit.NetworkKit';
import { PluginBase } from './PluginBase';

// 网络状态上报插件（kdeconnect.connectivity_report）——MSG112 §2。
// 只发不收（与 Android ConnectivityReportPlugin 一致）：对端 Information 页显示网络类型 + 信号强度。
// body: { signalStrengths: { "default": { networkType: "WiFi", signalStrength: 3 } } }
//
// 承载判定（用户 2026-09-15 反馈：明明走 WiFi，桌面却显示「移动网络 4G」）：
// 先看**默认网络的实际承载**（@ohos.net.connection bearerTypes），WiFi / 以太网优先于蜂窝，
// 只有确实走蜂窝时才报 4G/5G。
// 权限：ohos.permission.GET_NETWORK_INFO（承载查询）+ ohos.permission.GET_WIFI_INFO（WiFi 详情）。
interface SignalStrengthEntry {
  networkType: string;
  signalStrength: number;
}

interface ConnectivityBody {
  signalStrengths: Record<string, SignalStrengthEntry>;
}

const DEFAULT_SLOT: number = 0;
const CONNECTIVITY_POLL_MS: number = 60000;
// 以太网没有"信号"概念 → 用满格占位（对端只做展示）
const WIRED_LEVEL: number = 5;

export class ConnectivityReportPlugin extends PluginBase {
  private lastType: string = '';
  private lastLevel: number = -1;
  private timerId: number = -1;

  constructor() {
    super();
    this.displayName = 'ConnectivityReport';
    this.description = 'Report network type and signal to the peer';
    this.supportedPacketTypes = [];
    this.outgoingPacketTypes = ['kdeconnect.connectivity_report'];
  }

  onCreate(): boolean {
    this.sendReport(false);
    this.timerId = setInterval(() => {
      this.sendReport(true);
    }, CONNECTIVITY_POLL_MS);
    return true;
  }

  onDestroy(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  // onlyWhenChanged=true 时，类型/强度都没变则不发包（轮询兜底路径）
  sendReport(onlyWhenChanged: boolean): boolean {
    const entry: SignalStrengthEntry | undefined = this.readSignal();
    if (entry === undefined) {
      return false;
    }
    if (onlyWhenChanged && entry.networkType === this.lastType && entry.signalStrength === this.lastLevel) {
      return false;
    }
    this.lastType = entry.networkType;
    this.lastLevel = entry.signalStrength;
    const strengths: Record<string, SignalStrengthEntry> = {};
    strengths['default'] = entry;
    const body: ConnectivityBody = { signalStrengths: strengths };
    const ok: boolean = this.send('kdeconnect.connectivity_report', body);
    this.log(ok ? `connectivity report sent (${entry.networkType} level=${entry.signalStrength})`
      : 'connectivity report failed');
    return ok;
  }

  // 按当前默认网络的承载取信号；未知承载时退回蜂窝（旧行为）
  private readSignal(): SignalStrengthEntry | undefined {
    const bearer: string = this.defaultBearer();
    if (bearer === 'wifi') {
      const wifi: SignalStrengthEntry | undefined = this.readWifi();
      if (wifi !== undefined) {
        return wifi;
      }
    } else if (bearer === 'ethernet') {
      const wired: SignalStrengthEntry = { networkType: 'Ethernet', signalStrength: WIRED_LEVEL };
      return wired;
    }
    return this.readCellular();
  }

  // 默认网络承载类型：wifi / ethernet / cellular / unknown
  private defaultBearer(): string {
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net === undefined || net.netId === 0) {
        return 'unknown';
      }
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      const bearers: connection.NetBearType[] = caps.bearerTypes;
      if (bearers === undefined || bearers.length === 0) {
        return 'unknown';
      }
      for (const b of bearers) {
        if (b === connection.NetBearType.BEARER_WIFI) {
          return 'wifi';
        }
      }
      for (const b of bearers) {
        if (b === connection.NetBearType.BEARER_ETHERNET) {
          return 'ethernet';
        }
      }
      for (const b of bearers) {
        if (b === connection.NetBearType.BEARER_CELLULAR) {
          return 'cellular';
        }
      }
    } catch (e) {
      // 查询失败按未知处理
    }
    return 'unknown';
  }

  // WiFi 信号：getSignalLevel 官方量程 0–4
  private readWifi(): SignalStrengthEntry | undefined {
    try {
      const info: wifiManager.WifiLinkedInfo = wifiManager.getLinkedInfoSync();
      if (info === undefined) {
        return undefined;
      }
      const level: number = wifiManager.getSignalLevel(info.rssi, info.band);
      const entry: SignalStrengthEntry = { networkType: 'WiFi', signalStrength: level };
      return entry;
    } catch (e) {
      // 无权限 / 未连接 WiFi → 交回上层退回蜂窝
      return undefined;
    }
  }

  // 移动网络信号：取信号最强的一条（双卡时避免随机取到弱卡）
  private readCellular(): SignalStrengthEntry | undefined {
    try {
      const info: radio.SignalInformation[] = radio.getSignalInformationSync(DEFAULT_SLOT);
      if (info === undefined || info.length === 0) {
        return undefined;
      }
      let best: radio.SignalInformation = info[0];
      for (const s of info) {
        if (s.signalLevel > best.signalLevel) {
          best = s;
        }
      }
      const entry: SignalStrengthEntry = {
        networkType: ConnectivityReportPlugin.typeName(best.signalType),
        signalStrength: best.signalLevel
      };
      return entry;
    } catch (e) {
      // 无 SIM / 无权限 / 模块不可用 → 静默（不算错误）
      return undefined;
    }
  }

  private static typeName(t: radio.NetworkType): string {
    if (t === radio.NetworkType.NETWORK_TYPE_NR) {
      return '5G';
    }
    if (t === radio.NetworkType.NETWORK_TYPE_LTE) {
      return '4G';
    }
    if (t === radio.NetworkType.NETWORK_TYPE_WCDMA || t === radio.NetworkType.NETWORK_TYPE_TDSCDMA) {
      return '3G';
    }
    if (t === radio.NetworkType.NETWORK_TYPE_GSM || t === radio.NetworkType.NETWORK_TYPE_CDMA) {
      return '2G';
    }
    return 'unknown';
  }
}
