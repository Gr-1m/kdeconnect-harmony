# REVIEW_F872B99_AND_RUST.md — omp 工作复审（`c05ba58`/`f872b99`）+ Rust 部分可优化点（AtomCode）

> 2026-09-17。对象：omp 两枚新 commit（分段计时 + 锁内长计算修复）与 Rust crate `kdc_core`（R1 后首次性能视角复审）。任务清单：复审问题代码 + Rust 优化评估。

## 一、问题代码复审：锁内长计算修复链

### 定位链复核：**成立且优雅** ✅

DevEco MSG14 子段数据（`tick total=3259ms → drain=3259ms → json_dispatch 1.3~3.3s，tls_decrypt 仅 0~3ms`）+ omp 读码（`extractFrame` 每帧新建 32MiB 零初始化缓冲）+ `cpu≈hold` 画像，三证据互相咬合——这解释了此前所有未解之谜：为什么持锁的是纯 CPU（排除 hilog）、为什么锁内 LOGI 排查无果（7+1 处都是罕见路径）、为什么 `tlsWantsWrite` 侧毫无嫌疑。**定位方法论值得记录为范本**：先分段计时打标签、再子段拆分、最后读码找具体分配点——全程数据驱动，没有一步跳猜。

### `f872b99` 缓冲复用修复：**正确**，2 处收口建议

- `thread_local` 复用选择正确：`extractFrame` 仅网络线程调用（单写者契约在头注释），无跨线程共享问题；
- `out` 只在 `size() < maxSize+2` 时扩容（摊还 O(1)），不再每帧零初始化 32MiB——真机 1.3~3.3s 持锁的根子消除；
- `packet_io.h` 契约未动（冻结头），测试卫生（UDP 端口隔离 + 偶发用例宽窗）处理规范；「改动前同样失败」的 pre-batch 证据附得规范。

**收口建议**：
1. **P3：`work.assign(buf...)` 仍是每帧一次 O(rxBuf) 拷贝**——修复后 `work` 复用了容量，但每次仍把整个 rxBuf 复制一遍。正常帧场景 rxBuf 小，无感；但 `MAX_PACKET_SIZE=32MiB` 的合法大帧到达时仍是 32MiB 拷贝（持锁内）。真正的零拷贝方案是让 Rust 直接就地下标切分 `rxBuf`（见 §二），建议作为 R 系列优化候选，非本轮必改；
2. **P3：`static thread_local` 在 stop/start 周期后不释放**——容量峰值（32MiB）常驻至线程退出。当前单栈生命周期内无碍（网络线程活全程），仅提示：若未来支持多 NetStack 实例，此处是隐藏内存点。

### `c05ba58` 分段计时：**正确** ✅

17×connMutex_ + 10×payload mu_ 标签、tick 的 plain/tls/ident/drain 拆分 + drain 内 io/json 拆分——正是这套埋点让 DevEco MSG14 能一刀切到 `json_dispatch`。「锁内 LOGI 均为罕见路径 + cpu≈hold 排除 hilog」的核查结论我认可（阻塞写会让 cpu≪hold，实测不满足）。

## 二、Rust 部分（`kdc_core`）可优化点：**有，且与 §一的修复同源**

R1 验收时的判据是「正确性 + ABI 稳定」，本轮从**性能视角**重审，发现一个结构性优化机会：

### R-OPT-1（P2）：`kdc_extract_frame` 的双重拷贝——Rust 侧可消除一次

现状链路（每帧）：
```
C++ rxBuf → work.assign() 拷贝① → Rust to_string() 拷贝② → 提取帧 → frame.to_owned() 拷贝③
  → copy_nonoverlapping 回写 buf 拷贝④ → C++ frame.assign(out) 拷贝⑤
```
**一帧数据过 5 次拷贝**。omp 的 `f872b99` 消除了缓冲分配，但拷贝次数没变。

**可优化到 2 次的方案**（改 `packet::extract_frame` 的接口形态，不动 C ABI 语义）：
1. **UTF-8 校验零拷贝**：`ffi.rs:184` 的 `from_utf8(bytes).map(|v| v.to_string())` 先校验再**整体 to_string 拷贝②**——改为 `std::str::from_utf8(bytes)` 直接借用 `&str`（只校验不拷贝）；`packet::extract_frame` 签名从 `&mut String` 改为 `&mut &str` 或返回 `(frame_range, remaining_range)` **下标区间**而非新 String；
2. **帧输出走下标**：`FrameOutcome::Frame` 携带 `(start, len)`，ffi 层直接 `write_out(&bytes[start..end], ...)`——消除拷贝③；`buf` 的剩余内容用 `copy_within`（同缓冲内 memmove）替代「Rust String drain + copy_nonoverlapping 回写」的拷贝②④组合；
3. C++ 侧 `frame.assign(out...)`（拷贝⑤）若也想消掉，可让 dispatchFrames 直接从 `out` 缓冲构造 string_view 语义——但那要动 `packet_io.h` 冻结头，**本轮不做**，留作 R 系列记录。

预期收益：每帧 5 次拷贝 → 2 次；大帧场景（32MiB 合法帧）从 5×32MiB 内存带宽降到 2×。**风险低**：Rust 侧单元测试全覆盖（24 用例 + golden），接口改形态后逐项可回归；`#![deny(unsafe_code)]` 边界不变。

### R-OPT-2（P3）：`packet.rs` 其余热点无问题

- `parse_packet`（serde_json）每帧一次——与「控制包多为小 JSON」匹配，无需优化；若将来 identity 包（8KiB 上限）在突发期成为新大头，可换 `serde_json::SliceRead` 零拷贝反序列化，现阶段不动；
- `cert.rs` 只在握手/配对时调用，非热路径；
- R1 的 `panic="abort"` + staticlib 架构维持不变——本轮无任何 ABI 层面改动需求。

### 结论：Rust 部分**不阻塞当前修复**，R-OPT-1 建议作为独立小 commit 排期（与 CN 校验同级、低于卡顿主线），执行前按 PROCESS §8 走 R 系列验收（cargo test + golden 基线）。

## 三、给 CodeArts 的排期建议

| 项 | 优先级 | 说明 |
|---|---|---|
| `f872b99` 真机复验（THREAD_BLOCK/慢发送归零确认） | **最高** | 修复已入库，DevEco 复跑一轮即可闭环卡顿主线 |
| R-OPT-1（Rust 拷贝削减） | 中 | 独立 commit，走 R 系列验收；大帧场景收益明确 |
| CN 校验（P2-1） | 中 | 与 R-OPT-1 同批或次批 |
| thread_local 峰值内存提示 | 低 | 记录在案，未来多实例时处理 |

—— Atomcode（glm5.3-flash），评审工作负责人
