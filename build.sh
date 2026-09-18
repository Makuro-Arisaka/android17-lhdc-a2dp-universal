#!/usr/bin/env bash
# ============================================================================
# build.sh — 打包 KernelSU / Magisk 模块
# ----------------------------------------------------------------------------
# 用法：
#   ./build.sh                    打包到 ../<id>.zip，并生成 .sha256
#   ./build.sh -o /tmp/xx.zip     指定输出路径
#   ./build.sh --reproducible     可复现构建（时间戳取 git 提交时间，同 commit 同 hash）
#   ./build.sh --allow-dirty      工作区有未提交改动时照样打包
#   ./build.sh --no-check         跳过静态检查（不推荐）
#   ./build.sh -h                 帮助
#
# 为什么要有这个脚本（手工 `zip -r ../x.zip .` 的三个坑）：
#   1) 会把 .git / .gitignore 一起打进去 —— 体积翻倍，还可能泄露历史
#   2) 会把从设备拉回来的取证文件（ap.txt / dumpsys.txt …）一起打进去
#   3) 忘了 chmod —— zip 里脚本是 0644，装到设备上 post-fs-data.sh 没有 +x，
#      init exec 失败 → 现象是「模块装了却毫无反应」（本项目真踩过）
#
# 本脚本的做法：
#   文件清单来自 `git ls-files`（= 只有该进包的东西），排除构建脚本自身与 CI 配置；
#   打包前对**将要进包的那批文件**做静态检查；打包后校验 zip 里 module.prop
#   在根目录（多嵌一层目录会导致装不上）。
# ============================================================================
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

# ---------------------------------------------------------------- 参数解析
OUT=""
ALLOW_DIRTY=0
REPRO=0
NOCHECK=0

usage() {
    sed -n '2,20p' "$ROOT/build.sh" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)      OUT=${2:?--output 需要一个路径}; shift 2 ;;
        --allow-dirty|-f) ALLOW_DIRTY=1; shift ;;
        --reproducible)   REPRO=1; shift ;;
        --no-check)       NOCHECK=1; shift ;;
        -h|--help)        usage ;;
        *) echo "未知参数：$1（用 -h 看帮助）" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 输出工具
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=; C_GRN=; C_YEL=; C_DIM=; C_OFF=
fi
step() { printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_OFF"; }
ok()   { printf '  %s[OK]%s %s\n'   "$C_GRN" "$C_OFF" "$1"; }
note() { printf '  %s[--]%s %s\n'   "$C_DIM" "$C_OFF" "$1"; }
warn() { printf '  %s[!!]%s %s\n'   "$C_YEL" "$C_OFF" "$1"; }
die()  { printf '  %s[XX]%s %s\n'   "$C_RED" "$C_OFF" "$1" >&2; exit 1; }

for c in zip unzip sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"
done

# ---------------------------------------------------------------- 读 module.prop
prop() { grep -m1 "^$1=" module.prop 2>/dev/null | cut -d= -f2- || true; }

[ -f module.prop ] || die "找不到 module.prop（请在模块根目录运行）"

ID=$(prop id)
NAME=$(prop name)
VERSION=$(prop version)
VC=$(prop versionCode)
AUTHOR=$(prop author)

[ -n "$ID" ]      || die "module.prop 缺字段：id"
[ -n "$VERSION" ] || die "module.prop 缺字段：version"
[ -n "$VC" ]      || die "module.prop 缺字段：versionCode"
[ -n "$NAME" ]    || warn "module.prop 缺字段：name"
[ -n "$AUTHOR" ]  || warn "module.prop 缺字段：author"

case "$ID" in
    [a-zA-Z]*[!a-zA-Z0-9._-]*) die "id 只能包含字母数字和 . _ -：$ID" ;;
    [!a-zA-Z]*)                die "id 必须以字母开头：$ID" ;;
esac
case "$VC" in
    ''|*[!0-9]*) die "versionCode 必须是纯数字：$VC" ;;
esac

OUT=${OUT:-"$ROOT/../${ID}.zip"}
OUT_DIR=$(cd -- "$(dirname -- "$OUT")" && pwd)/$(basename -- "$OUT")

printf '%s\n' "模块  : $NAME"
printf '%s\n' "标识  : $ID"
printf '%s\n' "版本  : $VERSION (versionCode $VC)"
printf '%s\n' "输出  : $OUT_DIR"

BASE=$(basename -- "$ROOT")
[ "$BASE" = "$ID" ] || warn "目录名 '$BASE' 与模块 id '$ID' 不一致（不影响安装，但容易混淆）"

# ---------------------------------------------------------------- 取文件清单
# 仓库用 git ls-files（只含该进包的东西）；不在 git 仓库里时退回 find + 黑名单。
GV=""
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GV=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo "?")
fi

# 永不进包的东西（构建脚本自身、git 元数据、CI 配置、运行态、本地取证文件、编辑器杂物）
is_excluded() {
    case "$1" in
        build.sh|.gitignore|.gitattributes) return 0 ;;
        .git/*|.git)                        return 0 ;;
        # 英文文档：面向 GitHub 上的读者，设备侧没人会去读，进包只会平白增大体积、
        # 并让包 sha256 与已发布的 Release 附件对不上（README.md 是进包的，它一改
        # 包的哈希就变；多语言版本不该再叠加这个影响）。
        README.en.md)                       return 0 ;;
        # CI 配置：Release 由 GitHub Actions 构建，workflow 本身是仓库工程文件，
        # 与「装到设备上的模块」无关。它必须被排除，否则 Actions 打出的包会比
        # 本地包多出 .github/ 一个条目 → sha256 对不上，可复现验证直接失效。
        .github/*|.github)                  return 0 ;;
        state/*|*/state/*)                  return 0 ;;
        *.zip|*.sha256|*.log|*.err)         return 0 ;;
        *.bak|*.orig|*.rej|*~|*.swp|*.swo)  return 0 ;;
        .DS_Store|Thumbs.db|desktop.ini)    return 0 ;;
        .vscode/*|.idea/*)                  return 0 ;;
        ap.txt|af.txt|bt.txt|dumpsys*.txt|*.dump) return 0 ;;
        run.log|patch.err)                  return 0 ;;
    esac
    return 1
}

step "收集文件"
FILES=()
SRC=""
if [ -n "$GV" ]; then
    SRC="git ls-files"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        is_excluded "$f" && continue
        FILES+=("$f")
    done < <(git -C "$ROOT" ls-files)
else
    SRC="find（非 git 仓库）"
    while IFS= read -r f; do
        f=${f#./}
        [ -n "$f" ] || continue
        is_excluded "$f" && continue
        FILES+=("$f")
    done < <(find . -type f | sed 's|^\./||')
fi
[ ${#FILES[@]} -gt 0 ] || die "没有可打包的文件"

# 固定条目顺序。不排的话，顺序取决于文件系统的 readdir 顺序，
# 本机（ext4）和 CI（overlayfs）读出来的顺序不同 ——
# 结果是包内容一模一样、字节却不同，可复现性失效。
mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | LC_ALL=C sort)

# 补回父目录条目：显式传文件列表时 zip 不会自动建目录条目（`zip -r .` 会），
# 这里把每个文件的各级父目录也算进来，保持与旧包相同的目录结构。
mapfile -t DIRS < <(printf '%s\n' "${FILES[@]}" \
    | awk -F/ 'NF>1 { s=""; for (i=1; i<NF; i++) { s = s (i>1 ? "/" : "") $i; print s } }' \
    | LC_ALL=C sort -u)
FILES=("${DIRS[@]}" "${FILES[@]}")

note "来源：$SRC，共 ${#FILES[@]} 个文件"

# 脏检查：未提交 / 未跟踪的内容会让「构建产物」与「仓库状态」对不上。
if [ -n "$GV" ] && [ "$(git -C "$ROOT" status --porcelain | wc -l)" -gt 0 ]; then
    DIRTY=$(git -C "$ROOT" status --porcelain)
    if [ "$ALLOW_DIRTY" = 1 ]; then
        warn "工作区有未提交改动（你已用 --allow-dirty 放行）："
        printf '%s\n' "$DIRTY" | sed 's/^/       /'
        if printf '%s\n' "$DIRTY" | grep -q '^??'; then
            warn "注意：上面 ?? 开头的**未跟踪文件不会进包**（清单来自 git ls-files）"
            warn "     要让它们进包请先 git add"
        fi
    else
        printf '%s\n' "$DIRTY" | sed 's/^/       /'
        die "工作区不干净，先提交（或加 --allow-dirty 明知故犯地打包）"
    fi
else
    ok "工作区干净"
fi

# ---------------------------------------------------------------- 静态检查
if [ "$NOCHECK" = 0 ]; then
    step "静态检查"

    # --- 必需文件 ---
    REQUIRED=(module.prop lhdc.conf post-fs-data.sh service.sh uninstall.sh customize.sh
              lib/common.sh lib/patch_policy.awk)
    missing=0
    for r in "${REQUIRED[@]}"; do
        if [ -e "$r" ]; then ok "存在 $r"; else warn "缺少 $r"; missing=1; fi
    done
    [ "$missing" = 0 ] || die "必需文件不全，拒绝打包"

    # --- 行尾 / BOM：带 CRLF 的脚本在设备上 exec 会报 not found ---
    crlf=0; bom=0
    for f in "${FILES[@]}"; do
        case "$f" in *.sh|*.awk|*.conf|*.prop|*.md) ;; *) continue ;; esac
        if LC_ALL=C grep -qU $'\r' "$f" 2>/dev/null; then
            warn "含 CRLF：$f"; crlf=1
        fi
        if [ "$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
            warn "含 UTF-8 BOM：$f"; bom=1
        fi
    done
    [ "$crlf" = 0 ] || die "行尾不是 LF。脚本带 \\r 时 shebang 会变成 '#!/system/bin/sh\\r'，init 直接报 not found"
    [ "$bom"  = 0 ] || die "存在 BOM，某些解析器会把 BOM 当成内容"
    ok "行尾全部 LF，无 BOM"

    # --- 脚本语法：优先用 busybox ash（接近设备侧 shell），否则用本机 sh ---
    if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx ash; then
        SHCHK=(busybox ash -n); SHKIND="busybox ash -n"
    else
        SHCHK=(sh -n);          SHKIND="sh -n"
    fi
    for f in "${FILES[@]}"; do
        case "$f" in *.sh) ;; *) continue ;; esac
        if "${SHCHK[@]}" "$f" 2>/dev/null; then
            ok "语法 $f"
        else
            "${SHCHK[@]}" "$f" || true
            die "语法错误：$f（$SHKIND）"
        fi
    done

    # --- awk 语法：喂空输入跑一遍，只看有没有 syntax error ---
    for f in "${FILES[@]}"; do
        case "$f" in *.awk) ;; *) continue ;; esac
        aerr=$( (command -v busybox >/dev/null 2>&1 && busybox awk -f "$f" </dev/null \
                 || awk -f "$f" </dev/null) 2>&1 >/dev/null | grep -i 'syntax' || true)
        [ -z "$aerr" ] || { printf '%s\n' "$aerr" | sed 's/^/       /'; die "语法错误：$f"; }
        ok "语法 $f"
    done

    # --- 可执行位 ---
    # 根目录那 4 个脚本由 init 直接 exec，必须是 755；
    # lib/common.sh 只被 source（不 exec），644 才是对的 —— customize.sh 也是这么设的。
    for f in "${FILES[@]}"; do
        case "$f" in
            lib/*) ;;                       # 库文件跳过，不要求 +x
            *.sh)
                if [ -x "$f" ]; then
                    ok "可执行 $f"
                else
                    warn "$f 在仓库里没有 +x（安装时 customize.sh 会补，但本仓库就该设好）"
                fi
                ;;
        esac
    done
fi

# ---------------------------------------------------------------- 暂存 + 定权限
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/build-${ID}.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

step "暂存"
for f in "${FILES[@]}"; do
    if [ -d "$f" ]; then
        # 目录条目（如 lib）：建出目录即可，条目由 zip 负责记录
        mkdir -p "$STAGE/$f"
        continue
    fi
    mkdir -p "$STAGE/$(dirname -- "$f")"
    cp -p -- "$f" "$STAGE/$f"
done

# 权限与 customize.sh 保持一致：目录 755，根目录脚本 755，数据/文档 644。
# （设备侧 customize.sh 还会再补一次，这里做是为了 zip 本身也正确。）
#
# 这里是**全量显式设置**，不依赖源文件自身的权限位：`cp -p` 会原样保留源权限，
# 而本机仓库和 CI（git checkout）里同一批文件的权限并不一致 ——
# 本地常见 664/775（受 umask 与历史影响），CI 是 644/755。
# 这个差异会被写进 zip 的条目属性，让「同一个 commit 在不同机器上构建」
# 得到不同的 sha256，可复现性直接失效。
#
# 注意 `-maxdepth 1`：只有**根目录**那 4 个脚本由 init 直接 exec，需要 755；
# lib/ 下的 common.sh 只是被 source，644 才是对的。
# （写成 `find ... -name '*.sh'` 会把它一起设成 755，改成通用规则后更容易踩到。）
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
find "$STAGE" -maxdepth 1 -type f -name '*.sh' -exec chmod 755 {} +
ok "已写入 $(du -sh "$STAGE" | cut -f1) 到暂存区（权限已统一：目录 755 / 根脚本 755 / 其余 644）"

if [ "$REPRO" = 1 ]; then
    STAMP=${SOURCE_DATE_EPOCH:-}
    if [ -z "$STAMP" ] && [ -n "$GV" ]; then
        STAMP=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || true)
    fi
    case "$STAMP" in ''|*[!0-9]*) STAMP=315532800 ;; esac   # 兜底 1980-01-01（zip 纪元）
    find "$STAGE" -exec touch -h -d "@$STAMP" {} +
    ok "可复现模式：时间戳统一为 $(date -d "@$STAMP" '+%F %T %Z')"
fi

# ---------------------------------------------------------------- 打包
step "打包"
rm -f "$OUT_DIR"
# 显式传文件列表（而不是 `zip -r ... .`）才能让条目顺序可控 ——
# 传 `.` 是让 zip 自己递归，顺序就落回 readdir 了。
# 目录条目（如 lib/）由 zip 在添加其下第一个文件时自动补上。
( cd "$STAGE" && TZ="${TZ:-UTC}" zip -X -q "$OUT_DIR" "${FILES[@]}" )
[ -s "$OUT_DIR" ] || die "打包失败：$OUT_DIR 不存在或为空"

# --- 打包后自检：这几条错了就是「装了没反应」---
ZL=$(unzip -l "$OUT_DIR")
grep -qE ' [0-9]{2,4}-[0-9]{2}-[0-9]{2} [0-9:]+ +module\.prop$' <<<"$ZL" \
    || { printf '%s\n' "$ZL" | head -20; die "module.prop 不在 zip 根目录（多嵌了一层目录会导致装不上）"; }
grep -q '\.git' <<<"$ZL" && die "zip 里混进了 .git 相关内容"
grep -q 'state/' <<<"$ZL" && die "zip 里混进了 state/（运行时目录）"
ok "结构正确：module.prop 在根目录，无 .git / state/"

# 权限位核对。注意 `zipinfo -l <zip> <单个文件>` 只输出**一行**（无表头），
# 且模式位是第 1 列 —— 别按"整表第 2 行"去取，那样永远取到空值。
if command -v zipinfo >/dev/null 2>&1; then
    badperm=0
    for s in post-fs-data.sh service.sh uninstall.sh customize.sh; do
        m=$(zipinfo -l "$OUT_DIR" "$s" 2>/dev/null | awk 'NR==1{print $1}')
        case "$m" in
            -rwxr-xr-x) ;;
            *) warn "zip 内 $s 权限异常：${m:-读不到}（应为 -rwxr-xr-x）"; badperm=1 ;;
        esac
    done
    for s in module.prop lhdc.conf lib/common.sh; do
        m=$(zipinfo -l "$OUT_DIR" "$s" 2>/dev/null | awk 'NR==1{print $1}')
        case "$m" in
            -rw-r--r--) ;;
            *) warn "zip 内 $s 权限异常：${m:-读不到}（应为 -rw-r--r--）"; badperm=1 ;;
        esac
    done
    [ "$badperm" = 0 ] && ok "zip 内权限位正确（脚本 755 / 数据 644）"
fi

# ---------------------------------------------------------------- 收尾
SHA=$(sha256sum "$OUT_DIR" | cut -d' ' -f1)
printf '%s  %s\n' "$SHA" "$(basename -- "$OUT_DIR")" > "$OUT_DIR.sha256"

step "完成"
printf '  文件   : %s\n' "$OUT_DIR"
printf '  大小   : %s（%s 字节）\n' "$(du -h "$OUT_DIR" | cut -f1)" "$(stat -c %s "$OUT_DIR")"
printf '  条目   : %s 个（含目录）\n' "$(unzip -Z1 "$OUT_DIR" | wc -l)"
printf '  sha256 : %s\n' "$SHA"
[ -n "$GV" ] && printf '  git    : %s\n' "$GV"
if [ "$REPRO" = 1 ]; then
    printf '  %s可复现：相同 commit 重新构建应得到同一个 sha256%s\n' "$C_DIM" "$C_OFF"
fi
cat <<EOF

  装到设备：
    adb push "$OUT_DIR" /data/local/tmp/
    adb shell su -c 'ksud module install /data/local/tmp/$(basename -- "$OUT_DIR")'   # KernelSU
    # Magisk: 在管理器里"从本地安装"，或 adb push 后在 Magisk App 选文件
  重启后生效（KernelSU 先进 modules_update，重启才转正）。

  存档到 /sdcard（本项目的惯例）：
    adb push "$OUT_DIR" /sdcard/
EOF
