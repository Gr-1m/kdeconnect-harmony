// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// S1 —— 系统分享意图纯逻辑回归（零 Kit ⇒ 宿主 bun 与设备 hypium 双跑）。
import { describe, it, expect } from '@ohos/hypium';
import {
  MAX_SHARE_FILES, MAX_SHARE_TEXTS, SharedRecordLike, buildShareIntent, displayNameOf, parseShareIntent, ShareIntent
} from '../../../main/ets/common/ShareIntent';

function rec(utd: string, uri: string, content: string, title: string): SharedRecordLike {
  const r: SharedRecordLike = {
    utd: utd,
    uri: uri.length > 0 ? uri : undefined,
    content: content.length > 0 ? content : undefined,
    title: title.length > 0 ? title : undefined
  };
  return r;
}

export default function shareIntentTest(): void {
  describe('ShareIntentTest', () => {
    it('TestShareIntent_textOnly', 0, () => {
      const out: ShareIntent = buildShareIntent([rec('general.text', '', 'https://kde.org', '')]);
      expect(out.kind).assertEqual('text');
      expect(out.texts.length).assertEqual(1);
      expect(out.texts[0]).assertEqual('https://kde.org');
      expect(out.files.length).assertEqual(0);
    });

    it('TestShareIntent_singleFileUsesTitleAsName', 0, () => {
      const out: ShareIntent = buildShareIntent([rec('general.image', 'file:///mnt/x/IMG_1.heic', '', '我的照片.png')]);
      expect(out.kind).assertEqual('files');
      expect(out.files.length).assertEqual(1);
      expect(out.fileNames.length).assertEqual(1);
      expect(out.fileNames[0]).assertEqual('我的照片.png');   // title 优先（已是扩展名 ⇒ 不补）
    });

    it('TestShareIntent_mixedKindsAndExtensionBackfill', 0, () => {
      const out: ShareIntent = buildShareIntent([
        rec('general.text', '', 'hello', ''),
        rec('general.file', 'file:///docs/report.pdf', '', 'report')
      ]);
      expect(out.kind).assertEqual('mixed');
      expect(out.fileNames[0]).assertEqual('report.pdf');     // title 无扩展名 ⇒ 由 uri 补
    });

    it('TestShareIntent_textOverLimitDropped', 0, () => {
      const out: ShareIntent = buildShareIntent([
        rec('general.text', '', 'a', ''),
        rec('general.text', '', 'b', '')
      ]);
      expect(out.texts.length).assertEqual(MAX_SHARE_TEXTS);
      expect(out.dropped.length).assertEqual(1);
      expect(out.dropped[0].includes('text over limit')).assertTrue();
    });

    it('TestShareIntent_fileOverLimitDropped', 0, () => {
      const recs: SharedRecordLike[] = [];
      for (let i = 0; i < MAX_SHARE_FILES + 2; i++) {
        recs.push(rec('general.image', `file:///mnt/i${i}.png`, '', `i${i}.png`));
      }
      const out: ShareIntent = buildShareIntent(recs);
      expect(out.files.length).assertEqual(MAX_SHARE_FILES);
      expect(out.fileNames.length).assertEqual(MAX_SHARE_FILES);
      expect(out.dropped.length).assertEqual(2);
      expect(out.dropped[0].includes('file over limit')).assertTrue();
    });

    it('TestShareIntent_emptyRecordDroppedNotSilently', 0, () => {
      const out: ShareIntent = buildShareIntent([rec('general.file', '', '', '')]);
      expect(out.kind).assertEqual('empty');
      expect(out.dropped.length).assertEqual(1);
      expect(out.dropped[0].includes('no content and no uri')).assertTrue();
    });

    it('TestShareIntent_displayNamePriorityAndSanitize', 0, () => {
      expect(displayNameOf(rec('general.image', 'file:///a/photo.jpg', '', ''), 1)).assertEqual('photo.jpg');
      const evil: string = displayNameOf(rec('general.file', 'file:///a/x.bin', '', '../../etc/passwd'), 2);
      expect(evil.includes('/')).assertFalse();
      expect(evil.includes('..')).assertFalse();
      expect(displayNameOf(rec('general.file', '', '', ''), 3).length > 0).assertTrue();   // 兜底名
    });

    it('TestShareIntent_parseRoundTripAndBadJson', 0, () => {
      const ok: ShareIntent = parseShareIntent(JSON.stringify({ texts: ['t'], files: ['/cache/s1.png'], fileNames: ['s1.png'] }));
      expect(ok.kind).assertEqual('mixed');
      expect(ok.fileNames[0]).assertEqual('s1.png');
      // 名字缺失 ⇒ 由路径兜底（files 与 fileNames 始终等长）
      const noNames: ShareIntent = parseShareIntent(JSON.stringify({ files: ['/cache/only.bin'] }));
      expect(noNames.fileNames.length).assertEqual(1);
      expect(noNames.fileNames[0]).assertEqual('only.bin');
      // 坏数据：不抛，空意图 + 记原因
      const bad: ShareIntent = parseShareIntent('not json');
      expect(bad.kind).assertEqual('empty');
      expect(bad.dropped.includes('bad json')).assertTrue();
      expect(parseShareIntent('').kind).assertEqual('empty');
    });
  });
}
