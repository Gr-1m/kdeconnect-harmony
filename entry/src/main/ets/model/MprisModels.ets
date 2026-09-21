// SPDX-License-Identifier: GPL-2.0-or-later
// MPRIS 媒体控制数据模型（方向 1：手机作为控制方，控制电脑端播放器）。
// 字段名/单位严格照 `kdeconnect-meta/schemas/`（经 MSG106 §3 转述）与
// `devdocs/FEATURE_PLAN_MPRIS.md` §2；插件与 UI 共用同一份形状。
// 本文件不 import 任何模块（模型层保持零依赖，避免环形引用）。

// 单个播放器的状态快照（= kdeconnect.mpris 的字段镜像；对端是**增量**包，合并后才是完整态）
export interface MprisSnapshot {
  player: string;
  title: string;
  artist: string;
  album: string;
  isPlaying: boolean;
  // pos 是「收包那一刻」的位置（ms），posAt 是它的本地接收时刻（Date.now()，0 表示未知）；
  // 播放中的位置由 mprisDisplayPos() 本地插值，避免进度条停在原地。
  pos: number;
  posAt: number;
  length: number;      // ms
  volume: number;      // 0-100；-1 = 未知
  loopStatus: string;  // None | Track | Playlist
  shuffle: boolean;
  canPlay: boolean;
  canPause: boolean;
  canGoNext: boolean;
  canGoPrevious: boolean;
  canSeek: boolean;
}

// 一台对端设备的面板态（Index 按设备镜像一份，对齐 batteryItems 的写法）
export interface MprisItem {
  deviceId: string;
  playerList: string[];
  currentPlayer: string;
  // 是否收到过对端**任何** mpris 包：区分「对端没有播放器」（空列表）与「对端没响应」
  gotAny: boolean;
  snapshot: MprisSnapshot;
}

export function emptyMprisSnapshot(player: string): MprisSnapshot {
  const s: MprisSnapshot = {
    player: player,
    title: '',
    artist: '',
    album: '',
    isPlaying: false,
    pos: 0,
    posAt: 0,
    length: 0,
    volume: -1,
    loopStatus: 'None',
    shuffle: false,
    canPlay: false,
    canPause: false,
    canGoNext: false,
    canGoPrevious: false,
    canSeek: false
  };
  return s;
}

export function emptyMprisItem(deviceId: string): MprisItem {
  const it: MprisItem = {
    deviceId: deviceId,
    playerList: [],
    currentPlayer: '',
    gotAny: false,
    snapshot: emptyMprisSnapshot('')
  };
  return it;
}

// 播放中的实时位置：pos + 已经过时间（未播放 / 未知 posAt 则原样返回），并按 length 夹紧
export function mprisDisplayPos(s: MprisSnapshot, now: number): number {
  let ms: number = s.pos;
  if (s.isPlaying && s.posAt > 0 && now > s.posAt) {
    ms = s.pos + (now - s.posAt);
  }
  if (ms < 0) {
    ms = 0;
  }
  if (s.length > 0 && ms > s.length) {
    ms = s.length;
  }
  return ms;
}

// ms → "m:ss"（负数/未知一律显示 0:00）
export function mprisTimeText(ms: number): string {
  let total: number = ms;
  if (total < 0 || total !== total) {
    total = 0;
  }
  const secTotal: number = Math.floor(total / 1000);
  const min: number = Math.floor(secTotal / 60);
  const sec: number = secTotal % 60;
  return sec < 10 ? `${min}:0${sec}` : `${min}:${sec}`;
}

// 播放器名美化：`org.mpris.MediaPlayer2.vlc` → `vlc`
export function mprisPlayerText(name: string): string {
  if (name.length === 0) {
    return '';
  }
  const parts: string[] = name.split('.');
  const last: string = parts[parts.length - 1];
  return last.length > 0 ? last : name;
}
