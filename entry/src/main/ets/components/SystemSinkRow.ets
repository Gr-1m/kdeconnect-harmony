import { SystemSinkUi } from '../model/SystemVolumeModels';

// 「设备」tab 的单个输出设备行（系统音量 / OutputDevice）。
//
// 范式与 MprisProgress 一致（本项目既有约定）：值由外部持有、动作经回调抛出，
// **组件内不持业务状态、不拿插件**；组件只做渲染。
//
// ★ 为什么用 @ObjectLink 而不是一堆 @Prop（2026-09-19 实测踩坑，勿回退）：
//   本组件在 `ForEach` 里渲染，键是 sink.name。ForEach 键不变时**不会重新执行子组件构建**，
//   标量 @Prop 的值会永远停在首帧 —— 实测症状就是「点静音对端有静音效果，但按钮文案不变」。
//   @Observed 行对象 + @ObjectLink 才能让字段变化直接驱动**这一行**重建。
//
// volumePct < 0 = 该 sink 的刻度未知 ⇒ 禁用滑杆并显示「—」（不做任何猜测）。
@Component
export struct SystemSinkRow {
  @ObjectLink sink: SystemSinkUi;
  onVolumeChange: (name: string, pct: number) => void = () => {
  };
  onToggleMute: (name: string) => void = () => {
  };
  // 选择输出设备（把该 sink 设为对端默认输出；协议上是单独发 {name, enabled:true}）
  onSelect: (name: string) => void = () => {
  };

  private ready(): boolean {
    return this.sink.volumePct >= 0;
  }

  private title(): string {
    return this.sink.description.length > 0 ? this.sink.description : this.sink.name;
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        // 「选择输出设备」按 Android 的做法用**单选钮**（互斥）：
        // kdeconnect-android 的 list_item_systemvolume.xml 里就是 RadioButton（设备名是它的标签）。
        // checked 直接读协议 enabled（对端权威），点选只发 {name, enabled:true}。
        Radio({ value: this.sink.name, group: 'sysSink' })
          .checked(this.sink.isDefault)
          .width(22)
          .height(22)
          .onChange((isChecked: boolean) => {
            if (isChecked) {
              this.onSelect(this.sink.name);
            }
          })
        Text(this.title())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 8 }) {
        Slider({ value: this.ready() ? this.sink.volumePct : 0, min: 0, max: 100, step: 1 })
          .layoutWeight(1)
          .enabled(this.ready())
          .onChange((value: number, mode: SliderChangeMode) => {
            // 与 Android 行为对齐（用户 2026-09-18 实测：安卓端不松手也实时同步）：
            // Begin/Moving/End 都发，节流交给页面侧门控，避免刷包。
            this.onVolumeChange(this.sink.name, value);
          })
        Text(this.ready() ? `${this.sink.volumePct}` : '—')
          .fontSize(10)
          .fontColor($r('app.color.text_muted'))
          .width(28)
        Button(this.sink.muted ? $r('app.string.sys_unmute') : $r('app.string.sys_mute'))
          .fontSize(11)
          .height(30)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor(this.sink.muted ? $r('app.color.danger_text') : $r('app.color.text_secondary'))
          .borderRadius(8)
          .enabled(this.ready())
          .onClick(() => {
            this.onToggleMute(this.sink.name);
          })
      }
      .width('100%')
    }
    .width('100%')
  }
}
