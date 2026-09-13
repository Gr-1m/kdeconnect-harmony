import { ConfigurationConstant, Context } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import deviceInfo from '@ohos.deviceInfo';
import settings from '@ohos.settings';

// 应用设置常量与换算（Preferences: 'themeMode' number / 'language' string）

// 设备名兜底值（系统名称全部读不到时才用）
export const FALLBACK_DEVICE_NAME: string = 'kdeconnect-harmony';

// 读取「系统设备名称」：优先系统设置里的设备名称（设置→关于本机→设备名称，即蓝牙/多设备协同时显示的名字），
// 其次市场名（如 Mate 80 Pro），再次「品牌 + 型号」（如 HUAWEI SGT-AL50）。
// 三方应用对 settings.general 域可能被限制（抛错/返回空），故逐级回退，绝不抛异常。
export function systemDeviceName(ctx: Context | undefined): string {
  if (ctx !== undefined) {
    try {
      const raw: string = settings.getValueSync(ctx, settings.general.DEVICE_NAME, '');
      if (raw.length > 0) {
        return raw;
      }
    } catch (e) {
      console.warn('KDC systemDeviceName: settings.general.DEVICE_NAME unavailable: '
        + (e instanceof Error ? e.message : 'unknown'));
    }
  }
  try {
    if (deviceInfo.marketName.length > 0) {
      return deviceInfo.marketName;
    }
  } catch (e) {
    console.warn('KDC systemDeviceName: marketName unavailable');
  }
  try {
    if (deviceInfo.productModel.length > 0) {
      return `${deviceInfo.brand} ${deviceInfo.productModel}`;
    }
  } catch (e) {
    console.warn('KDC systemDeviceName: productModel unavailable');
  }
  return FALLBACK_DEVICE_NAME;
}

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
