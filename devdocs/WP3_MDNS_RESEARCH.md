# WP-3 mDNS 发现机制调研报告

> CodeArts（总指挥）调研，2026-09-13。  
> 目标：为鸿蒙版 KDE Connect 选择 mDNS 实现方案，替代/补充 UDP 广播发现。

## 1. 背景与动机

当前鸿蒙版仅用 UDP 全局广播（`255.255.255.255:1716`）发现设备。已知问题：
- 部分路由器/网络环境屏蔽全局广播
- Win10 QEMU 模拟器 NAT 下 UDP 广播不可达
- 企业网 172.16/12 网段也有广播受限风险

KDE 桌面端和 iOS 端均采用 **UDP 广播 + mDNS 双通道** 策略，mDNS 作为辅助提升到达率。

## 2. 各端 mDNS 实现对照

| 端 | 库/API | 服务类型 | TXT 记录 | 发现后行为 |
|---|---|---|---|---|
| **KDE 桌面** | `mdns.h` header-only（[mjansson/mdns](https://github.com/mjansson/mdns)） | `_kdeconnect._udp.local` | `id`, `name`, `type`, `protocol` | 向发现的 IP 发 UDP identity 包 |
| **iOS** | `NWBrowser` + `NetService`（系统框架） | `_kdeconnect._udp` | 同上 | 同上 |
| **Android** | 无 mDNS（仅 UDP 广播） | — | — | — |
| **鸿蒙（待实现）** | `@ohos.net.mdns`（系统 API）或 vendor `mdns.h` | `_kdeconnect._udp` | 同上 | 待定 |

### 2.1 KDE 桌面端关键实现细节

- `MdnshDiscovery`（`mdnshdiscovery.cpp`）：Announcer + Discoverer 双角色
- Announcer：注册服务 + 监听查询 + 响应 PTR/SRV/A/AAAA/TXT 记录
- Discoverer：发送 PTR 查询 + 监听响应 + 解析 PTR(实例名)/SRV(端口)/A(IP)/TXT(属性)
- 发现服务后：`lanLinkProvider->sendUdpIdentityPacket({service.address})` — **不直接 TCP 连接**，而是向发现的地址发 UDP identity，让对方主动连过来（与 UDP 广播发现后的流程一致）
- 网络变化时：重启 Discoverer（停止 + 重新开始发现）

### 2.2 鸿蒙系统 mDNS API 概览

SDK 定义文件：`/opt/ohos-sdk/26/ets/api/@ohos.net.mdns.d.ts`

| API | 功能 | 关键约束 |
|---|---|---|
| `addLocalService(context, serviceInfo)` | 注册/宣告本地 mDNS 服务 | 需 Context；`serviceType` 格式 `_<name>._<tcp/udp>` |
| `removeLocalService(context, serviceInfo)` | 移除本地服务 | — |
| `createDiscoveryService(context, serviceType)` | 创建发现服务对象 | 返回 `DiscoveryService` 实例 |
| `resolveLocalService(context, serviceInfo)` | 解析服务获取 IP+端口 | `serviceFound` 回调通常不含 IP，必须再调此方法 |
| `DiscoveryService.startSearchingMDNS()` | 开始搜索 | — |
| `DiscoveryService.stopSearchingMDNS()` | 停止搜索 | — |
| 事件 `serviceFound` | 发现服务 | 回调参数 `LocalServiceInfo`（可能缺 `host`） |
| 事件 `serviceLost` | 服务消失 | — |
| 事件 `discoveryStart/Stop` | 搜索开始/停止 | — |

**`LocalServiceInfo` 结构**：
```typescript
interface LocalServiceInfo {
  serviceType: string;       // "_kdeconnect._udp"
  serviceName: string;       // "kdeconnect-<deviceId>"
  port?: number;             // TCP 端口 (1716-1764)
  host?: NetAddress;         // 仅 resolveLocalService 后填充
  serviceAttribute?: Array<ServiceAttribute>;  // TXT 记录
}

interface ServiceAttribute {
  key: string;               // 最大 9 字符！
  value: Array<number>;      // UTF-8 字节数组（不是字符串）
}
```

**关键限制**：
1. `ServiceAttribute.key` **最大 9 字符** — KDE 用的 `deviceId`(8)、`name`(4)、`type`(4)、`protocol`(8) 均在限制内 ✓
2. `ServiceAttribute.value` 是 `Array<number>` — 字符串必须编码为 UTF-8 字节数组
3. `serviceFound` 回调**通常不含确切 IP** — 必须再调 `resolveLocalService`（两步流程）
4. 所有 API 需要 `Context` 参数 — **必须在 ArkTS 层调用**，不能直接从 native C++ 调用
5. SystemCapability：`SystemCapability.Communication.NetManager.MDNS`（API 10+，atomicservice API 11+）

## 3. 方案对比

### 方案 A：使用鸿蒙系统 mDNS API（纯 ArkTS 层）

**实现路径**：ArkTS 层 `MdnsDiscovery` 类 → 系统服务 → NAPI 回调通知 native

**优点**：
- 官方 API，系统集成最佳（后台行为、网络变化处理、省电策略由系统管理）
- 无需 vendor 任何第三方库
- `serviceLost` 事件可替代当前有问题的 60s 超时 `deviceLost` 机制

**缺点**：
- 与现有 native 网络栈架构不一致（发现层在 ArkTS，连接层在 native）
- `serviceAttribute.value` 是数字数组，需手动编码/解码字符串
- `serviceFound` → `resolveLocalService` 两步流程增加延迟
- QEMU 模拟器可能不支持系统 mDNS 服务（与 UDP 广播同样的 NAT 限制）

### 方案 B：Native 自实现最小 DNS-SD（vendor `mdns.h`）

**实现路径**：vendor `mdns.h` → native `MdnsDiscovery` 类 → 与 `UdpDiscovery` 并行

**优点**：
- 与 KDE 桌面端用**同一库**（`mdns.h`），行为完全一致
- 在 native 层实现，与现有网络栈架构一致
- 可直接复用 KDE 的 `MdnshWrapper` 设计（Announcer + Discoverer）
- 发现后可直接拿到 IP+端口，无需两步解析

**缺点**：
- 需 vendor `mdns.h`（header-only，~2000 行，但功能成熟）
- 需自己处理多网卡 socket 管理、网络变化重发现
- 系统可能对 native 层的 multicast socket 有额外限制
- 不如系统 API 省电（系统 mDNS 服务可聚合多个应用的查询）

### 方案 C：混合方案（ArkTS 系统 API + native UDP 双通道）★ 推荐

**实现路径**：
- ArkTS 层：`MdnsDiscovery` 类用系统 API 做服务宣告 + 发现
- 发现到对端后：`resolveLocalService` → 拿到 IP+端口 → NAPI 回调通知 native
- native 层：`NetStack` 新增 `onMdnsDeviceFound(ip, port)` → 走与 UDP 发现相同的连接流程
- 两通道并行：UDP 广播 + mDNS 互为补充

**优点**：
- 充分利用系统 mDNS 服务的集成优势（省电、网络变化处理）
- 与现有 native 网络栈无缝衔接（native 只需新增一个入口点）
- 双通道策略与 KDE 桌面端/iOS 端一致
- 不需要 vendor 任何第三方库

**缺点**：
- ArkTS ↔ native 的 NAPI 回调增加少量复杂度
- `serviceAttribute.value` 编码转换
- 两步解析流程（`serviceFound` → `resolveLocalService`）

## 4. 推荐方案：C（混合方案）

### 4.1 理由

1. **鸿蒙平台硬约束**：系统 mDNS API 需要 Context，只能在 ArkTS 层调用 — 这是平台限制，不是设计选择
2. **与现有架构兼容**：native 网络栈（UDP/TCP/TLS）保持不变，只需新增 `onMdnsDeviceFound` 入口
3. **双通道策略**：与 KDE 桌面端/iOS 端的设计一致，UDP 广播 + mDNS 互为补充
4. **无需 vendor 新库**：减少代码量和维护成本
5. **系统服务优势**：省电、后台行为、网络变化处理由系统管理

### 4.2 实现架构

```
┌─────────────────────────────────────────────┐
│ ArkTS 层                                     │
│                                              │
│  ┌──────────────┐    ┌──────────────────┐   │
│  │ UdpDiscovery │    │ MdnsDiscovery    │   │
│  │ (native NAPI)│    │ (系统 @ohos.mdns)│   │
│  │              │    │                  │   │
│  │ broadcast ←──┤    │ addLocalService  │   │
│  │ readIdentity │    │ startSearching   │   │
│  │              │    │ serviceFound     │   │
│  │              │    │ resolveLocal     │   │
│  └──────┬───────┘    └────────┬─────────┘   │
│         │                     │              │
│         │              NAPI 回调:             │
│         │              onMdnsDeviceFound     │
│         │                     │              │
├─────────┼─────────────────────┼──────────────┤
│ Native  │                     │              │
│         ▼                     ▼              │
│  ┌──────────────────────────────────────┐    │
│  │ NetStack                             │    │
│  │  - UDP broadcast (existing)          │    │
│  │  - mDNS device found (new entry)     │    │
│  │  - TCP connect → TLS → identity      │    │
│  └──────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### 4.3 ArkTS 层实现规格

```typescript
import { mdns } from '@kit.NetworkKit';

class MdnsDiscovery {
  private discoveryService: mdns.DiscoveryService | null = null;
  private localService: mdns.LocalServiceInfo | null = null;

  // 宣告自己
  async startAnnouncing(context: Context, deviceId: string, deviceName: string,
                         deviceType: string, tcpPort: number): Promise<void> {
    this.localService = {
      serviceType: '_kdeconnect._udp',
      serviceName: `kdeconnect-${deviceId}`,
      port: tcpPort,
      serviceAttribute: [
        { key: 'id', value: this.strToBytes(deviceId) },
        { key: 'name', value: this.strToBytes(deviceName) },
        { key: 'type', value: this.strToBytes(deviceType) },
        { key: 'protocol', value: this.strToBytes('8') },
      ]
    };
    await mdns.addLocalService(context, this.localService);
  }

  // 发现对端
  startDiscovering(context: Context): void {
    this.discoveryService = mdns.createDiscoveryService(context, '_kdeconnect._udp');
    this.discoveryService.on('serviceFound', (info: mdns.LocalServiceInfo) => {
      mdns.resolveLocalService(context, info).then((resolved) => {
        if (resolved.host?.address && resolved.port) {
          // NAPI 回调通知 native
          nativeNetStack.onMdnsDeviceFound(resolved.host.address, resolved.port);
        }
      });
    });
    this.discoveryService.startSearchingMDNS();
  }

  // 停止
  stop(context: Context): void {
    this.discoveryService?.stopSearchingMDNS();
    if (this.localService) {
      mdns.removeLocalService(context, this.localService);
    }
  }

  // 字符串 → UTF-8 字节数组（ServiceAttribute.value 要求 Array<number>）
  private strToBytes(s: string): Array<number> {
    const encoder = new TextEncoder();
    return Array.from(encoder.encode(s));
  }
}
```

### 4.4 Native 层新增入口

`NetStack` 新增方法：
```cpp
void NetStack::onMdnsDeviceFound(const std::string &ip, uint16_t port) {
    // 与 UDP 发现走相同的连接流程：
    // 1. 检查是否是自己（deviceId 匹配）
    // 2. 检查是否已有连接
    // 3. TCP connect → TLS → identity 交换
    // 与 onUdpIdentityReceived 共享连接逻辑
}
```

NAPI 桥接新增：
```typescript
// napi_exports.cpp
napi_value OnMdnsDeviceFound(napi_env env, napi_callback_info info) {
    // 解析 ip + port 参数
    // 调用 NetStack::onMdnsDeviceFound
}
```

### 4.5 与 KDE 桌面端的互操作

KDE 桌面端 mDNS 发现后的行为：**向发现的 IP 发 UDP identity 包**（不直接 TCP 连接）。

鸿蒙版的 `onMdnsDeviceFound` 有两种选择：
1. **与 KDE 一致**：向发现的 IP 发 UDP identity 包，等对方主动连过来
2. **直接 TCP 连接**：跳过 UDP identity，直接 TCP connect（protocol v8 已有足够信息）

**推荐选择 1**（与 KDE 一致），理由：
- 保持与所有对端的互操作一致性
- KDE 桌面端代码注释提到 v8 可以跳过 UDP 直接 TCP，但尚未实现
- 通过 UDP identity 包，对端可以用标准的连接限流/信任检查逻辑

### 4.6 serviceAttribute 编码

| key | 最大长度 | value | 编码 |
|---|---|---|---|
| `id` | 2 ≤ 9 ✓ | deviceId（32-38 字符） | UTF-8 字节数组 |
| `name` | 4 ≤ 9 ✓ | deviceName | UTF-8 字节数组 |
| `type` | 4 ≤ 9 ✓ | deviceType（如 "phone"） | UTF-8 字节数组 |
| `protocol` | 8 ≤ 9 ✓ | "8" | UTF-8 字节数组 |

**注意**：KDE 桌面端 TXT 记录的 key 是 `id`/`name`/`type`/`protocol`，鸿蒙系统 API 的 `ServiceAttribute.key` 最大 9 字符，全部满足。

### 4.7 module.json5 权限

需确认是否需要额外权限声明。mDNS API 属于 `SystemCapability.Communication.NetManager.MDNS`，当前 `module.json5` 已声明 `ohos.permission.INTERNET`。需验证：
- mDNS 是否需要 `ohos.permission.GET_WIFI_INFO` 或类似权限
- 是否需要在 `module.json5` 的 `metadata` 中声明 MDNS capability

## 5. 风险与待验证项

| 风险 | 影响 | 缓解 |
|---|---|---|
| QEMU 模拟器不支持系统 mDNS 服务 | 开发期无法测试 mDNS | 真机测试为主；模拟器走 UDP 广播/手动连接 |
| `resolveLocalService` 超时或失败 | 发现但无法连接 | 增加超时和重试逻辑 |
| 系统后台限制 mDNS 活动 | 后台发现不可靠 | 前台时主动搜索；后台依赖系统行为 |
| `serviceAttribute.value` 编码不一致 | 对端无法解析 TXT 记录 | 严格使用 UTF-8 编码，与 KDE 的 `QString::toLatin1` 对齐（注意：KDE 用 Latin1 不是 UTF-8，但 deviceId/name 都是 ASCII，两者一致） |
| 系统服务可能缓存旧服务宣告 | 重启后 serviceName 冲突 | 使用 `removeLocalService` 清理；serviceName 含 deviceId 保证唯一 |

## 6. 实现任务拆解（给 ZCode/DevEco）

| 任务 | 负责人 | 依赖 | 优先级 |
|---|---|---|---|
| ArkTS `MdnsDiscovery` 类实现 | DevEco Code | 无 | P1 |
| NAPI `onMdnsDeviceFound` 桥接 | ZCode | ArkTS 类定义 | P1 |
| Native `NetStack::onMdnsDeviceFound` | ZCode | NAPI 桥接 | P1 |
| `module.json5` 权限/capability 验证 | DevEco Code | 真机测试 | P2 |
| mDNS + UDP 双通道集成测试 | DevEco Code | 全部实现完成 | P2 |
| 与 KDE 桌面端 mDNS 互操作测试 | 用户 | 联测环境 | P2 |

## 7. 结论

**推荐方案 C（混合方案）**：ArkTS 层用系统 `@ohos.net.mdns` API 做服务宣告和发现，发现结果通过 NAPI 回调传给 native 层，native 层走与 UDP 发现相同的 TCP→TLS→identity 连接流程。双通道并行（UDP 广播 + mDNS），与 KDE 桌面端/iOS 端的设计一致。

**核心优势**：无需 vendor 第三方库、与系统集成最佳、与现有 native 网络栈无缝衔接。

**关键约束**：系统 mDNS API 需要 Context（只能在 ArkTS 层调用）；`serviceAttribute.value` 是数字数组需编码转换；`serviceFound` 后需 `resolveLocalService` 两步解析。
