import uiMaterial from '@ohos.arkui.uiMaterial';
import { GlassCard } from './GlassCard';
import { THEME_FOLLOW_SYSTEM, THEME_LIGHT, THEME_DARK, LANG_SYSTEM, LANG_ZH, LANG_EN } from '../common/AppSettings';

// 设置 Tab：本机身份与协议信息 + 可自定义设备名称 / 主题（跟随系统·亮·暗）/ 语言（默认跟随系统）。
@Component
export struct SettingsTab {
  @Prop deviceId: string = '';
  // 父页面 Preferences 读取完成晚于本组件首次构建，用 @Watch 同步草稿，避免显示默认值
  @Prop @Watch('onDeviceNameChanged') deviceName: string = '';
  @Prop statusText: string = '';
  @Prop themeMode: number = THEME_FOLLOW_SYSTEM;
  @Prop language: string = LANG_SYSTEM;
  @Prop immersive: boolean = false;
  cardMaterial: uiMaterial.Material | undefined = undefined;
  onRenameDevice: (name: string) => void = () => {
  };
  onThemeChange: (mode: number) => void = () => {
  };
  onLanguageChange: (lang: string) => void = () => {
  };
  @State nameDraft: string = '';
  // 用户是否已手动编辑草稿（否则外部 deviceName 更新时应同步草稿）
  @State nameEdited: boolean = false;

  aboutToAppear(): void {
    this.nameDraft = this.deviceName;
  }

  onDeviceNameChanged(): void {
    if (!this.nameEdited) {
      this.nameDraft = this.deviceName;
    }
  }

  @Builder
  infoRow(label: ResourceStr, value: string, mono: boolean) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width(96)
      Text(value)
        .fontSize(12)
        .fontColor(mono ? $r('app.color.accent_text') : $r('app.color.text_primary'))
        .fontFamily(mono ? 'monospace' : 'default')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  sectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
  }

  @Builder
  optionPill(label: ResourceStr, active: boolean, onPick: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(active ? $r('app.color.accent_text') : $r('app.color.text_secondary'))
      .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .layoutWeight(1)
      .borderRadius(10)
      .backgroundColor(active ? $r('app.color.accent_soft') : $r('app.color.input_bg'))
      .onClick(() => {
        onPick();
      })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // 设备名称（可自定义）
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 10 }) {
            this.sectionTitle($r('app.string.settings_device_name'))
            Row({ space: 8 }) {
              TextInput({ text: this.nameDraft, placeholder: 'kdeconnect-harmony' })
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.input_bg'))
                .borderRadius(10)
                .onChange((v: string) => {
                  this.nameDraft = v;
                  this.nameEdited = true;
                })
              Button($r('app.string.settings_save'))
                .height(40)
                .fontSize(13)
                .backgroundColor($r('app.color.accent'))
                .borderRadius(10)
                .enabled(this.nameDraft.length > 0 && this.nameDraft !== this.deviceName)
                .onClick(() => {
                  this.nameEdited = false;
                  this.onRenameDevice(this.nameDraft);
                })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // 主题
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 10 }) {
            this.sectionTitle($r('app.string.settings_theme'))
            Row({ space: 8 }) {
              this.optionPill($r('app.string.follow_system'), this.themeMode === THEME_FOLLOW_SYSTEM, () => {
                this.onThemeChange(THEME_FOLLOW_SYSTEM);
              })
              this.optionPill($r('app.string.theme_light'), this.themeMode === THEME_LIGHT, () => {
                this.onThemeChange(THEME_LIGHT);
              })
              this.optionPill($r('app.string.theme_dark'), this.themeMode === THEME_DARK, () => {
                this.onThemeChange(THEME_DARK);
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // 语言（默认跟随系统）
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 10 }) {
            this.sectionTitle($r('app.string.settings_language'))
            Row({ space: 8 }) {
              this.optionPill($r('app.string.follow_system'), this.language === LANG_SYSTEM, () => {
                this.onLanguageChange(LANG_SYSTEM);
              })
              this.optionPill($r('app.string.lang_zh'), this.language === LANG_ZH, () => {
                this.onLanguageChange(LANG_ZH);
              })
              this.optionPill($r('app.string.lang_en'), this.language === LANG_EN, () => {
                this.onLanguageChange(LANG_EN);
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // 本机信息
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 12 }) {
            this.infoRow($r('app.string.settings_app_name'), 'KDE-H Connect', false)
            this.infoRow($r('app.string.settings_app_version'), '0.1.0-dev', false)
            this.infoRow($r('app.string.settings_device_id'), this.deviceId, true)
            this.infoRow($r('app.string.settings_protocol_version'), '8', false)
            this.infoRow($r('app.string.settings_ports'), 'UDP 1716 · TCP 1716-1764', false)
            this.infoRow($r('app.string.settings_status'), this.statusText, false)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.TopStart)
  }
}
