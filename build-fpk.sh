#!/bin/bash
# build-fpk.sh — 跨平台精简打包（macOS/Linux 本地与 GitHub Actions 共用一条打包路径）
# 用法：在 fnos-hermes-agent 根目录运行；产出 pkg/fnos-hermes-agent_v<manifest版本>.fpk
# 正式发布产物以 GitHub Actions 构建为准（.github/workflows/Build_fnos-hermes-agent.yml），
# 本脚本本地运行用于开发验证。
#
# 幂等性：
#   - app/hermes-src 缺失时自动从上游 clone（tag 取 hermes-version.env 的 HERMES_TAG）
#   - 前端预构建按 stamp 判定：stamp 与 HERMES_TAG 不一致或产物缺失才重新 npm build
#
# 打包关键步骤（与 build-slim.sh 出厂惯例对齐，v0.21.149 出厂包实测校准）：
#   - rsync 精简副本（排除 hermes-src 的 tests/apps/website/docs/.github/assets/contributors/scripts）
#   - pyproject 版本注入（上游 v0.22.x 起 version 为发布期占位 "0.0.0"，必须改写为实际版本）
#   - 模式归一化（目录 777 / 文件 666，对齐 Windows fnpack 出厂形态）
#   - ICON.PNG 兜底（git 只跟踪小写 icon.png，大小写敏感文件系统上需补大写副本）
#   - manifest checksum 由 fnpack 构建时自动回填
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
VER="$(grep '^version' "$ROOT/manifest" | awk '{print $3}')"
HERMES_VER="$(grep '^HERMES_VERSION=' "$ROOT/config/bootstrap/hermes-version.env" | cut -d= -f2)"
HERMES_TAG="$(grep '^HERMES_TAG=' "$ROOT/config/bootstrap/hermes-version.env" | cut -d= -f2)"
HERMES_TAG="${HERMES_TAG:-v${HERMES_VER}}"
HERMES_SRC_DIR="$ROOT/app/hermes-src"
STAMP_FILE="$HERMES_SRC_DIR/.fnos-webdist-stamp"
DST="$(dirname "$ROOT")/fnos-hermes-agent-slim"

if [ "$(uname)" = "Darwin" ]; then SED_I=(-i ''); else SED_I=(-i); fi

# ── fnpack：优先 $FNPACK / PATH，缺失则按平台下载官方构建 ──
if [ -z "${FNPACK:-}" ] && command -v fnpack >/dev/null 2>&1; then FNPACK="$(command -v fnpack)"; fi
if [ -z "${FNPACK:-}" ]; then
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64)  FNPACK_ARCH=darwin-arm64 ;;
        Darwin/x86_64) FNPACK_ARCH=darwin-amd64 ;;
        Linux/x86_64)  FNPACK_ARCH=linux-amd64 ;;
        Linux/aarch64) FNPACK_ARCH=linux-arm64 ;;
        *) echo "FATAL: 不支持的平台 $(uname -s)/$(uname -m)，请通过 FNPACK 环境变量指定"; exit 1 ;;
    esac
    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fnpack"
    FNPACK="${CACHE_DIR}/fnpack-1.0.4-${FNPACK_ARCH}"
    mkdir -p "$CACHE_DIR"
    [ -x "$FNPACK" ] || {
        echo "下载 fnpack ${FNPACK_ARCH} ..."
        curl -fsSL "https://static2.fnnas.com/fnpack/fnpack-1.0.4-${FNPACK_ARCH}" -o "$FNPACK" && chmod +x "$FNPACK"
    }
fi

echo "===== [0] 源码与前端预构建（hermes ${HERMES_VER} / tag ${HERMES_TAG}） ====="
if [ ! -d "$HERMES_SRC_DIR" ]; then
    echo "app/hermes-src 缺失，clone 上游 ${HERMES_TAG} ..."
    git clone --depth 1 --branch "$HERMES_TAG" https://github.com/NousResearch/hermes-agent.git "$HERMES_SRC_DIR"
fi
if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE" 2>/dev/null || true)" != "$HERMES_TAG" ] \
   || [ ! -f "$HERMES_SRC_DIR/hermes_cli/web_dist/index.html" ] \
   || [ ! -f "$HERMES_SRC_DIR/ui-tui/dist/entry.js" ]; then
    echo "预构建 hermes 前端（web + ui-tui）..."
    ( cd "$HERMES_SRC_DIR" && export LEFTHOOK=0 \
        && npm install --workspace web --no-audit --no-fund \
        && npm install --workspace ui-tui --no-audit --no-fund \
        && npm run build --workspace web \
        && npm run build --workspace ui-tui )
    printf '%s\n' "$HERMES_TAG" > "$STAMP_FILE"
else
    echo "前端产物已是 ${HERMES_TAG}（stamp 命中），跳过预构建"
fi

# 版本严格绑定校验：manifest 必须等于 HERMES_VERSION（该 hermes 版本的首个构建），
# 或 HERMES_VERSION.N（仅包内变更的重建——fnOS 拒绝安装版本号相同的 fpk，故递增构建号）
if [ "$VER" != "$HERMES_VER" ] && ! echo "$VER" | grep -Eq "^${HERMES_VER}\.[0-9]+$"; then
    echo "FATAL: manifest 版本(${VER}) 与 HERMES_VERSION(${HERMES_VER}) 绑定失败——仅允许 ${HERMES_VER} 或 ${HERMES_VER}.N（包内重建构建号）"
    exit 1
fi

echo ""
echo "===== [1] rsync 精简镜像 → ${DST} ====="
# apps/scripts 可安全排除：0.22.5 中仅 venv_sync/source_build（源码重建流程，fnos 走预构建产物不走）
# 与注释引用它们；setup.py 的 editable 构建链（build_editable）不依赖这两个目录。
if [ "$DST" != "$ROOT" ] && [ -d "$DST" ]; then rm -rf "$DST"; fi
rsync -a \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'pkg' \
  --exclude '*.fpk' \
  --exclude '*.bak' \
  --exclude 'SIADA.md' \
  --exclude 'WORK-MEMORY.md' \
  --exclude 'init-pack.tgz' \
  --exclude '_restore021' \
  --exclude '/app/hermes-src/tests' \
  --exclude '/app/hermes-src/apps' \
  --exclude '/app/hermes-src/website' \
  --exclude '/app/hermes-src/docs' \
  --exclude '/app/hermes-src/.github' \
  --exclude '/app/hermes-src/assets' \
  --exclude '/app/hermes-src/contributors' \
  --exclude '/app/hermes-src/scripts' \
  --exclude '/app/hermes-src/.dist-*' \
  --exclude '/app/hermes-src/.fnos-webdist-stamp' \
  "$ROOT"/ "$DST"/

echo ""
echo "===== [1a] 隐私兜底：副本内二次清除个人信息关键词命中文件 ====="
grep -rlE "Ferr0li|紫寒" "$DST" 2>/dev/null | while read -r f; do echo "隐私清除: $f"; rm -f "$f"; done
grep -rlE 'C:\\Users\\veenyi' "$DST" 2>/dev/null | while read -r f; do echo "隐私清除(路径): $f"; rm -f "$f"; done

echo ""
echo "===== [1b] ICON.PNG 兜底 + pyproject 版本注入：0.0.0 占位 → ${HERMES_VER} ====="
# git 只跟踪小写 icon.png 而 manifest 引用 ICON.PNG；大小写不敏感文件系统（darwin/Windows）
# 两者同文件、-e 判断自动跳过，大小写敏感文件系统（Linux CI）补大写副本
if [ ! -e "$DST/ICON.PNG" ]; then cp "$DST/icon.png" "$DST/ICON.PNG"; fi
sed "${SED_I[@]}" "s/^version = \"0.0.0\"/version = \"${HERMES_VER}\"/" "$DST/app/hermes-src/pyproject.toml"

echo ""
echo "===== [1c] 模式归一化（对齐出厂包实测形态：目录 777 / 文件 666，无 exec 位） ====="
# Windows fnpack 对所有条目归一化为 666/777，出厂包（v0.21.149）真机验证即此形态；
# 其他平台 fnpack 原样保留 umask（644/755），会导致运行期 hermes-agent 用户无法在
# hermes-src 内写 __pycache__ 等。按出厂惯例统一。
find "$DST" -type d -exec chmod 777 {} +
find "$DST" -type f -exec chmod 666 {} +

echo ""
echo "===== [1d] 运行必需资源断言 ====="
# 上游 setup.py 说明的运行时资源：locales/skills/optional-mcps/web_dist/tui_dist/plugin manifests + native(FTS5 CJK)
for req in \
  "$DST/ICON.PNG" \
  "$DST/app/ui/scripts/marked.min.js" \
  "$DST/app/hermes-src/hermes_cli/web_dist/index.html" \
  "$DST/app/hermes-src/hermes_cli/web_dist/assets" \
  "$DST/app/hermes-src/ui-tui/dist/entry.js" \
  "$DST/app/hermes-src/native" \
  "$DST/app/hermes-src/skills" \
  "$DST/app/hermes-src/locales" \
  "$DST/app/hermes-src/optional-mcps" ; do
  [ -e "$req" ] || { echo "FATAL: 运行资源缺失 $req"; exit 1; }
done
grep -q "^version = \"${HERMES_VER}\"" "$DST/app/hermes-src/pyproject.toml" || { echo "FATAL: pyproject 版本注入失败"; exit 1; }
echo "runtime resources verified"

echo ""
echo "===== [2] 副本信息 ====="
grep '^version' "$DST/manifest"
du -sh "$DST" "$DST/app/hermes-src"

echo ""
echo "===== [3] fnpack build ====="
cd "$(dirname "$DST")"
"$FNPACK" build --directory "$DST"
[ -f hermes-agent.fpk ] || { echo "FATAL: fnpack 未生成 hermes-agent.fpk"; exit 1; }

echo ""
echo "===== [4] 归档 ====="
mkdir -p "$ROOT/pkg"
mv -f hermes-agent.fpk "$ROOT/pkg/fnos-hermes-agent_v${VER}.fpk"
ls -la "$ROOT/pkg/fnos-hermes-agent_v${VER}.fpk"
echo "归档: pkg/fnos-hermes-agent_v${VER}.fpk"
