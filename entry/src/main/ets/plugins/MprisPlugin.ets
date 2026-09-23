// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import { PluginBase } from './PluginBase';
import { MprisItem, MprisSnapshot, emptyMprisItem, emptyMprisSnapshot } from '../model/MprisModels';

// 媒体控制插件（kdeconnect.mpris / kdeconnect.mpris.request）——方向 1：手机作为**控制方**。
// 规划：`devdocs/FEATURE_PLAN_MPRIS.md` §3；字段表：MSG106 §3（自 `kdeconnect-meta/schemas/`）。
//
// 关键语义（易错，勿回退）：
// 1. 对端的 `kdeconnect.mpris` 是**增量**包（只含变化字段）⇒ 内部按播放器名分桶存**完整态**，
//    收包只覆盖「包中出现的字段」，绝不能用默认值把没出现的字段冲掉。
// 2. 字段大小写/单位不统一：`action` 值首字母大写；`SetPosition` 大写 S 且单位**毫秒**；
//    `Seek` 大写 S 且单位**微秒**（本期不做相对跳转，故不发 Seek）。
// 3. 方向 2（被控方）不做：普通应用无 `MANAGE_MEDIA_RESOURCES`（system_basic），见规划 §4。
//
// notify 约定（FEATURE_PLAN_MPRIS §8）：
// - 'mpris.playerList'   → data: JSON.stringify(playerName[])
// - 'mpris.playerUpdate' → data: JSON.stringify(MprisSnapshot)（完整快照，字段齐全，UI 可直读）

interface MprisStateBody {
  playerList?: string[];
  player?: string;
  canPause?: boolean;
  canPlay?: boolean;
  canGoNext?: boolean;
  canGoPrevious?: boolean;
  canSeek?: boolean;
  isPlaying?: boolean;
  loopStatus?: string;
  shuffle?: boolean;
  pos?: number;
  length?: number;
  volume?: number;
  artist?: string;
  title?: string;
  album?: string;
  // 已废弃字段（老对端），仅日志用
  nowPlaying?: string;
}

interface MprisRequestListBody {
  requestPlayerList: boolean;
}

interface MprisRequestStatusBody {
  player: string;
  requestNowPlaying: boolean;
  requestVolume: boolean;
}

interface MprisRequestActionBody {
  player: string;
  action: string;
}

interface MprisRequestVolumeBody {
  player: string;
  setVolume: number;
}

interface MprisRequestPositionBody {
  player: string;
  SetPosition: number;
}

interface MprisRequestLoopBody {
  player: string;
  setLoopStatus: string;
}

interface MprisRequestShuffleBody {
  player: string;
  setShuffle: boolean;
}

// action 取值（首字母大写，KDE 直接透传给 DBus，写错会被静默忽略）
const ACTION_PLAY_PAUSE: string = 'PlayPause';
const ACTION_NEXT: string = 'Next';
const ACTION_PREVIOUS: string = 'Previous';
// 循环模式三态（None → Track → Playlist）
const LOOP_NONE: string = 'None';
const LOOP_TRACK: string = 'Track';
const LOOP_PLAYLIST: string = 'Playlist';
const LOG_PREVIEW_MAX: number = 60;

export class MprisPlugin extends PluginBase {
  // 按播放器名分桶存完整态：对端会为**不同播放器**发定向增量包，只存一份会串味
  private players: Map<string, MprisSnapshot> = new Map();
  private playerList: string[] = [];
  private currentPlayer: string = '';
  private gotAny: boolean = false;
  private loggedKeys: boolean = false;
  private lastLogSig: string = '';

  constructor() {
    super();
    this.displayName = 'MPRIS';
    this.description = 'Control media players on the peer';
    this.supportedPacketTypes = ['kdeconnect.mpris'];
    this.outgoingPacketTypes = ['kdeconnect.mpris.request'];
  }

  onCreate(): boolean {
    // 规划 §3.2：建链即拉一次播放器列表（面板打开时会再拉一次状态）
    this.requestPlayerList();
    return true;
  }

  onDestroy(): void {
    this.players.clear();
    this.playerList = [];
    this.currentPlayer = '';
    this.gotAny = false;
    this.loggedKeys = false;
    this.lastLogSig = '';
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType !== 'kdeconnect.mpris') {
      return false;
    }
    this.handleState(body as MprisStateBody, body);
    return true;
  }

  // UI 打开面板时拉取初始镜像
  item(): MprisItem {
    const it: MprisItem = emptyMprisItem(this.deviceId);
    it.playerList = this.playerList;
    it.currentPlayer = this.currentPlayer;
    it.gotAny = this.gotAny;
    const snap: MprisSnapshot | undefined = this.players.get(this.currentPlayer);
    if (snap !== undefined) {
      it.snapshot = snap;
    }
    return it;
  }

  // ---------- 发送侧（UI 调用；返回 false 表示发送失败，由 UI 决定提示）----------

  requestPlayerList(): boolean {
    const body: MprisRequestListBody = { requestPlayerList: true };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? 'request player list sent' : 'request player list failed');
    return ok;
  }

  // 不带参数时请求当前播放器；当前播放器未知则只发列表请求（等列表到了由 handleState 自动补一次）
  requestStatus(player?: string): boolean {
    const target: string = player ?? this.currentPlayer;
    if (target.length === 0) {
      return this.requestPlayerList();
    }
    const body: MprisRequestStatusBody = { player: target, requestNowPlaying: true, requestVolume: true };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? `request status sent: ${target}` : `request status failed: ${target}`);
    return ok;
  }

  // 用户切换播放器：切当前 + 推 UI + 定向拉该播放器状态
  selectPlayer(name: string): void {
    if (name.length === 0 || name === this.currentPlayer) {
      return;
    }
    this.currentPlayer = name;
    if (!this.players.has(name)) {
      this.players.set(name, emptyMprisSnapshot(name));
    }
    this.emitUpdate();
    this.requestStatus(name);
  }

  // 播放/暂停统一用 `PlayPause`：由对端按自身状态决定，避免本地 isPlaying 过期时反向操作
  togglePlay(): boolean {
    return this.control(ACTION_PLAY_PAUSE);
  }

  next(): boolean {
    return this.control(ACTION_NEXT);
  }

  previous(): boolean {
    return this.control(ACTION_PREVIOUS);
  }

  control(action: string): boolean {
    if (this.currentPlayer.length === 0) {
      this.log('control skipped: no current player');
      return false;
    }
    const body: MprisRequestActionBody = { player: this.currentPlayer, action: action };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? `action sent: ${action}` : `action failed: ${action}`);
    return ok;
  }

  setVolume(volume: number): boolean {
    if (this.currentPlayer.length === 0) {
      return false;
    }
    let v: number = Math.round(volume);
    if (v < 0) {
      v = 0;
    }
    if (v > 100) {
      v = 100;
    }
    const body: MprisRequestVolumeBody = { player: this.currentPlayer, setVolume: v };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? `set volume sent: ${v}` : `set volume failed: ${v}`);
    return ok;
  }

  // SetPosition：大写 S，单位**毫秒**（与 Seek 的微秒不同）
  setPosition(positionMs: number): boolean {
    if (this.currentPlayer.length === 0) {
      return false;
    }
    let ms: number = Math.round(positionMs);
    if (ms < 0) {
      ms = 0;
    }
    const body: MprisRequestPositionBody = { player: this.currentPlayer, SetPosition: ms };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? `set position sent: ${ms}ms` : `set position failed: ${ms}ms`);
    return ok;
  }

  // 循环三态轮转：None → Track → Playlist → None
  cycleLoopStatus(): boolean {
    const snap: MprisSnapshot | undefined = this.players.get(this.currentPlayer);
    const cur: string = snap === undefined ? LOOP_NONE : snap.loopStatus;
    let next: string = LOOP_NONE;
    if (cur === LOOP_NONE) {
      next = LOOP_TRACK;
    } else if (cur === LOOP_TRACK) {
      next = LOOP_PLAYLIST;
    }
    return this.setLoopStatus(next);
  }

  setLoopStatus(status: string): boolean {
    if (this.currentPlayer.length === 0) {
      return false;
    }
    const body: MprisRequestLoopBody = { player: this.currentPlayer, setLoopStatus: status };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? `set loop sent: ${status}` : `set loop failed: ${status}`);
    return ok;
  }

  toggleShuffle(): boolean {
    const snap: MprisSnapshot | undefined = this.players.get(this.currentPlayer);
    const next: boolean = snap === undefined ? true : !snap.shuffle;
    return this.setShuffle(next);
  }

  setShuffle(shuffle: boolean): boolean {
    if (this.currentPlayer.length === 0) {
      return false;
    }
    const body: MprisRequestShuffleBody = { player: this.currentPlayer, setShuffle: shuffle };
    const ok: boolean = this.send('kdeconnect.mpris.request', body);
    this.log(ok ? `set shuffle sent: ${shuffle}` : `set shuffle failed: ${shuffle}`);
    return ok;
  }

  // ---------- 接收侧 ----------

  private handleState(b: MprisStateBody, raw: Object): void {
    this.gotAny = true;
    if (!this.loggedKeys) {
      // 首包打一行真实字段名：核对 schema 与实现对得上（尤其 playerList 的类型）
      this.loggedKeys = true;
      this.log(`mpris state keys: [${Object.keys(raw).join(',')}]`);
    }

    // 1) 播放器列表（整体替换；空数组 = 对端没有播放器）
    if (b.playerList !== undefined) {
      const incoming: string[] = b.playerList;
      this.playerList = incoming;
      if (incoming.length === 0) {
        this.players.clear();
        this.currentPlayer = '';
        this.emitList();
        this.log('peer has no media player');
        return;
      }
      // 清掉已消失的播放器分桶
      const alive: string[] = [];
      this.players.forEach((v: MprisSnapshot, k: string) => {
        if (incoming.includes(k)) {
          alive.push(k);
        }
      });
      const gone: string[] = [];
      this.players.forEach((v: MprisSnapshot, k: string) => {
        if (!alive.includes(k)) {
          gone.push(k);
        }
      });
      for (const k of gone) {
        this.players.delete(k);
      }
      this.emitList();
    }

    // 2) 目标播放器：包里有 player 就是它，否则沿用当前。
    // 实测坑：KDE 会同时用两个身份名发同一个播放器（如 playerList=["Firefox"]，却仍有
    // `player:"Mozilla firefox"` 的包）⇒ 若见谁都切，面板会来回跳、曲目信息忽有忽无。
    // 规则：只有出现在 playerList 里的名字才允许成为「当前播放器」；列表为空（对端不发列表）时放行。
    const target: string = b.player ?? this.currentPlayer;
    const listed: boolean = this.playerList.length === 0 || this.playerList.includes(target);
    const canClaim: boolean = listed && (this.currentPlayer.length === 0 || target === this.currentPlayer);
    if (target.length > 0 && canClaim) {
      this.currentPlayer = target;
    }
    if (this.currentPlayer.length === 0 && this.playerList.length > 0) {
      this.currentPlayer = this.playerList[0];
    }
    if (this.currentPlayer.length === 0) {
      return;
    }
    // 别名身份的包：合并进它自己的桶，但不改变当前播放器、不推 UI
    if (target.length > 0 && target !== this.currentPlayer) {
      this.mergeInto(target, b);
      return;
    }

    // 3) 增量合并：只覆盖「包中出现的字段」
    const snap: MprisSnapshot = this.mergeInto(this.currentPlayer, b);

    // 4) 推 UI
    this.emitUpdate();
    this.logVisibleChange(snap);

    // 5) 列表先到、当前播放器后到：补拉一次状态
    if (b.playerList !== undefined && target.length === 0) {
      this.requestStatus(this.currentPlayer);
    }
  }

  // 增量合并：只覆盖包中**出现**的字段（对端只发变化字段，绝不能被默认值冲掉）
  private mergeInto(player: string, b: MprisStateBody): MprisSnapshot {
    let snap: MprisSnapshot | undefined = this.players.get(player);
    if (snap === undefined) {
      snap = emptyMprisSnapshot(player);
      this.players.set(player, snap);
    }
    snap.player = player;
    if (b.title !== undefined) {
      snap.title = b.title;
    }
    if (b.artist !== undefined) {
      snap.artist = b.artist;
    }
    if (b.album !== undefined) {
      snap.album = b.album;
    }
    if (b.isPlaying !== undefined) {
      snap.isPlaying = b.isPlaying;
    }
    if (b.loopStatus !== undefined) {
      snap.loopStatus = b.loopStatus;
    }
    if (b.shuffle !== undefined) {
      snap.shuffle = b.shuffle;
    }
    if (b.length !== undefined) {
      snap.length = b.length;
    }
    if (b.pos !== undefined) {
      snap.pos = b.pos;
      snap.posAt = Date.now();
    }
    if (b.volume !== undefined) {
      snap.volume = b.volume;
    }
    if (b.canPlay !== undefined) {
      snap.canPlay = b.canPlay;
    }
    if (b.canPause !== undefined) {
      snap.canPause = b.canPause;
    }
    if (b.canGoNext !== undefined) {
      snap.canGoNext = b.canGoNext;
    }
    if (b.canGoPrevious !== undefined) {
      snap.canGoPrevious = b.canGoPrevious;
    }
    if (b.canSeek !== undefined) {
      snap.canSeek = b.canSeek;
    }
    return snap;
  }

  private emitList(): void {
    // 批1 根治：传对象（不再 JSON.stringify），UI 侧不再 JSON.parse
    this.notifyEvent({ kind: 'mpris.playerList', mprisList: this.playerList });
  }

  private emitUpdate(): void {
    const snap: MprisSnapshot | undefined = this.players.get(this.currentPlayer);
    if (snap === undefined) {
      return;
    }
    this.notifyEvent({ kind: 'mpris.playerUpdate', mprisSnap: snap });
  }

  // 只在「看得见」的字段变化时打日志：对端会周期推 pos，逐包打会把日志刷屏
  private logVisibleChange(s: MprisSnapshot): void {
    const sig: string = `${s.player}|${s.title}|${s.artist}|${s.isPlaying}|${s.length}`;
    if (sig === this.lastLogSig) {
      return;
    }
    this.lastLogSig = sig;
    const title: string = s.title.length > LOG_PREVIEW_MAX ? s.title.substring(0, LOG_PREVIEW_MAX) : s.title;
    this.log(`mpris state <- ${s.player}: playing=${s.isPlaying} title=${title}`);
  }
}
