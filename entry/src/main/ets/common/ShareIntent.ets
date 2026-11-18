// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// S1 —— 系统分享「记录 → 发送意图」的**纯逻辑**（DESIGN_SYSTEM_SHARE §3.2/§3.6；零 Kit / 零 native ⇒ 宿主 bun 与设备 hypium 双跑）。
//
// 分工：
//   · `EntryAbility.consumeShareWant` 只做 Kit 调用（`systemShare.getSharedData`）+ 把 `SharedRecord` **逐字段**拷成
//     `SharedRecordLike`（ArkTS 禁结构化类型 ⇒ 必须显式构造，不能直接把 Kit 对象传进来）+
//     写 `AppStorage('pendingShareData')`（落盘所有权在 Ability：URI 授权不跨 Ability/进程）；
//   · 本文件负责「哪些记录要发、叫什么名字、超限怎么办」的全部判断（可单测）。
import { sanitizeFileName } from '../model/PayloadLogic';

/** 分享面板单次最多文件数（与 `module.json5` 的 `maxFileSupported` 对齐：image/file 各 10） */
export const MAX_SHARE_FILES: number = 10;
/** 文本条数上限（`module.json5` 的 `general.text: maxFileSupported=1`） */
export const MAX_SHARE_TEXTS: number = 1;

/** `systemShare.SharedRecord` 的**纯镜像**（只取本功能用到的字段；显式构造，避免结构化类型） */
export interface SharedRecordLike {
  utd: string;
  uri?: string;
  content?: string;
  title?: string;
  label?: string;
}

export type ShareIntentKind = 'files' | 'text' | 'mixed' | 'empty';

/**
 * 发送意图（S3 消费）：`files` 与 `fileNames` **按下标对齐**（前者=沙箱路径，后者=发给对端的显示名）。
 * `dropped` 记录被丢弃的原因（超限/无内容/不支持的类型）——按项目口径**不静默**。
 */
export interface ShareIntent {
  kind: ShareIntentKind;
  texts: string[];
  files: string[];
  fileNames: string[];
  dropped: string[];
}

/** 记录是否携带「独立文本」（有 content 且没有可读 URI） */
function isTextRecord(r: SharedRecordLike): boolean {
  const hasContent: boolean = r.content !== undefined && r.content.length > 0;
  const hasUri: boolean = r.uri !== undefined && r.uri.length > 0;
  return hasContent && !hasUri;
}

/** URI 的扩展名（含点；无扩展名返回空串） */
function extOf(uri: string): string {
  const slash: number = uri.lastIndexOf('/');
  const tail: string = slash >= 0 ? uri.substring(slash + 1) : uri;
  const dot: number = tail.lastIndexOf('.');
  return dot > 0 ? tail.substring(dot) : '';
}

/** URI 的文件名（无扩展名兜底 `shared`） */
function baseNameOf(uri: string): string {
  const slash: number = uri.lastIndexOf('/');
  const tail: string = slash >= 0 ? uri.substring(slash + 1) : uri;
  return tail.length > 0 ? tail : 'shared';
}

/**
 * 显示名优先级：`title` → `label` → URI 文件名 → `share_<n><ext>`；统一过 `sanitizeFileName`
 * （去路径分隔符/控制字符/前导点、空名回落 `transfer_<tid>`、限长 128）。
 */
export function displayNameOf(r: SharedRecordLike, index: number): string {
  let name: string = '';
  if (r.title !== undefined && r.title.length > 0) {
    name = r.title;
  } else if (r.label !== undefined && r.label.length > 0) {
    name = r.label;
  } else if (r.uri !== undefined && r.uri.length > 0) {
    name = baseNameOf(r.uri);
  }
  if (name.length === 0) {
    name = `share_${index}`;
  }
  // 没有扩展名而 URI 有 ⇒ 补上（相册/文件管理器常只给 title，扩展名要靠 uri）
  if (r.uri !== undefined && r.uri.length > 0 && extOf(name).length === 0) {
    name = name + extOf(r.uri);
  }
  return sanitizeFileName(name, index + 1);
}

/**
 * 记录 → 意图。规则（与 `module.json5` 的 UTD 声明一致）：
 *   · 文本：`content` 非空且无 URI（`general.text` 的首选形态）；超过 `MAX_SHARE_TEXTS` ⇒ 丢弃并记原因；
 *   · 文件：有 URI ⇒ 进 `files`（沙箱路径由 S2 复制得到）；超过 `MAX_SHARE_FILES` ⇒ 丢弃并记原因；
 *   · 既无 content 又无 URI ⇒ 丢弃并记原因（不静默）。
 */
export function buildShareIntent(records: SharedRecordLike[]): ShareIntent {
  const texts: string[] = [];
  const files: string[] = [];
  const fileNames: string[] = [];
  const dropped: string[] = [];
  let index: number = 0;
  for (const r of records) {
    index++;
    const hasUri: boolean = r.uri !== undefined && r.uri.length > 0;
    if (isTextRecord(r)) {
      if (texts.length >= MAX_SHARE_TEXTS) {
        dropped.push(`#${index} text over limit (${MAX_SHARE_TEXTS})`);
        continue;
      }
      texts.push(r.content ?? '');
      continue;
    }
    if (hasUri) {
      if (files.length >= MAX_SHARE_FILES) {
        dropped.push(`#${index} file over limit (${MAX_SHARE_FILES}) utd=${r.utd}`);
        continue;
      }
      files.push(r.uri ?? '');
      fileNames.push(displayNameOf(r, index));
      continue;
    }
    dropped.push(`#${index} no content and no uri utd=${r.utd}`);
  }
  let kind: ShareIntentKind = 'empty';
  if (files.length > 0 && texts.length > 0) {
    kind = 'mixed';
  } else if (files.length > 0) {
    kind = 'files';
  } else if (texts.length > 0) {
    kind = 'text';
  }
  return { kind: kind, texts: texts, files: files, fileNames: fileNames, dropped: dropped };
}

/** `AppStorage('pendingShareData')` 的载荷形状（EntryAbility 写、页面读） */
export interface PendingSharePayload {
  texts?: string[];
  files?: string[];
  fileNames?: string[];
}

/** 解析页面侧读到的 JSON；坏数据/空串 ⇒ 空意图（不抛、不静默：调用方按空意图跳过即可） */
export function parseShareIntent(json: string): ShareIntent {
  if (json.length === 0) {
    return { kind: 'empty', texts: [], files: [], fileNames: [], dropped: [] };
  }
  let payload: PendingSharePayload;
  try {
    payload = JSON.parse(json) as PendingSharePayload;
  } catch (e) {
    return { kind: 'empty', texts: [], files: [], fileNames: [], dropped: ['bad json'] };
  }
  const texts: string[] = payload.texts ?? [];
  const files: string[] = payload.files ?? [];
  const names: string[] = payload.fileNames ?? [];
  // 名字缺失时用路径兜底（老载荷/异常情况），保证 files 与 fileNames 始终等长
  const fileNames: string[] = [];
  let i: number = 0;
  for (const f of files) {
    i++;
    fileNames.push(i <= names.length && names[i - 1].length > 0 ? names[i - 1] : displayNameOf({ utd: 'general.file', uri: f }, i));
  }
  let kind: ShareIntentKind = 'empty';
  if (files.length > 0 && texts.length > 0) {
    kind = 'mixed';
  } else if (files.length > 0) {
    kind = 'files';
  } else if (texts.length > 0) {
    kind = 'text';
  }
  return { kind: kind, texts: texts, files: files, fileNames: fileNames, dropped: [] };
}
