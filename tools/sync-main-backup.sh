#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# `backup/main-cpp` —— 保留 C++/BearSSL 原生栈的 main 快照分支。
#
# 背景（用户 2026-11-07 决定）：
#   - `dev/native-rust` 把 native 层改成全 Rust；合入 main 之前，需要一个分支长期保留
#     「最后一份带 C++ 栈的 main」，供其他开源维护者参考/自建分支；
#   - Rust 一旦并入 main，本备份分支即**冻结**在最后一份 C++ main 快照。
#
# 用法：
#   tools/sync-main-backup.sh             # 快进 backup/main-cpp 到 main
#   tools/sync-main-backup.sh --status    # 显示两个分支的差异
#   tools/sync-main-backup.sh --install   # 安装 post-commit/post-merge 钩子（仅 main 触发同步）
#
# 环境变量：MAIN_BRANCH（默认 main）、BACKUP_BRANCH（默认 backup/main-cpp）。
#
# 安全规则：
#   - 只在 `backup/main-cpp` 是 `main` 的祖先时快进（不做 merge/rebase）；
#   - 备份分支被任何 worktree 检出时不移动；
#   - main 已不含 `entry/src/main/cpp/net/net_stack.h`（Rust 已并入）⇒ 冻结，不再跟随。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${MAIN_BRANCH:-main}"
BACKUP="${BACKUP_BRANCH:-backup/main-cpp}"
CPP_MARKER="entry/src/main/cpp/net/net_stack.h"
MARK_BEGIN="# >>> kdeconnect backup/main-cpp sync >>>"
MARK_END="# <<< kdeconnect backup/main-cpp sync <<<"

cd "$ROOT"

git rev-parse --verify "$MAIN" >/dev/null 2>&1 || { echo "[backup] main branch '$MAIN' not found" >&2; exit 1; }
git rev-parse --verify "$BACKUP" >/dev/null 2>&1 || { echo "[backup] backup branch '$BACKUP' not found" >&2; exit 1; }

has_cpp_stack() {
    git cat-file -e "$1:$CPP_MARKER" 2>/dev/null
}

checked_out_anywhere() {
    git worktree list --porcelain 2>/dev/null | grep -qxF "branch refs/heads/$1"
}

sync_once() {
    local main_sha backup_sha
    main_sha="$(git rev-parse "$MAIN")"
    backup_sha="$(git rev-parse "$BACKUP")"

    if [ "$main_sha" = "$backup_sha" ]; then
        echo "[backup] up to date: $BACKUP = $MAIN ($main_sha)"
        return 0
    fi
    if ! has_cpp_stack "$MAIN"; then
        echo "[backup] $MAIN no longer contains the C++ stack ($CPP_MARKER);" >&2
        echo "[backup] $BACKUP frozen at $backup_sha (last C++ main snapshot)." >&2
        return 0
    fi
    if ! git merge-base --is-ancestor "$BACKUP" "$MAIN"; then
        echo "[backup] $BACKUP and $MAIN diverged; refusing to move (manual review required)." >&2
        return 1
    fi
    if checked_out_anywhere "$BACKUP"; then
        echo "[backup] $BACKUP is checked out in a worktree; refusing to move." >&2
        return 1
    fi
    git update-ref "refs/heads/$BACKUP" "$main_sha"
    echo "[backup] fast-forwarded $BACKUP: ${backup_sha:0:7} -> ${main_sha:0:7}"
}

status_once() {
    local main_sha backup_sha
    main_sha="$(git rev-parse "$MAIN")"
    backup_sha="$(git rev-parse "$BACKUP")"
    echo "main            = ${main_sha:0:7}"
    echo "backup/main-cpp = ${backup_sha:0:7}"
    if [ "$main_sha" = "$backup_sha" ]; then
        echo "state: in sync"
    elif ! has_cpp_stack "$MAIN"; then
        echo "state: FROZEN (main no longer has the C++ stack)"
    elif git merge-base --is-ancestor "$BACKUP" "$MAIN"; then
        echo "state: backup is behind main (run without --status to fast-forward)"
    else
        echo "state: DIVERGED (manual review required)"
    fi
}

install_hook() {
    local hook="$1" hookdir path
    hookdir="$(git rev-parse --git-common-dir)/hooks"
    mkdir -p "$hookdir"
    path="$hookdir/$hook"
    if [ ! -f "$path" ]; then
        printf '#!/usr/bin/env bash\n' > "$path"
    fi
    # 钩子必须自包含：main worktree 在本分支合并前没有 tools/sync-main-backup.sh。
    # 因此内联快进逻辑（与 sync_once 等价），不依赖脚本文件存在。
    if grep -qF "$MARK_BEGIN" "$path"; then
        sed -i "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\\.*^$/]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\\.*^$/]/\\&/g')/d" "$path"
    fi
    {
        printf '\n%s\n' "$MARK_BEGIN"
        printf 'if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "%s" ]; then\n' "$MAIN"
        printf '  BACKUP=%s\n' "$BACKUP"
        printf '  if git rev-parse --verify -q "$BACKUP" >/dev/null 2>&1 \\\n'
        printf '     && git cat-file -e "%s:entry/src/main/cpp/net/net_stack.h" 2>/dev/null; then\n' "$MAIN"
        printf '    MAIN_SHA=$(git rev-parse "%s")\n' "$MAIN"
        printf '    BACKUP_SHA=$(git rev-parse "$BACKUP")\n'
        printf '    if [ "$MAIN_SHA" != "$BACKUP_SHA" ] \\\n'
        printf '       && git merge-base --is-ancestor "$BACKUP" "%s" \\\n' "$MAIN"
        printf '       && ! git worktree list --porcelain 2>/dev/null | grep -qxF "branch refs/heads/$BACKUP"; then\n'
        printf '      git update-ref "refs/heads/$BACKUP" "$MAIN_SHA" || true\n'
        printf '    fi\n'
        printf '  fi\n'
        printf 'fi\n'
        printf '%s\n' "$MARK_END"
    } >> "$path"
    chmod +x "$path"
    echo "[backup] installed $hook hook (only on branch '$MAIN')"
}

case "${1:-}" in
    --status) status_once ;;
    --install)
        install_hook post-commit
        install_hook post-merge
        install_hook post-rewrite
        sync_once
        ;;
    "" ) sync_once ;;
    *) echo "usage: $0 [--status|--install]" >&2; exit 2 ;;
esac
