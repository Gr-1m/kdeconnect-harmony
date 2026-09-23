#!/usr/bin/env bash
# 生成/更新 AgentsConversion/GIT_REVISION.md —— 让 Win10 侧（没有 .git）知道
# 「Syncthing 同步过来的这些文件，对应哪个提交」。
#
# 为什么需要：本仓库的 git 状态**只**存在于 Linux 侧（.git 被 .stignore 排除：Syncthing
# 搬不动活着的 git 仓库——index/refs 靠原子重命名与锁，冲突副本无法手工合并），
# 而 Win10/DevEco 只拿到文件、无从判断它们对应哪个提交。
#
# 用法：
#   tools/sync-revision.sh            # 生成一次
#   tools/sync-revision.sh --install  # 安装 git hook（post-commit/post-merge/post-checkout）后生成
#
# 产物 AgentsConversion/GIT_REVISION.md **不是仓库内容**（AgentsConversion/ 已被 .gitignore
# 排除），只随 Syncthing 同步；因此本脚本在任何时刻都是幂等、无副作用的。
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "不在 git 仓库内，跳过" >&2; exit 0; }
cd "$ROOT" || exit 0

if [ "${1:-}" = "--install" ]; then
  for hook in post-commit post-merge post-checkout; do
    cat > ".git/hooks/$hook" <<'HOOK'
#!/usr/bin/env bash
# 由 tools/sync-revision.sh --install 生成：提交/合并/切分支后刷新共享目录的版本标记
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
"$ROOT/tools/sync-revision.sh" >/dev/null 2>&1 || true
HOOK
    chmod +x ".git/hooks/$hook"
  done
  # pre-commit：编码守卫（拒非法 UTF-8/U+FFFD），hook 体由 check-encoding.py 自带
  if [ -x "$ROOT/tools/check-encoding.py" ]; then
    "$ROOT/tools/check-encoding.py" --install-hook >/dev/null 2>&1 ||
      echo "警告：pre-commit 编码守卫安装失败（可手动运行 tools/check-encoding.py --install-hook）" >&2
  fi
  echo "已安装 hook：pre-commit（编码守卫）、post-commit / post-merge / post-checkout（版本标记）"
fi

HASH="$(git rev-parse --short HEAD 2>/dev/null)" || exit 0
[ -n "$HASH" ] || exit 0
FULL="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
SUBJECT="$(git log -1 --pretty=%s)"
WHEN="$(git log -1 --pretty=%cI)"
DIRTY_M="$(git status --porcelain | grep -c '^ M\|^M ' || true)"
DIRTY_U="$(git status --porcelain | grep -c '^??' || true)"
DIRTY_N=$((DIRTY_M + DIRTY_U))
if [ "$DIRTY_N" = "0" ]; then
  WORK="干净"
else
  WORK="**dirty**（已跟踪改动 $DIRTY_M / 新增未跟踪 $DIRTY_U ⇒ 这些改动**不在**本次 commit 里）"
fi
UPSTREAM="origin/$BRANCH"
if git rev-parse --verify -q "$UPSTREAM" >/dev/null 2>&1; then
  AHEAD="$(git rev-list --count "$UPSTREAM..HEAD")"
  BEHIND="$(git rev-list --count "HEAD..$UPSTREAM")"
  SYNC="\`$UPSTREAM\`：本地领先 $AHEAD / 落后 $BEHIND（同步由 Omp 按「提交/推送纪律」执行）"
else
  SYNC="无远端跟踪分支（\`$UPSTREAM\` 不存在）"
fi

mkdir -p AgentsConversion
cat > AgentsConversion/GIT_REVISION.md <<MARKER
# GIT_REVISION — 共享目录当前对应的提交（自动生成，勿手改）

> 由 \`tools/sync-revision.sh\` 在每次提交/合并/切分支后自动刷新（git hook，**只在 Linux 侧执行**）。
> Win10 侧没有 \`.git\`（Syncthing 不同步 git 内部状态：index/refs 靠原子重命名与锁，冲突副本无法手工合并），
> 因此用本文件判断「这些文件对应哪个提交」；差异以此为准，不要编辑本文件。

| 项 | 值 |
|---|---|
| commit | \`$HASH\` (\`$FULL\`) |
| 分支 | \`$BRANCH\` |
| 提交主题 | $SUBJECT |
| 提交时间 | $WHEN |
| 工作区 | $WORK |
| 与远端 | $SYNC |
| 生成时间 | $(date -Iseconds) |
MARKER

echo "已更新 AgentsConversion/GIT_REVISION.md（$HASH, $BRANCH, $WORK）"
