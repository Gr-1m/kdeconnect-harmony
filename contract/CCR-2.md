# CCR-2: contract/ 目录布局

- 日期：2026-11-08
- 提出人：CodeArts（依据 MSG196 AtomCode §7.5 裁决）
- 状态：**已批准（2026-11-09 用户批准，AtomCode 记录）— 两车道均按仓库根 `contract/` 消费**
- 影响：仓库结构、08 §9 工件落位

## 动机

桥层契约迁移提案 §7.5（PROPOSAL_BRIDGE_CONTRACT_MIGRATION_20261108）：`contract/` 目录落点选择。MSG196 AtomCode 裁决：仓库根 `contract/`。

kdeconn1109（参考版本）将 `contract/` 放在工程子目录 `kdeconn-1108/contract/` 下——这是单工程结构下的自然选择。我们是双车道结构（Rust + ArkTS），两车道都需消费契约工件，放仓库根更合理。

## 变更内容

### 仓库根新增 `contract/` 目录

```
contract/
├── kcbridge.d.ts          # 08 §2 逐字（命令 API 签名）
├── errors.v1.json         # 08 §4 机读（20 码 + kind + disposition）
├── capabilities.v1.json   # 08 §10 机读（14 插件能力集）
├── scenarios/             # 08 §8 起步集
│   ├── pairing-in.json    # 已有（参考 kdeconn1109）
│   ├── share-in.json      # 需自建
│   ├── share-out.json     # 需自建
│   └── ping.json          # 需自建
├── CCR-1.md               # 本文件之前的 CCR
├── CCR-2.md               # 本文件
└── ...                    # 后续 CCR
```

### 08 §9 工件清单更新

原文：
> 工件清单（M0 落位）：`contract/kcbridge.d.ts`（§2 逐字）、`contract/errors.v1.json`（§4 机读）、`contract/capabilities.v1.json`（§10）、`contract/scenarios/*.json`（§8 起步集）、`contract/CCR-*.md`。

确认：仓库根 `contract/`，与 08 §9 描述一致（"M0 时逐字拷入 `contract/`"）。

### .gitignore 无需变更

`contract/` 入库，不排除。

## 两车道影响

| 车道 | 影响 |
|---|---|
| Rust（Omp-Native） | `include_str!("../../contract/errors.v1.json")` 等路径引用（相对仓库根） |
| ArkTS（Omp-ArkTS） | `import { KcApi } from '../../contract/kcbridge.d.ts'` 等路径引用（相对工程目录） |

## 向后兼容

- 新增目录，不影响现有代码
- `entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts` 在桥层 P4 收口时删除，P0-P3 期间并行保留

## 验收

- `contract/` 目录在仓库根创建
- 5 个工件文件齐备（kcbridge.d.ts + errors.v1.json + capabilities.v1.json + scenarios/ + CCR）
- 两车道各自确认路径引用方式
