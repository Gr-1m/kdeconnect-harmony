// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// 媒体控制领域控制器（阶段 3 / 批次 2 步骤 6a-1；CodeArts MSG62、Omp MSG68 §6、设计见 devdocs/DESIGN_BATCH2_deveco.md）
//
// 抽离自 Index.ets 的 MPRIS + 系统音量共 **24 个方法**（L846–L1125，逐字保真，零语义变更）。
//
// 分层（与 PairSession / PayloadController 同一套范式）：
//   · 本类持有**领域状态**：items（按设备镜像对端播放器）/ deviceId / dialogOpen / tab / svSinks / svDeviceId；
//   · 不碰 I/O 与平台能力：日志、提示、限频、插件取用全部**注入**（log / toast / actionGate / pluginsFor）；
//   · `@Observed` ⇒ 页面 @State 持实例、Dialog 以 @ObjectLink 读，字段变化只重建订阅者（避开"状态变了 UI 不刷新"）。
//
// 不变量（勿改）：
//   ① 面板**关着**时对端周期推送不写状态（`isPanelFor` 门控）—— 否则白白整页重渲染；
//   ② 面板读数的插值时钟在 `components/MprisProgress.ets`（子组件局部 @State + 1s ticker），**别退回页面级 ticker**；
//   ③ `systemvolume.sinks` 单槽过滤（`svDeviceId === deviceId`）不得丢；
//   ④ 调音量/静音/选输出的发包口径见 SystemVolumePlugin 头注释（不带 enabled / 静音要带 volume 等）。

import {
  MprisItem,
  MprisSnapshot,
  emptyMprisItem
} from '../model/MprisModels';
import { SystemSinkUi } from '../model/SystemVolumeModels';
import { PluginBase } from '../plugins/PluginBase';
import { MprisPlugin } from '../plugins/MprisPlugin';
import { SystemVolumePlugin } from '../plugins/SystemVolumePlugin';

@Observed
export class MprisController {
  // ---------- 领域状态（原 Index 的 @State）----------
  items: MprisItem[] = [];          // 原 @State mprisItems
  deviceId: string = '';            // 原 @State mprisDeviceId（当前面板设备）
  dialogOpen: boolean = false;      // 原 @State mprisDialogOpen
  tab: number = 0;                  // 原 @State mprisTab（0=媒体 1=设备）
  svSinks: SystemSinkUi[] = [];     // 原 @State svSinks
  svDeviceId: string = '';          // 原 @State svDeviceId（防切换面板串数据）

  // ---------- 注入：平台能力（本类不碰 I/O）----------
  log: (msg: string) => void = () => {
  };
  /** 已本地化文案的 toast（页面注入 notify.toast / notify.resText 组合） */
  toast: (message: string) => void = () => {
  };
  resText: (resId: number) => string = () => '';
  /** 点击/发包限频（同一 key 在窗口内重复触发直接忽略） */
  actionGate: (key: string, ms: number) => boolean = () => true;
  /** 取某设备的插件实例列表（页面注入 pluginHost.pluginsFor） */
  pluginsFor: (deviceId: string) => PluginBase[] = () => [];

  // ========== 状态镜像（原 L846–L902）=========

  /** 当前是否正为该设备打开媒体面板（决定要不要把插件事件写进状态） */
  isPanelFor(deviceId: string): boolean {
    return this.dialogOpen && this.deviceId === deviceId;
  }

  itemOf(deviceId: string): MprisItem {
    for (const m of this.items) {
      if (m.deviceId === deviceId) {
        return m;
      }
    }
    return emptyMprisItem(deviceId);
  }

  put(next: MprisItem): void {
    const exists: boolean = this.items.some((m: MprisItem) => m.deviceId === next.deviceId);
    if (exists) {
      this.items = this.items.map((m: MprisItem) => m.deviceId === next.deviceId ? next : m);
    } else {
      this.items = this.items.concat([next]);
    }
  }

  setList(deviceId: string, list: string[]): void {
    // 前后台分离（用户建议）：面板没开就不写状态 —— 对端会周期推播放器状态，
    // 关着面板还写会白白触发整页重渲染。面板打开时用 MprisPlugin.item() 重新播种，不会丢数据。
    if (!this.isPanelFor(deviceId)) {
      return;
    }
    const cur: MprisItem = this.itemOf(deviceId);
    const next: MprisItem = {
      deviceId: cur.deviceId,
      playerList: list,
      currentPlayer: cur.currentPlayer,
      gotAny: true,
      snapshot: cur.snapshot
    };
    this.put(next);
  }

  setSnapshot(deviceId: string, snap: MprisSnapshot): void {
    // 同上：关着面板时不写状态（对端 ~1s 推一次 pos，逐次写会持续触发整页重渲染）
    if (!this.isPanelFor(deviceId)) {
      return;
    }
    const cur: MprisItem = this.itemOf(deviceId);
    const next: MprisItem = {
      deviceId: cur.deviceId,
      playerList: cur.playerList,
      currentPlayer: snap.player.length > 0 ? snap.player : cur.currentPlayer,
      gotAny: true,
      snapshot: snap
    };
    this.put(next);
  }

  mprisPluginOf(deviceId: string): MprisPlugin | undefined {
    for (const p of this.pluginsFor(deviceId)) {
      if (p instanceof MprisPlugin) {
        return p;
      }
    }
    return undefined;
  }

  /** 系统音量插件取用（与 MPRIS 分开：播放器不提供音量/无播放器时仍可调对端系统音量） */
  sysVolumePluginOf(deviceId: string): SystemVolumePlugin | undefined {
    for (const p of this.pluginsFor(deviceId)) {
      if (p instanceof SystemVolumePlugin) {
        return p;
      }
    }
    return undefined;
  }

  // ========== 系统音量（原 L925–L980）=========

  /** 当前面板设备的输出设备快照（设备不符 ⇒ 空数组，避免显示上一台设备的行） */
  svSinksForCurrent(): SystemSinkUi[] {
    return this.svDeviceId === this.deviceId ? this.svSinks : [];
  }

  /** 打开面板时：换设备先清空快照，再向对端**请求一次列表**（协议级刷新） */
  svPrepare(): void {
    if (this.svDeviceId !== this.deviceId) {
      this.svSinks = [];
      this.svDeviceId = this.deviceId;
    }
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.deviceId);
    if (p !== undefined) {
      p.requestSinks();
    }
  }

  svSinkSet(name: string, pct: number): void {
    // 60ms 轻门控（用户要求拖动实时同步；Android 端不松手即同步，这里只防刷包）
    if (!this.actionGate(`sysvol:${name}:vol`, 60)) {
      return;
    }
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.deviceId);
    if (p === undefined || !p.setVolume(name, pct)) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  svSinkToggleMute(name: string): void {
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.deviceId);
    if (p === undefined || !p.toggleMute(name)) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  /** 「选择输出设备」：把该 sink 设为对端默认输出（协议上单独发 {name, enabled:true}） */
  svSinkSetDefault(name: string): void {
    const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.deviceId);
    if (p === undefined || !p.setDefault(name)) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  // ========== 面板读数（原 L982–L1027）=========

  snapshot(): MprisSnapshot {
    return this.itemOf(this.deviceId).snapshot;
  }

  playerList(): string[] {
    return this.itemOf(this.deviceId).playerList;
  }

  /** 对端没响应 / 对端没有播放器 → 都走空态 */
  isEmpty(): boolean {
    const it: MprisItem = this.itemOf(this.deviceId);
    return !it.gotAny || it.playerList.length === 0;
  }

  vol(): number {
    const v: number = this.snapshot().volume;
    return v > 0 ? v : 0;
  }

  artistLine(): ResourceStr {
    const s: MprisSnapshot = this.snapshot();
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

  loopText(): ResourceStr {
    const cur: string = this.snapshot().loopStatus;
    if (cur === 'Track') {
      return $r('app.string.media_loop_track');
    }
    if (cur === 'Playlist') {
      return $r('app.string.media_loop_playlist');
    }
    return $r('app.string.media_loop_none');
  }

  // ========== 面板生命周期（原 L1029–L1043）=========

  close(): void {
    this.dialogOpen = false;
  }

  /** P2（MSG132 §2）：设备断链/离线 → 丢掉该设备的面板镜像 + 关面板。
   *  过期快照若留着，重连前打开面板会显示旧曲目，并继续用本地插值往前跑（假进度）。 */
  forget(deviceId: string): void {
    if (deviceId.length === 0) {
      return;
    }
    this.items = this.items.filter((m: MprisItem) => m.deviceId !== deviceId);
    if (this.deviceId === deviceId) {
      this.close();
    }
  }

  // ========== 控制动作（原 L1045–L1125）=========

  /** 控制类动作：插件没装载（对端不支持）或发送失败都给明确提示 */
  action(action: string): void {
    // 连点保护：⏮⏯⏭ 每次都会真发包，连点会把主线程和对端一起刷爆
    if (!this.actionGate(`mpris:${this.deviceId}:${action}`, 400)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined) {
      this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
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
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  setVolume(v: number): void {
    if (!this.actionGate(`mpris:${this.deviceId}:vol`, 200)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined || !p.setVolume(v)) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  setPosition(ms: number): void {
    if (!this.actionGate(`mpris:${this.deviceId}:pos`, 200)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined || !p.setPosition(ms)) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  toggleLoop(): void {
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined || !p.cycleLoopStatus()) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  toggleShuffle(): void {
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined || !p.toggleShuffle()) {
      this.toast(this.resText($r('app.string.toast_media_action_failed').id));
    }
  }

  selectPlayer(name: string): void {
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined) {
      this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    p.selectPlayer(name);
    p.requestStatus(name);
  }

  refresh(): void {
    if (!this.actionGate(`mpris:${this.deviceId}:refresh`, 1500)) {
      return;
    }
    const p: MprisPlugin | undefined = this.mprisPluginOf(this.deviceId);
    if (p === undefined) {
      this.toast(this.resText($r('app.string.toast_plugin_unavailable').id));
      return;
    }
    p.requestPlayerList();
    p.requestStatus();
    this.log(`media refresh requested for ${this.deviceId}`);
  }

  /** 面板页脚「刷新」：按当前 tab 决定刷新对象（媒体=播放器列表/状态，设备=输出设备列表） */
  panelRefresh(): void {
    if (this.tab === 1) {
      const p: SystemVolumePlugin | undefined = this.sysVolumePluginOf(this.deviceId);
      if (p === undefined || !p.requestSinks()) {
        this.toast(this.resText($r('app.string.toast_media_action_failed').id));
      }
      return;
    }
    this.refresh();
  }
}
