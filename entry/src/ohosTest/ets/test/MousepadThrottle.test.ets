// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// MousepadThrottle 单测（阶段4 方向B / B1 纯逻辑；设计见
// devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md §2/§5-4）。
//
// 纯逻辑类（时间由调用方注入）⇒ 无需 native/设备即可确定性验证。
// 约定：@ohos/hypium table-driven，命名 `Test<对象>_<场景>`（PROCESS §4.3）。
import { describe, it, expect } from '@ohos/hypium';
import { MousepadThrottle, MoveDelta } from '../../../main/ets/plugins/MousepadThrottle';

export default function mousepadThrottleTest(): void {
  describe('MousepadThrottleTest', () => {

    it('TestMousepadThrottle_firstAccumulateIsImmediatelyDue', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      expect(t.due(1000)).assertFalse();       // 无增量 ⇒ 不放行
      t.accumulate(3, 4);
      expect(t.due(1000)).assertTrue();        // 首次有增量 ⇒ 立即放行（低延迟）
    });

    it('TestMousepadThrottle_throttlesWithinWindow', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      t.accumulate(1, 1);
      const first: MoveDelta = t.take(1000);   // 窗口起点 = 1000
      expect(first.dx).assertEqual(1);
      expect(first.dy).assertEqual(1);
      t.accumulate(1, 1);
      expect(t.due(1005)).assertFalse();       // 窗口内 ⇒ 不放行（丢弃/延后）
      expect(t.due(1015)).assertFalse();       // 差 15ms < 16ms
      expect(t.due(1016)).assertTrue();        // 差 16ms ⇒ 放行
    });

    it('TestMousepadThrottle_accumulatesDeltasBetweenFlushes', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      t.accumulate(1, 2);
      t.take(1000);
      t.accumulate(3, 4);
      t.accumulate(5, 6);
      const merged: MoveDelta = t.take(1020);
      // 窗口内多次增量被合并（合并同向增量 ⇒ 减少帧数）
      expect(merged.dx).assertEqual(8);
      expect(merged.dy).assertEqual(10);
    });

    it('TestMousepadThrottle_takeResetsPendingState', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      t.accumulate(2, 2);
      t.take(1000);
      expect(t.hasPendingDelta()).assertFalse();
      expect(t.due(2000)).assertFalse();
    });

    it('TestMousepadThrottle_tailFlushReturnsResidualDelta', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      t.accumulate(1, 1);
      t.take(1000);
      t.accumulate(7, -3);                     // 手势结束时窗口未到
      const tail: MoveDelta = t.take(1005);    // 调用方强制收尾
      expect(tail.dx).assertEqual(7);
      expect(tail.dy).assertEqual(-3);
    });

    it('TestMousepadThrottle_negativeDeltasAccumulate', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      t.accumulate(-5, 5);
      t.accumulate(2, -8);
      const out: MoveDelta = t.take(1000);
      expect(out.dx).assertEqual(-3);
      expect(out.dy).assertEqual(-3);
    });

    it('TestMousepadThrottle_resetClearsPendingAndWindow', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(16);
      t.accumulate(9, 9);
      t.take(1000);
      t.accumulate(9, 9);
      t.reset();                               // 手势取消/断链
      expect(t.hasPendingDelta()).assertFalse();
      expect(t.due(1001)).assertFalse();
      t.accumulate(1, 1);                      // 复位后回到"立即放行"
      expect(t.due(1001)).assertTrue();
    });

    it('TestMousepadThrottle_invalidWindowFallsBackToDefault', 0, () => {
      const zero: MousepadThrottle = new MousepadThrottle(0);
      zero.accumulate(1, 1);
      zero.take(1000);
      zero.accumulate(1, 1);
      expect(zero.due(1015)).assertFalse();    // 默认 16ms
      expect(zero.due(1016)).assertTrue();

      const negative: MousepadThrottle = new MousepadThrottle(-5);
      negative.accumulate(1, 1);
      negative.take(0);
      negative.accumulate(1, 1);
      // lastFlushMs=0 被当作"未放行过" ⇒ 立即放行（防守：非法入参不产生静默卡死）
      expect(negative.due(1)).assertTrue();
    });

    it('TestMousepadThrottle_customWindowRespected', 0, () => {
      const t: MousepadThrottle = new MousepadThrottle(100);
      t.accumulate(1, 1);
      t.take(500);
      t.accumulate(1, 1);
      expect(t.due(599)).assertFalse();
      expect(t.due(600)).assertTrue();
    });
  });
}
