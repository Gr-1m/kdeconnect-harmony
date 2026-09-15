#!/usr/bin/env python3
"""提交前编码守卫：拒绝把「非法 UTF-8」或「乱码替换字符 U+FFFD」带进历史。

为什么需要（2026-09-15 事故，用户报）：Win10 侧编辑器用非 UTF-8 编码重存了
`entry/src/main/ets/pages/Index.ets`：437 个中文被替换成 U+FFFD 替换字符、连字符串收尾引号
都被吞掉（`'端口探测中'` 变成「端口探测 + 替换字符 + 无收尾引号」），把 ArkTS 编译直接打断。
**构建门禁拦不住这类问题**：乱码落在注释里时 `hvigorw assembleHap` 照样通过，
等它变成编译错误就已经进了同步链路。

（本文件自身**不得**出现真实的替换字符字面量，否则会被自己拦下——示例一律用文字描述。）

用法：
  tools/check-encoding.py                # 检查**已 staged** 的文件（pre-commit hook 用）
  tools/check-encoding.py --all          # 检查工作区所有已跟踪的文本文件
  tools/check-encoding.py <path>...      # 检查指定文件/目录
  tools/check-encoding.py --install-hook # 安装 .git/hooks/pre-commit（幂等）

退出码：0 = 干净；1 = 发现问题（提交会被拒绝）。确属有意（如测试数据本身含 U+FFFD）时
用 `git commit --no-verify` 绕过。
"""

from __future__ import annotations

import os
import subprocess
import sys

REPO_HOOK = "pre-commit"
TEXT_SUFFIXES = {
    ".ets", ".ts", ".js", ".json", ".json5", ".md", ".txt", ".sh", ".bash",
    ".cpp", ".cc", ".h", ".hpp", ".c", ".rs", ".py", ".cmake", ".toml",
    ".yml", ".yaml", ".xml", ".ini", ".cfg", ".properties", ".gitignore",
    ".stignore", ".gitattributes",
}
TEXT_NAMES = {"CMakeLists.txt", "Kconfig", "Makefile"}
MAX_BYTES = 8 * 1024 * 1024
MAX_LINES_PER_FILE = 5


def is_text_candidate(path: str) -> bool:
    base = os.path.basename(path)
    if base in TEXT_NAMES:
        return True
    if base.startswith(".") and base.count(".") == 1:
        return True   # 点文件（.gitignore/.stignore/.gitattributes …）：splitext 对它们返回空后缀
    return os.path.splitext(base)[1].lower() in TEXT_SUFFIXES


def run_git(*args: str) -> str:
    try:
        out = subprocess.run(
            ["git", *args], capture_output=True, text=True, check=False
        )
    except OSError:
        return ""
    return out.stdout


def staged_files() -> list[str]:
    names = run_git("diff", "--cached", "--name-only", "--diff-filter=ACM").splitlines()
    return [n for n in names if n.strip()]


def tracked_files() -> list[str]:
    return [n for n in run_git("ls-files").splitlines() if n.strip()]


def collect(paths: list[str]) -> list[str]:
    out: list[str] = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                if f"{os.sep}.git" in root:
                    continue
                out.extend(os.path.join(root, f) for f in files)
        else:
            out.append(p)
    return out


def check_file(path: str) -> tuple[list[str], bool]:
    """返回 (问题行描述, 是否严格非法 UTF-8)。文件不可读或二进制则视为无问题。"""
    if not is_text_candidate(path) or not os.path.isfile(path):
        return [], False
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return [], False
    if size > MAX_BYTES or b"\x00" in data:
        return [], False

    strict_ok = True
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        strict_ok = False
        text = data.decode("utf-8", "replace")

    problems: list[str] = []
    shown = 0
    total = 0
    for no, line in enumerate(text.splitlines(), start=1):
        if "\ufffd" not in line:
            continue
        total += 1
        if shown < MAX_LINES_PER_FILE:
            shown += 1
            problems.append(f"    L{no}: {line.strip()[:100]}")
    if total > shown:
        problems.append(f"    … 另有 {total - shown} 行（共 {total} 行受影响）")
    return problems, (not strict_ok)


def install_hook() -> int:
    root = run_git("rev-parse", "--show-toplevel").strip()
    if not root:
        print("不在 git 仓库内，无法安装 hook", file=sys.stderr)
        return 1
    hooks_dir = os.path.join(root, ".git", "hooks")
    os.makedirs(hooks_dir, exist_ok=True)
    hook_path = os.path.join(hooks_dir, REPO_HOOK)
    body = (
        "#!/usr/bin/env bash\n"
        "# 由 tools/check-encoding.py --install-hook 生成：拒绝把非法 UTF-8/乱码带进历史\n"
        'ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0\n'
        'CHECK="$ROOT/tools/check-encoding.py"\n'
        '# 脚本不在（例如尚未提交、被清理）时放行并告警：守卫不能变成拦死一切提交的绞索\n'
        '[ -f "$CHECK" ] || { echo "警告：找不到 $CHECK，编码守卫跳过" >&2; exit 0; }\n'
        'exec python3 "$CHECK"\n'
    )
    with open(hook_path, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(hook_path, 0o755)
    print(f"已安装 hook: .git/hooks/{REPO_HOOK}")
    return 0


def main(argv: list[str]) -> int:
    if "--install-hook" in argv:
        return install_hook()

    if "--all" in argv:
        files = [f for f in tracked_files() if is_text_candidate(f)]
        scope = "工作区所有已跟踪文本文件"
    elif len(argv) > 0:
        files = [f for f in collect(argv) if is_text_candidate(f)]
        scope = f"指定路径（{len(files)} 个文本文件）"
    else:
        files = [f for f in staged_files() if is_text_candidate(f)]
        scope = "已 staged 的文件"

    bad: list[tuple[str, list[str], bool]] = []
    for f in files:
        if not os.path.exists(f):
            continue
        problems, invalid = check_file(f)
        if problems:
            bad.append((f, problems, invalid))

    if not bad:
        print(f"编码检查通过（{scope}，{len(files)} 个文件）")
        return 0

    print(f"编码检查失败：{scope} 中 {len(bad)} 个文件含非法 UTF-8 或乱码字符 U+FFFD")
    print("（这类内容多半是编辑器用非 UTF-8 编码重存造成的，中文会被替换、字符串引号可能被吞掉）")
    for f, problems, invalid in bad:
        print(f"  ✗ {f}{'  [非法 UTF-8]' if invalid else '  [含 U+FFFD]'}")
        for line in problems:
            print(line)
    print("处理：用 UTF-8 重新保存该文件后重试；确属有意请用 `git commit --no-verify`。")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
