// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
import uiMaterial from '@ohos.arkui.uiMaterial';
import { bundleManager, common, Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { GlassCard } from './GlassCard';
import { OptionPill } from './OptionPill';
import { THEME_FOLLOW_SYSTEM, THEME_LIGHT, THEME_DARK, LANG_SYSTEM, LANG_ZH, LANG_EN } from '../common/AppSettings';

// 设置 Tab：本机身份与协议信息 + 可自定义设备名称 / 主题（跟随系统·亮·暗）/ 语言（默认跟随系统）。
@Component
export struct SettingsTab {
  @Prop deviceId: string = '';
  // 父页面 Preferences 读取完成晚于本组件首次构建，用 @Watch 同步草稿，避免显示默认值
  @Prop @Watch('onDeviceNameChanged') deviceName: string = '';
  // 系统设备名称（只读展示；「使用系统名称」按钮用它回填）
  @Prop systemName: string = '';
  @Prop statusText: string = '';
  @Prop themeMode: number = THEME_FOLLOW_SYSTEM;
  @Prop language: string = LANG_SYSTEM;
  @Prop immersive: boolean = false;
  @Prop settingsSection: number = 0;
  cardMaterial: uiMaterial.Material | undefined = undefined;
  onRenameDevice: (name: string) => void = () => {
  };
  // 「使用系统名称」：把设备名回填为系统设备名称
  onUseSystemName: () => void = () => {
  };
  onThemeChange: (mode: number) => void = () => {
  };
  onLanguageChange: (lang: string) => void = () => {
  };
  @State nameDraft: string = '';
  // 用户是否已手动编辑草稿（否则外部 deviceName 更新时应同步草稿）
  @State nameEdited: boolean = false;
  // 备案链接的「点击后」状态（点击前显示查询入口并置灰，点击后换成强调色 + 已打开文案）
  @State icpOpened: boolean = false;

  aboutToAppear(): void {
    this.nameDraft = this.deviceName;
  }

  onDeviceNameChanged(): void {
    if (!this.nameEdited) {
      this.nameDraft = this.deviceName;
    }
  }

  // 贡献者邮箱：不直接列在页面上（避免被抓取），改成点贡献者名字弹小窗展示。
  // 目前暂未公开 ⇒ 小窗提示「暂未公开」；以后把真实邮箱填进 contributorEmail 即可。
  private contributorEmail: string = '';
  @State emailPopupShown: boolean = false;

  private contribEmailText(): string {
    return this.contributorEmail.length > 0
      ? this.contributorEmail
      : this.resText($r('app.string.settings_about_email_pending').id);
  }

  // 应用版本：唯一来源是 AppScope/app.json5 的 versionName（目前从 0.1.0 起算，尚无首个正式版本）
  private appVersion(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      return '0.1.0';
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

  // 打开外部链接：Hyperlink 组件**不支持 fontSize**（只吃默认大字号的链接字），和卡片里 12fp 的
  // 文字混排会又大又突兀（用户反馈「关于块很丑、字体大小奇怪」）⇒ 统一用 Text + openLink，
  // 字号/颜色/下划线都能与卡片其它文字对齐。
  private openUrl(url: string): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      ctx.openLink(url).catch((err: BusinessError): void => {
        console.warn(`open link failed: ${url} (code=${err.code})`);
      });
    } catch (e) {
      console.warn(`open link failed: ${url}`);
    }
  }

  // 「标签: 值」纯文字行（用户 2026-09-16 裁决：开源仓库不再做链接，直接写文字）。
  // 标签用固定宽度 ⇒ 两个仓库名的起始位置对齐；整体缩进一级，与后面的条目保持一致。
  @Builder
  indentedTextRow(label: string, value: string) {
    Row() {
      Text(label + ':')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width(72)
      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14 })
  }

  // 资源字符串取值（SettingsTab 里没有 Index 的 resText，照同款写法补一个）
  private resText(resId: number): string {
    try {
      const hostCtx: Context | undefined = this.getUIContext().getHostContext();
      if (hostCtx === undefined) {
        return '';
      }
      return hostCtx.resourceManager.getStringSync(resId);
    } catch (e) {
      return '';
    }
  }

  // 选中态一律用子组件 OptionPill（@Prop 驱动）——不要用 @Builder 传值：
  // @Builder 的参数不变时会跳过重建，表现为"点击有效但高亮不跟随"。
  build() {
    Column({ space: 12 }) {
      if (this.settingsSection === 0) {
        // 设备名称（可自定义）
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 10 }) {
            this.sectionTitle($r('app.string.settings_device_name'))
            Row({ space: 8 }) {
              TextInput({ text: this.nameDraft, placeholder: this.systemName.length > 0 ? this.systemName : 'kdeconnect-harmony' })
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
            if (this.systemName.length > 0) {
              Row({ space: 8 }) {
                Text($r('app.string.settings_system_name_label'))
                  .fontSize(11)
                  .fontColor($r('app.color.text_muted'))
                Text(this.systemName)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text($r('app.string.settings_use_system_name'))
                  .fontSize(11)
                  .fontColor($r('app.color.accent_text'))
                  .onClick(() => {
                    this.nameDraft = this.systemName;
                    this.nameEdited = false;
                    this.onUseSystemName();
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // 主题
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 10 }) {
            this.sectionTitle($r('app.string.settings_theme'))
            Row({ space: 8 }) {
              OptionPill({
                label: $r('app.string.follow_system'),
                active: this.themeMode === THEME_FOLLOW_SYSTEM,
                onPick: (): void => {
                  this.onThemeChange(THEME_FOLLOW_SYSTEM);
                }
              })
              OptionPill({
                label: $r('app.string.theme_light'),
                active: this.themeMode === THEME_LIGHT,
                onPick: (): void => {
                  this.onThemeChange(THEME_LIGHT);
                }
              })
              OptionPill({
                label: $r('app.string.theme_dark'),
                active: this.themeMode === THEME_DARK,
                onPick: (): void => {
                  this.onThemeChange(THEME_DARK);
                }
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
              OptionPill({
                label: $r('app.string.follow_system'),
                active: this.language === LANG_SYSTEM,
                onPick: (): void => {
                  this.onLanguageChange(LANG_SYSTEM);
                }
              })
              OptionPill({
                label: $r('app.string.lang_zh'),
                active: this.language === LANG_ZH,
                onPick: (): void => {
                  this.onLanguageChange(LANG_ZH);
                }
              })
              OptionPill({
                label: $r('app.string.lang_en'),
                active: this.language === LANG_EN,
                onPick: (): void => {
                  this.onLanguageChange(LANG_EN);
                }
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      } else if (this.settingsSection === 1) {
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 12 }) {
            this.sectionTitle($r('app.string.settings_drawer_info'))
            this.infoRow($r('app.string.settings_app_name'), 'KDE Connect', false)
            this.infoRow($r('app.string.settings_app_version'), this.appVersion(), false)
            this.infoRow($r('app.string.settings_device_id'), this.deviceId, true)
            this.infoRow($r('app.string.settings_protocol_version'), '8', false)
            this.infoRow($r('app.string.settings_ports'), 'UDP 1716 · TCP 1716-1764', false)
            this.infoRow($r('app.string.settings_status'), this.statusText, false)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      } else if (this.settingsSection === 2) {
        GlassCard({ immersive: this.immersive, cardMaterial: this.cardMaterial }) {
          Column({ space: 12 }) {
            this.sectionTitle($r('app.string.settings_drawer_about'))
            this.indentedTextRow('GitCode', 'Gr1m/kdeconnect-harmony')
            this.indentedTextRow('GitHub', 'Gr-1m/kdeconnect-harmony')
            this.infoRow($r('app.string.settings_about_version'), this.appVersion(), false)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
