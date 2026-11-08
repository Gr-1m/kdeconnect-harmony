# 0.8.4 合并 Runbook（全 Rust 栈 cutover）

> 2026-11-08 起草。前置：用户已批准合并（MSG193）；唯一门禁 = Omp-Native 在途 10 文件落地 + 门禁
> 通过并发回 `TO_ATOMCODE`。**执行人：总指挥**。任何步骤失败即停，按 §7 回退。

## 1. 前置核对（执行前逐项打勾）

- [ ] Omp-Native 已发 `TO_ATOMCODE`（在途 10 文件收尾）
- [ ] `dev/native-rust` 工作区干净（`git status -s` 为空）
- [ ] `cargo test -p kdc_native` 全过；`hvigorw --no-daemon assembleHap` 成功
- [ ] `git diff main -- entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts` 为空
- [ ] 分支与远端一致（`dev/native-rust` = origin）

## 2. 提交 Omp-Native 交付（在 native worktree）

```bash
cd /home/cagp/WorkSpace2/kdeconnect-harmony-native
git add -A && git commit   # 说明：doc 驱动加固（设备名过滤/证书链/CN 字段/数值兼容/limits）
git push origin dev/native-rust && git push github dev/native-rust
```

## 3. 冻结 C++ 基线（backup/main-cpp）

```bash
cd /home/cagp/WorkSpace2/kdeconnect-harmony
git branch -f backup/main-cpp main          # 当前已指向 a901b8a（pre-merge main）
git push origin backup/main-cpp && git push github backup/main-cpp
```

> 远端此前无该分支，本步首次发布；此后 main 前进，备份分支保持 pre-merge 快照。

## 4. 处理 worktree 局部改动（避免阻塞 merge）

```bash
cd /home/cagp/WorkSpace2/kdeconnect-harmony
git stash push tools/build-both.sh          # 本地临时改动，不提交
# 未跟踪实验文件（CapsuleBarCompare/CapsuleMaterialPrototype/SESSION_HANDOFF）不影响 merge
```

## 5. Cutover（单提交，可回退）

```bash
git checkout main
git merge --squash dev/native-rust
# 预期冲突：entry/src/main/cpp/net/cert_gen.cpp（分支删除/main 曾修改）→ 保留删除：
git rm -q entry/src/main/cpp/net/cert_gen.cpp
git commit   # "feat(native)!: 原生栈全 Rust 化（ohos-rs + rustls），替换 C++/BearSSL"
```

> 说明：squash 使 main 只有一个 cutover 提交（便于 revert）；完整分支历史保留在
> `dev/native-rust` 与 `backup/main-cpp`。

## 6. 版本号与文档同步（同一提交或紧随一提交）

```bash
# AppScope/app.json5：versionCode 7 → 8；versionName "0.8.3" → "0.8.4"
# AGENTS.md：网络栈段由「native C++」改为「0.8.4 起 Rust 为主（C++ 冻结 backup/main-cpp）」
# devdocs/ROADMAP_FUNCTIONAL_20261107.md §7：合并窗口标记完成
# devdocs/CPP_GUIDE.md：标注 C++ 栈仅历史参考
```

## 7. 门禁（合并后必须全绿才 push）

```bash
cd /home/cagp/WorkSpace2/kdeconnect-harmony
export LD_LIBRARY_PATH="$HOME/.local/share/ohos_libshim${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
hvigorw --no-daemon assembleHap
cd entry/src/main/cpp/rust/full && cargo test -p kdc_native && cd -
cd entry/src/main/cpp/tests && ./run.sh          # Rust host 测试
git diff backup/main-cpp -- entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts   # 应为空
```

## 8. 发布与复验

```bash
git push origin main && git push github main
# 观察 CI：reuse（应绿）+ native-tests（应绿）
# 设备：SpatialPad 5555 / SpatialPhone 5559 安装 + 真实 KDE 桌面连接/配对/收文件/发文件
# 由 Omp-Native 执行设备复验，总指挥留证（截图/hilog）
```

## 9. 回退（任一步失败）

```bash
# 首选：revert 单提交（保留历史，main 可继续）
git revert <cutover-commit>
git push origin main && git push github main

# 紧急兜底（破坏性，需用户明示同意才可）：
# git reset --hard backup/main-cpp && git push --force origin main
```

> `--force` 属破坏性操作：默认禁用，必须用户明确同意。

## 10. 合并后清理（不阻塞发布）

- native worktree 保留（`dev/native-rust` 为参考）；Win10/Syncthing 侧拉取新 main；
- `backup/main-cpp` 仅保留，不再开发；
- 桥层阶段 1（kcbridge 契约形态对齐）按 MSG194 启动；
- 0.9.0 孵化入口按 `INCUBATION_ENTRY_PACK_20261108.md` 推进（对外动作待用户确认）。
