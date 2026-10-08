// SPDX-FileCopyrightText: 2026 KDE Connect HarmonyOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// ohosTest 运行器（DevEco 标准模板；由构建系统按 ohosTest target 注入调用）。
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';

let abilityDelegator: abilityDelegatorRegistry.AbilityDelegator;
let abilityDelegatorArguments: abilityDelegatorRegistry.AbilityDelegatorArgs;
let jsonPath: string = 'mock/mock-config.json';
let tag: string = 'testTag';

async function onAbilityCreateCallback(data: UIAbility): Promise<void> {
  hilog.info(0x0000, 'testTag', 'onAbilityCreateCallback, data: %{public}s', JSON.stringify(data));
}

async function addAbilityMonitorCallback(err: BusinessError): Promise<void> {
  hilog.info(0x0000, 'testTag', 'addAbilityMonitorCallback : %{public}s', JSON.stringify(err) ?? '');
}

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(0x0000, 'testTag', '%{public}s', 'OpenHarmonyTestRunner OnPrepare');
  }

  async onRun(): Promise<void> {
    hilog.info(0x0000, tag, '%{public}s', 'OpenHarmonyTestRunner onRun run');
    abilityDelegatorArguments = abilityDelegatorRegistry.getArguments();
    abilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
    const moduleName: string = abilityDelegatorArguments.parameters['-m'];
    const context = abilityDelegator.getAppContext().getApplicationContext().createModuleContext(moduleName);
    const mResourceManager: resourceManager.ResourceManager = context.resourceManager;
    await checkMock(abilityDelegator, mResourceManager);
    const bundleName: string = abilityDelegatorArguments.bundleName;
    const testAbilityName: string = 'TestAbility';
    const lMonitor: abilityDelegatorRegistry.AbilityMonitor = {
      abilityName: testAbilityName,
      onAbilityCreate: onAbilityCreateCallback,
      moduleName: moduleName
    };
    abilityDelegator.addAbilityMonitor(lMonitor, addAbilityMonitorCallback);
    const want: Want = {
      bundleName: bundleName,
      abilityName: testAbilityName,
      moduleName: moduleName
    };
    abilityDelegator.startAbility(want, (err: BusinessError, data: void) => {
      hilog.info(0x0000, tag, 'startAbility : err : %{public}s', JSON.stringify(err) ?? '');
      hilog.info(0x0000, tag, 'startAbility : data : %{public}s', JSON.stringify(data) ?? '');
    });
    hilog.info(0x0000, tag, '%{public}s', 'OpenHarmonyTestRunner onRun end');
  }
}

async function checkMock(delegator: abilityDelegatorRegistry.AbilityDelegator,
  rm: resourceManager.ResourceManager): Promise<void> {
  try {
    const rawFile: Uint8Array = rm.getRawFileContentSync(jsonPath);
    hilog.info(0x0000, tag, 'MockList file exists');
    const mockStr: string = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(rawFile);
    const mockMap: Record<string, string> = getMockList(mockStr);
    try {
      delegator.setMockList(mockMap);
    } catch (error) {
      const code = (error as BusinessError).code;
      const message = (error as BusinessError).message;
      hilog.error(0x0000, tag, `abilityDelegator.setMockList failed, error code: ${code}, message: ${message}.`);
    }
  } catch (error) {
    const code = (error as BusinessError).code;
    const message = (error as BusinessError).message;
    hilog.error(0x0000, tag,
      `ResourceManager: getRawFileContent failed, error code: ${code}, message: ${message}.`);
  }
}

function getMockList(jsonStr: string): Record<string, string> {
  const jsonObj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
  const mockList: Record<string, string> = {};
  const map: Map<string, object> = new Map<string, object>(Object.entries(jsonObj));
  map.forEach((value: object, key: string) => {
    const realValue: string = value['source'].toString();
    mockList[key] = realValue;
  });
  hilog.info(0x0000, tag, '%{public}s', 'mock-json value:' + JSON.stringify(mockList) ?? '');
  return mockList;
}
