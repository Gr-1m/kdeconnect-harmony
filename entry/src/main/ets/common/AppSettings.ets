import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';

// 应用设置常量与换算（Preferences: 'themeMode' number / 'language' string）

export const THEME_FOLLOW_SYSTEM: number = 0;
export const THEME_LIGHT: number = 1;
export const THEME_DARK: number = 2;

// 'system' = 跟随系统；其余为 ApplicationContext.setLanguage 的取值
export const LANG_SYSTEM: string = 'system';
export const LANG_ZH: string = 'zh-Hans';
export const LANG_EN: string = 'en-US';

// 主题模式 → 系统 ColorMode（跟随系统用 NOT_SET）
export function colorModeOf(themeMode: number): ConfigurationConstant.ColorMode {
  if (themeMode === THEME_LIGHT) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  if (themeMode === THEME_DARK) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

// 语言设置 → setLanguage 入参（跟随系统时取系统语言）
export function languageOf(language: string): string {
  if (language === LANG_SYSTEM) {
    return i18n.System.getSystemLanguage();
  }
  return language;
}
