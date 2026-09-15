import { radio } from '@kit.TelephonyKit';
import { PluginBase } from './PluginBase';

// 网络状态上报插件（kdeconnect.connectivity_report）——MSG112 §2。
// 只发不收（与 Android ConnectivityReportPlugin 一致）：对端 Information 页显示移动网络类型 + 信号强度。
// body: { signalStrengths: { "default": { networkType: "5G", signalStrength: 4 } } }
// 权限：ohos.permission.GET_NETWORK_INFO（module.json5 已声明）。
// 无蜂窝（平板/WiFi-only）时取不到信号信息 → 本轮不发包（catch 静默），不影响其它功能。
interface SignalStrengthEntry {
  networkType: string;
  signalStrength: number;
}

interface ConnectivityBody {
  signalStrengths: Record<string, SignalStrengthEntry>;
}

const DEFAULT_SLOT: number = 0;
const CONNECTIVITY_POLL_MS: number = 60000;

export class ConnectivityReportPlugin extends PluginBase {
  private lastType: string = '';
  private lastLevel: number = -1;
  private timerId: number = -1;

  constructor() {
    super();
    this.displayName = 'ConnectivityReport';
    this.description = 'Report mobile network signal to the peer';
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

  // onlyWhenChanged=true 时，信号无变化则不发包（轮询兜底路径）
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

  // 读移动网络信号：取信号最强的一条（双卡时避免随机取到弱卡）
  private readSignal(): SignalStrengthEntry | undefined {
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
