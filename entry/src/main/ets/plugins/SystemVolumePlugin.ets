import { PluginBase } from './PluginBase';

// 「系统音量」插件（kdeconnect.systemvolume，2026-09-18 用户要求）：
// 控对端**系统/音频输出**音量，与 MPRIS（播放器音量）**分区分开**。
// 价值场景：播放器不暴露音量（如 Firefox 的 MPRIS 无 volume）或**根本没有播放器**时，
// 仍能调对端系统音量。
//
// 协议依据（kdeconnect-meta/schemas，已核对本机参考仓库）：
//   收 kdeconnect.systemvolume：
//      全量：{ "sinkList": [ { name, description, muted, volume, maxVolume, enabled }, … ] }
//      增量：{ name, volume, muted, enabled }            ← volume 是**百分比 0-100**
//   发 kdeconnect.systemvolume.request：
//      取列表：{ "requestSinks": true }
//      设置：  { name, volume(0-100), muted, enabled: true }
interface SysSink {
  name: string;
  description: string;
  muted: boolean;
  volume: number;    // 列表里是绝对刻度
  maxVolume: number; // 与 volume 配合换算成百分比
  enabled: boolean;
}

interface SysVolumeBody {
  sinkList?: SysSink[];
  name?: string;
  volume?: number;
  muted?: boolean;
  enabled?: boolean;
  requestSinks?: boolean;
}

export class SystemVolumePlugin extends PluginBase {
  private sinks: SysSink[] = [];
  private primary: string = '';
  private volumePct: number = -1; // -1 = 未知（对端还没给）
  private muted: boolean = false;

  constructor() {
    super();
    this.displayName = 'SystemVolume';
    this.description = 'Control peer system volume';
    this.supportedPacketTypes = ['kdeconnect.systemvolume'];
    this.outgoingPacketTypes = ['kdeconnect.systemvolume.request'];
  }

  onCreate(): boolean {
    // 建链即拉一次输出设备列表
    this.requestSinks();
    this.emit();
    return true;
  }

  onDestroy(): void {
    this.sinks = [];
    this.primary = '';
    this.volumePct = -1;
    this.muted = false;
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.systemvolume') {
      return false;
    }
    const b: SysVolumeBody = body as SysVolumeBody;
    if (b.sinkList !== undefined) {
      this.sinks = b.sinkList;
      if (this.primary.length === 0 && this.sinks.length > 0) {
        this.pickPrimary();
      }
    }
    // 目标 sink：包里有 name 用它；否则用我们选定的主输出
    const target: string = b.name !== undefined && b.name.length > 0 ? b.name : this.primary;
    if (this.primary.length === 0 && target.length > 0) {
      this.primary = target;
    }
    if (b.name !== undefined && b.name === this.primary) {
      if (b.volume !== undefined) {
        this.volumePct = this.percentOf(b.volume);
      }
      if (b.muted !== undefined) {
        this.muted = b.muted;
      }
    }
    // 列表到达时用列表里那条主输出的值刷新一次
    if (b.sinkList !== undefined) {
      const p: SysSink | undefined = this.findPrimary();
      if (p !== undefined) {
        this.volumePct = this.percentOfSink(p);
        this.muted = p.muted;
      }
    }
    this.emit();
    return true;
  }

  // ---------- UI 读数 ----------
  hasData(): boolean {
    return this.volumePct >= 0;
  }

  volume(): number {
    return this.volumePct;
  }

  isMuted(): boolean {
    return this.muted;
  }

  // ---------- UI 动作（返回 false 表示发送失败，由 UI 决定提示）----------
  requestSinks(): boolean {
    const body: SysVolumeBody = { requestSinks: true };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    this.log(ok ? 'request sinks sent' : 'request sinks failed');
    return ok;
  }

  setVolume(v: number): boolean {
    if (this.primary.length === 0) {
      this.log('set volume skipped: no sink');
      return false;
    }
    let pct: number = Math.round(v);
    if (pct < 0) {
      pct = 0;
    }
    if (pct > 100) {
      pct = 100;
    }
    // 乐观更新（对端随后会推回真实值）
    this.volumePct = pct;
    this.emit();
    const body: SysVolumeBody = { name: this.primary, volume: pct, muted: this.muted, enabled: true };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    this.log(ok ? `set volume sent: ${pct}%` : `set volume failed: ${pct}%`);
    return ok;
  }

  toggleMute(): boolean {
    if (this.primary.length === 0) {
      return false;
    }
    this.muted = !this.muted;
    this.emit();
    const body: SysVolumeBody = { name: this.primary, muted: this.muted, enabled: true };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    this.log(ok ? `mute -> ${this.muted}` : 'mute send failed');
    return ok;
  }

  // ---------- 内部 ----------
  private pickPrimary(): void {
    // 优先 enabled 的 sink，其次列表第一个
    for (const s of this.sinks) {
      if (s.enabled) {
        this.primary = s.name;
        return;
      }
    }
    this.primary = this.sinks[0].name;
  }

  private findPrimary(): SysSink | undefined {
    for (const s of this.sinks) {
      if (s.name === this.primary) {
        return s;
      }
    }
    return undefined;
  }

  private percentOfSink(s: SysSink): number {
    if (s.maxVolume > 0) {
      return Math.round(s.volume * 100 / s.maxVolume);
    }
    return this.percentOf(s.volume);
  }

  private percentOf(v: number): number {
    // 增量包的 volume 已是百分比；异常值夹到 0-100
    if (v < 0) {
      return 0;
    }
    return v > 100 ? 100 : Math.round(v);
  }

  private emit(): void {
    // 走标量通道（ARKTS_GUIDE：只发短字符串用 notify）⇒ "<volume>|<muted>"
    const v: string = this.volumePct < 0 ? '?' : `${this.volumePct}`;
    this.notify('sysvolume', `${v}|${this.muted ? '1' : '0'}`);
  }
}
