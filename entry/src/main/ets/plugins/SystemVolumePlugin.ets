// SPDX-License-Identifier: GPL-2.0-or-later
import { PluginBase } from './PluginBase';
import { PluginEvent } from './PluginEvent';
import { SystemSinkUi } from '../model/SystemVolumeModels';

// 「系统音量」插件（kdeconnect.systemvolume）——控对端**系统音频输出**：调音量 / 静音 / **选择默认输出设备**。
// 与 MPRIS（播放器音量）分区分开：播放器不暴露音量（Firefox 的 MPRIS 就没有）或根本没有播放器时，
// 这里仍能调控对端系统音频。
//
// 协议依据（kdeconnect-meta/schemas/kdeconnect.systemvolume.json + KDE/Android 源码逐条核对）：
//   收 kdeconnect.systemvolume：
//       全量：{ "sinkList": [ { name, description, muted, volume, maxVolume, enabled }, … ] }
//       增量：{ name, volume, muted, enabled }
//         ⚠️ 两条里的 `volume` 用的是**同一把尺子**：绝对刻度（见下方 ★ 1）。
//            schema 的增量示例写 `"volume": 49`（看着像百分比）属**示例误导**——KDE pulse / macOS /
//            Windows 三个后端下发的都是绝对值（pulse 是 `sink->volume()`，与 maxVolume 同刻度）。
//            本项目一律按绝对刻度处理；该「schema 表述 vs KDE 实现」的不一致已记入
//            `devdocs/EXP_LESSONS_20260919_systemvolume.md`（CodeArts MSG20 §1 要求登记）。
//   发 kdeconnect.systemvolume.request：
//       拉列表：{ "requestSinks": true }
//       调音量：{ name, volume }        ← Android sendVolume 同款
//       静音：  { name, muted }         ← Android sendMute 同款
//       选输出：{ name, enabled: true } ← Android sendEnable 同款（= 设为默认输出）
//
// ★ 字段语义（2026-09-19 逐条核对后固定，勿凭记忆改）：
//   1) `volume` 是**绝对刻度**（与 maxVolume 同刻度，pulse 端 normalVolume 通常 65536），不是 0-100。
//      依据：KDE pulse `sink->setVolume(np.get<int>("volume"))`；用户实测发 49 ⇒ 听感等于静音（0.07%）。
//   2) 三个字段都是"**有才读**"（KDE `np.has(...)`）——**不存在"缺字段被读成 0"**（我此前注释那样写过，已更正）。
//   3) 带 `volume` 会**顺带取消静音**（KDE 紧随 setVolume 无条件 `sink->setMuted(false)`）⇒ 本地也要清 muted。
//   4) `enabled` = **是否默认输出**（KDE `sink->setDefault(enabled)`；Windows/macOS 同为 isDefault）。
//      ⇒ 「选择输出设备」= 单独发 `{name, enabled: true}`；**调音量/静音绝不能带 enabled**，
//      否则会顺带切走对端默认输出（我此前多塞了 enabled，用户实测发现"调哪个音量就用哪个输出"）。
//
// ★ 数据流（单一数据源 + 单一派生 + 单一通道）：
//   · 单一数据源：sinks[]（每个 sink 各带自己的 maxVolume 与绝对刻度音量；默认与否只认 `enabled`）；
//   · 单一派生：syncRows() 把 sinks[] 写成 UI 行对象（唯一换算点，且保持行对象实例稳定）；
//   · 单一通道：任何变化都 notifyEvent 推**整份**行数组（幂等）⇒ UI 不需要"主动拉取 / 二次同步"补丁。
//   · **没有**"本地默认 sink"这种平行状态：谁是默认输出只认协议 `enabled`（本地点选只做乐观改标记）。
//
// ★ UI 刷新前提（勿回退）：行对象必须是 @Observed 且实例稳定、行组件用 @ObjectLink ——
//   因为 ForEach 的键（name）不变时不会重建子组件，传标量 @Prop 会导致"命令有效但 UI 不刷新"（实测踩过）。

// 协议 DTO（字段名/可选性与 schema 严格一致；**只在本文件内使用**，不外泄给 UI）
interface SysSinkDto {
  name?: string;
  description?: string;
  muted?: boolean;
  volume?: number;
  maxVolume?: number;
  enabled?: boolean;
}

interface SysVolumeBodyDto {
  sinkList?: SysSinkDto[];
  name?: string;
  volume?: number;
  muted?: boolean;
  enabled?: boolean;
  requestSinks?: boolean;
}

// 单个 sink 的内部状态：只存**协议原值**（绝对刻度），百分比由 pct() 现算。
// 这样"刻度"只有一份，不存在"UI 百分比 + 插件绝对值"两份真相对不上的可能。
class SysSinkState {
  name: string = '';
  description: string = '';
  maxVolume: number = 0;   // 0 = 该 sink 的刻度未知（还没收到带 maxVolume 的列表）
  volumeAbs: number = -1;  // -1 = 未知
  muted: boolean = false;
  enabled: boolean = false;  // 协议 enabled = 是否对端默认输出（UI 单选钮读它）

  // 0-100；刻度或音量未知时返回 -1（**不猜测**：旧的 `abs > 100 ? 100 : abs` 兜底已删除）
  pct(): number {
    if (this.maxVolume <= 0 || this.volumeAbs < 0) {
      return -1;
    }
    const p: number = Math.round(this.volumeAbs * 100 / this.maxVolume);
    return p > 100 ? 100 : (p < 0 ? 0 : p);
  }
}

export class SystemVolumePlugin extends PluginBase {
  private sinks: SysSinkState[] = [];
  // UI 行对象的**渲染缓存**（实例稳定）：内容由 sinks[] 派生，唯一读者是 UI。
  // 之所以缓存实例：UI 侧 ForEach 的键是 name，键不变就不会重建子组件，
  // 必须靠 @Observed 实例原地更新 + 子组件 @ObjectLink 才能刷新（详见 SystemVolumeModels.ets 头注释）。
  private rows: SystemSinkUi[] = [];

  constructor() {
    super();
    this.displayName = 'SystemVolume';
    this.description = 'Control peer system volume';
    this.supportedPacketTypes = ['kdeconnect.systemvolume'];
    this.outgoingPacketTypes = ['kdeconnect.systemvolume.request'];
  }

  onCreate(): boolean {
    // 建链即拉全量列表；并先推一次空数组（若本设备上次残留了行，直接清干净）
    this.requestSinks();
    this.push();
    return true;
  }

  onDestroy(): void {
    this.sinks = [];
    this.rows = [];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.systemvolume') {
      return false;
    }
    const b: SysVolumeBodyDto = body as SysVolumeBodyDto;
    if (b.sinkList !== undefined) {
      this.applyList(b.sinkList);          // 全量：以对端为准重建
    } else if (b.name !== undefined && b.name.length > 0) {
      this.applyIncrement(b);              // 增量：只改该 name 那条
    }
    this.push();
    return true;
  }

  // ---------- UI 行（唯一派生点：绝对刻度 → 百分比；并保持行对象实例稳定）----------
  // · 内容：一律从 sinks[]（协议真值）派生，这里不做任何协议判断；
  // · 身份：同名 sink 复用**同一个** SystemSinkUi 实例、字段原地更新 ⇒ @ObjectLink 能收到；
  // · 仅当"成员集合"变化（sink 增删/改名）时才换新数组引用，让 ForEach 重新求值一次。
  private syncRows(): SystemSinkUi[] {
    let membershipChanged: boolean = this.rows.length !== this.sinks.length;
    if (!membershipChanged) {
      for (let i = 0; i < this.sinks.length; i++) {
        if (this.rows[i].name !== this.sinks[i].name) {
          membershipChanged = true;
          break;
        }
      }
    }
    if (membershipChanged) {
      const next: SystemSinkUi[] = [];
      for (const s of this.sinks) {
        const reused: SystemSinkUi | undefined = this.findRow(s.name);
        if (reused !== undefined) {
          next.push(reused);
        } else {
          const fresh: SystemSinkUi = new SystemSinkUi();
          fresh.name = s.name;
          next.push(fresh);
        }
      }
      this.rows = next;
    }
    for (const s of this.sinks) {
      const row: SystemSinkUi | undefined = this.findRow(s.name);
      if (row !== undefined) {
        row.update(s.name, s.description, s.pct(), s.muted, s.enabled);
      }
    }
    return this.rows;
  }

  private findRow(name: string): SystemSinkUi | undefined {
    for (const r of this.rows) {
      if (r.name === name) {
        return r;
      }
    }
    return undefined;
  }

  // ---------- UI 动作（一律**按 name** 操作，不再有"主输出"隐式目标）----------
  // 返回 false = 发送失败 / 该 sink 不可用（由 UI 决定提示）
  requestSinks(): boolean {
    const body: SysVolumeBodyDto = { requestSinks: true };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    this.log(ok ? 'request sinks sent' : 'request sinks failed');
    return ok;
  }

  setVolume(name: string, pct: number): boolean {
    const s: SysSinkState | undefined = this.find(name);
    if (s === undefined) {
      this.log(`set volume skipped: unknown sink ${name}`);
      return false;
    }
    if (s.maxVolume <= 0) {
      this.log(`set volume skipped: scale unknown for ${name}`);
      return false;
    }
    const p: number = pct < 0 ? 0 : (pct > 100 ? 100 : Math.round(pct));
    const oldVolumeAbs: number = s.volumeAbs;
    const oldMuted: boolean = s.muted;
    s.volumeAbs = Math.round(p * s.maxVolume / 100);
    s.muted = false;
    this.push();
    const body: SysVolumeBodyDto = { name: s.name, volume: s.volumeAbs };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    if (!ok) {
      s.volumeAbs = oldVolumeAbs;
      s.muted = oldMuted;
      this.push();
    }
    this.log(ok ? `set volume sent: ${s.name} ${p}%` : `set volume failed: ${s.name} ${p}%`);
    return ok;
  }

  toggleMute(name: string): boolean {
    const s: SysSinkState | undefined = this.find(name);
    if (s === undefined) {
      this.log(`mute skipped: unknown sink ${name}`);
      return false;
    }
    const oldMuted: boolean = s.muted;
    s.muted = !s.muted;
    this.push();
    const body: SysVolumeBodyDto = { name: s.name, muted: s.muted };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    if (!ok) {
      s.muted = oldMuted;
      this.push();
    }
    this.log(ok ? `mute -> ${s.muted} (${s.name})` : `mute send failed (${s.name})`);
    return ok;
  }

  // 「选择输出设备」：把该 sink 设为对端**默认输出**（音频改从这里出）。
  // 协议依据：KDE pulse `if (np.has("enabled")) sink->setDefault(np.get<bool>("enabled"))`；
  // Android 对应 `sendEnable(name)`（只发 enabled=true + name，不给旧的默认 sink 发 false）。
  setDefault(name: string): boolean {
    const s: SysSinkState | undefined = this.find(name);
    if (s === undefined) {
      this.log(`set default skipped: unknown sink ${name}`);
      return false;
    }
    if (s.enabled) {
      return true;   // 已是默认，无须发包（对端也会推回，避免无谓切换）
    }
    // 乐观更新：默认只有一个 ⇒ 只改协议 enabled 标记（这是 UI 单选钮的唯一来源）
    for (const other of this.sinks) {
      other.enabled = other.name === s.name;
    }
    this.push();
    const body: SysVolumeBodyDto = { name: s.name, enabled: true };
    const ok: boolean = this.send('kdeconnect.systemvolume.request', body);
    this.log(ok ? `set default sink sent: ${s.name}` : `set default sink failed: ${s.name}`);
    return ok;
  }

  // ---------- 内部 ----------
  // 列表 = 全量重建（对端为准）
  private applyList(list: SysSinkDto[]): void {
    const next: SysSinkState[] = [];
    for (const d of list) {
      if (d.name === undefined || d.name.length === 0) {
        continue;   // 无名 sink 无法按 name 操作，直接丢弃
      }
      const s: SysSinkState = new SysSinkState();
      s.name = d.name;
      s.description = d.description !== undefined ? d.description : '';
      s.maxVolume = d.maxVolume !== undefined ? d.maxVolume : 0;
      s.volumeAbs = d.volume !== undefined ? d.volume : -1;
      s.muted = d.muted === true;
      s.enabled = d.enabled === true;
      next.push(s);
    }
    this.sinks = next;
    // 取证用（用户实测：对端有两路输出，UI 却只出现 1 行 —— 需要先确认"对端到底下发了几条"）：
    // 列表只在变化时到达，这条日志是低频的；名字截断以免刷屏。
    this.log(`sinkList n=${next.length} [${next.map((s: SysSinkState): string => s.name).join(', ').substring(0, 120)}]`);
  }

  // 增量：只改该 name 那条。**刻度（maxVolume）只从全量列表来**——schema 的增量包没有 maxVolume 字段，
  // 所以不在这里猜刻度；若该 name 尚未出现在列表里，先建一条刻度未知的占位（pct() = -1 ⇒ UI 显示「—」、
  // 滑杆禁用），列表到达时被 applyList 整体替换 ⇒ 自愈。面板打开时会请求一次列表，因此这只是极短的瞬态。
  private applyIncrement(b: SysVolumeBodyDto): void {
    const name: string = b.name !== undefined ? b.name : '';
    let s: SysSinkState | undefined = this.find(name);
    if (s === undefined) {
      if (name.length === 0) {
        return;
      }
      s = new SysSinkState();
      s.name = name;
      s.volumeAbs = b.volume !== undefined ? b.volume : -1;
      s.muted = b.muted === true;
      s.enabled = b.enabled === true;
      this.sinks.push(s);
      this.log(`increment for unknown sink -> placeholder (scale unknown): ${name}`);
    }
    if (b.volume !== undefined) {
      s.volumeAbs = b.volume;
    }
    if (b.muted !== undefined) {
      s.muted = b.muted;
    }
    if (b.enabled !== undefined) {
      // 对端权威的"谁是默认输出"：一个 sink 被置为默认时，其余同批/后续回推会带 false
      s.enabled = b.enabled;
    }
  }

  private find(name: string): SysSinkState | undefined {
    if (name.length === 0) {
      return undefined;
    }
    for (const s of this.sinks) {
      if (s.name === name) {
        return s;
      }
    }
    return undefined;
  }

  private push(): void {
    const ev: PluginEvent = { kind: 'systemvolume.sinks', svSinks: this.syncRows() };
    this.notifyEvent(ev);
  }
}
