// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// MousepadInputPipeline 单测（阶段4 方向B / B1；设计见
// devdocs/DESIGN_STAGE4_REMOTE_INPUT_deveco.md §2/§4.1）。
//
// 用「假 sink」观测语义化调用序列 ⇒ **完全不涉及协议字段名**（B0 未决也不阻塞），
// 覆盖：累计偏移→增量、窗口节流、尾帧收尾、零位移不发包、基线重置、透传顺序。
// 约定：@ohos/hypium table-driven，命名 `Test<对象>_<场景>`（PROCESS §4.3）。
import { describe, it, expect } from '@ohos/hypium';
import { MousepadInputPipeline, MousepadSink, MousepadButton } from '../../../main/ets/plugins/MousepadInput';

class SpySink implements MousepadSink {
  moves: string[] = [];
  clicks: string[] = [];
  scrolls: string[] = [];
  keys: string[] = [];
  specials: number[] = [];

  move(dx: number, dy: number): void {
    this.moves.push(`${dx},${dy}`);
  }

  click(button: MousepadButton): void {
    this.clicks.push(button);
  }

  scroll(dx: number, dy: number): void {
    this.scrolls.push(`${dx},${dy}`);
  }

  key(text: string): void {
    this.keys.push(text);
  }

  specialKey(code: number): void {
    this.specials.push(code);
  }
}

function pipeline(spy: SpySink): MousepadInputPipeline {
  return new MousepadInputPipeline(spy, 16);
}

export default function mousepadInputTest(): void {
  describe('MousepadInputPipelineTest', () => {

    // ---- 累计偏移 → 增量（不变量①） ----

    it('TestMousepadInput_drag_firstUpdateSendsFullOffset', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(10, 20, 1000);
      expect(spy.moves.length).assertEqual(1);
      expect(spy.moves[0]).assertEqual('10,20');
    });

    it('TestMousepadInput_drag_cumulativeOffsetsConvertToIncrements', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(10, 10, 1000);      // 增量 10,10
      p.dragTo(15, 18, 1020);      // 累计 15,18 ⇒ 增量 5,8（窗口已过）
      expect(spy.moves.length).assertEqual(2);
      expect(spy.moves[0]).assertEqual('10,10');
      expect(spy.moves[1]).assertEqual('5,8');
    });

    it('TestMousepadInput_drag_negativeIncrementsPreserved', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(-6, 4, 1000);
      expect(spy.moves[0]).assertEqual('-6,4');
    });

    // ---- 节流（不变量④） ----

    it('TestMousepadInput_drag_throttlesWithinWindowAndMerges', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(1, 1, 1000);        // 立即放行
      p.dragTo(2, 2, 1005);        // 窗口内 ⇒ 合并（增量 1,1）
      p.dragTo(3, 3, 1010);        // 窗口内 ⇒ 合并（增量 1,1）
      expect(spy.moves.length).assertEqual(1);
      p.dragTo(4, 4, 1016);        // 窗口到 ⇒ 一次放出合并后的 3,3
      expect(spy.moves.length).assertEqual(2);
      expect(spy.moves[1]).assertEqual('3,3');
    });

    it('TestMousepadInput_drag_zeroDeltaDoesNotSend', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(0, 0, 1000);        // 无位移 ⇒ 不发包（不变量③）
      expect(spy.moves.length).assertEqual(0);
      p.dragTo(0, 0, 1016);
      expect(spy.moves.length).assertEqual(0);
    });

    it('TestMousepadInput_drag_repeatedSameOffsetSendsNothing', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(5, 5, 1000);        // 增量 5,5
      expect(spy.moves.length).assertEqual(1);
      p.dragTo(5, 5, 1020);        // 累计未变 ⇒ 增量 0,0
      expect(spy.moves.length).assertEqual(1);
    });

    // ---- 收尾与取消（不变量②） ----

    it('TestMousepadInput_endDrag_flushesResidualDelta', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(5, 5, 1000);        // 放行
      p.dragTo(8, 9, 1005);        // 窗口内 ⇒ 残留增量 3,4
      p.endDrag(1006);
      expect(spy.moves.length).assertEqual(2);
      expect(spy.moves[1]).assertEqual('3,4');
    });

    it('TestMousepadInput_endDrag_withoutResidualSendsNothing', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(5, 5, 1000);        // 已放行，无残留
      p.endDrag(1001);
      expect(spy.moves.length).assertEqual(1);
    });

    it('TestMousepadInput_cancelDrag_discardsResidual', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(5, 5, 1000);
      p.dragTo(9, 9, 1005);        // 残留
      p.cancelDrag();
      p.endDrag(1006);             // 已取消 ⇒ 不补发
      expect(spy.moves.length).assertEqual(1);
    });

    it('TestMousepadInput_beginDrag_resetsBaselineBetweenGestures', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.beginDrag();
      p.dragTo(10, 10, 1000);
      p.endDrag(1001);
      p.beginDrag();               // 新手势：基线归零
      p.dragTo(3, 3, 2000);        // 增量应为 3（而非 3-10）
      expect(spy.moves.length).assertEqual(2);
      expect(spy.moves[1]).assertEqual('3,3');
    });

    // ---- 透传：点击 / 滚动 / 键盘 ----

    it('TestMousepadInput_tap_passesEachButtonInOrder', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.tap('single');
      p.tap('double');
      p.tap('middle');
      p.tap('right');
      expect(spy.clicks.length).assertEqual(4);
      expect(spy.clicks[0]).assertEqual('single');
      expect(spy.clicks[1]).assertEqual('double');
      expect(spy.clicks[2]).assertEqual('middle');
      expect(spy.clicks[3]).assertEqual('right');
    });

    it('TestMousepadInput_scroll_passesDxDyInOrder', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.scrollBy(0, 2.5);          // 纵向滚动
      p.scrollBy(-1, 0);           // 横向滚动
      expect(spy.scrolls.length).assertEqual(2);
      expect(spy.scrolls[0]).assertEqual('0,2.5');
      expect(spy.scrolls[1]).assertEqual('-1,0');
    });

    it('TestMousepadInput_typeText_sendsEachCharInOrder', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.typeText('abc');
      expect(spy.keys.length).assertEqual(3);
      expect(spy.keys[0]).assertEqual('a');
      expect(spy.keys[1]).assertEqual('b');
      expect(spy.keys[2]).assertEqual('c');
    });

    it('TestMousepadInput_typeText_emptySendsNothing', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.typeText('');
      expect(spy.keys.length).assertEqual(0);
    });

    it('TestMousepadInput_typeSpecialKey_passesCode', 0, () => {
      const spy: SpySink = new SpySink();
      const p: MousepadInputPipeline = pipeline(spy);
      p.typeSpecialKey(66);
      expect(spy.specials.length).assertEqual(1);
      expect(spy.specials[0]).assertEqual(66);
    });
  });
}
