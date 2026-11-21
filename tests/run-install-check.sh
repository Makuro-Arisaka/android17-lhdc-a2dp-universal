#!/usr/bin/env bash
# ============================================================================
# run-install-check.sh — lib/install_check.sh 与 customize.sh 的本地回归测试
# ----------------------------------------------------------------------------
# 本机测试的基础设施（都不依赖真机）：
#   · LHDC_ETC_ROOTS / LHDC_HAL_DIRS 覆盖成临时目录里的假 vendor 树
#   · 在 PATH 前插入 getprop / ui_print / abort 三个 shell 脚本垫片，
#     模拟 root 管理器提供的同名函数
#
# 用法: bash tests/run-install-check.sh
# ============================================================================
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
FIX="$HERE/fixtures"

PASS=0
FAIL=0
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/lhdc-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m[XX]\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

# ---------------------------------------------------------------- 假设备环境
# 搭一个假的 vendor 树：
#   $1 = 场景目录
#   $2 = 策略 XML 来源文件（空串 = 不建策略文件）
#   $3 = 1 建 HAL 文件 / 0 不建
make_env() {
    local d=$1 policy=$2 withhal=$3
    mkdir -p "$d/vendor/etc/audio/sku_test" "$d/vendor/lib64/hw" "$d/bin" "$d/props"
    if [ -n "$policy" ]; then
        cp "$policy" "$d/vendor/etc/audio/sku_test/audio_policy_configuration.xml"
    fi
    [ "$withhal" = 1 ] && : > "$d/vendor/lib64/hw/audio.bluetooth.default.so"

    # getprop 垫片：从 $d/props 里按 key=value 查
    cat > "$d/bin/getprop" <<'SH'
#!/bin/sh
f="${LHDC_TEST_PROPS:?}"
[ -f "$f" ] || exit 0
v=$(grep -m1 "^$1=" "$f" 2>/dev/null | cut -d= -f2-)
[ -n "$v" ] && printf '%s\n' "$v"
exit 0
SH
    # root 管理器提供的 ui_print / abort
    cat > "$d/bin/ui_print" <<'SH'
#!/bin/sh
printf '%s\n' "$*"
SH
    cat > "$d/bin/abort" <<'SH'
#!/bin/sh
printf 'ABORT: %s\n' "$*" >&2
exit 42
SH
    chmod 755 "$d/bin/getprop" "$d/bin/ui_print" "$d/bin/abort"
}

# setprop 一份属性表
set_props() {
    local d=$1 sdk=$2
    cat > "$d/props/p" <<EOF
ro.build.version.sdk=$sdk
ro.product.device=testdev
ro.product.model=Test Device
ro.vendor.build.fingerprint=vendor/testdev/testdev:17/TQ1A/eng:user/release-keys
ro.bluetooth.a2dp_offload.supported=true
persist.bluetooth.a2dp_offload.disabled=false
ro.boot.product.vendor.sku=test
ro.board.platform=testplat
ro.hardware=testplat
ro.soc.model=testplat
EOF
}

# ---------------------------------------------------------------- 单测：检查函数
# 用法: run_check <场景目录> [额外 KEY=VAL ...]；输出检查输出，返回 lc_install_check 的码
run_check() {
    local d=$1; shift
    (
        export MODDIR="$REPO"
        export LHDC_TEST_PROPS="$d/props/p"
        export PATH="$d/bin:$PATH"
        export LHDC_ETC_ROOTS="$d/vendor/etc/audio"
        export LHDC_ETC_TOPDIRS="$d/vendor/etc/audio $d/vendor/etc"
        export LHDC_HAL_DIRS="$d/vendor/lib64/hw"
        export DRY_RUN=1
        for kv in "$@"; do export "$kv"; done
        # shellcheck disable=SC1091
        . "$REPO/lib/common.sh"
        # shellcheck disable=SC1091
        . "$REPO/lib/install_check.sh"
        lc_install_check
    )
}

# ---------------------------------------------------------------- 集成：customize.sh
# 把仓库复制成模块目录（customize.sh 会 chmod 它），然后跑真正的安装脚本
run_customize() {
    local d=$1; shift
    local mod="$d/module"
    mkdir -p "$mod"
    (cd "$REPO" && git ls-files -z | tar --null -T - -cf - 2>/dev/null) | (cd "$mod" && tar xf - 2>/dev/null)
    # 补上新增但尚未提交的文件
    cp "$REPO/lib/install_check.sh" "$mod/lib/" 2>/dev/null
    cp "$REPO/customize.sh" "$mod/" 2>/dev/null
    (
        export MODPATH="$mod"
        export LHDC_TEST_PROPS="$d/props/p"
        export PATH="$d/bin:$PATH"
        export LHDC_ETC_ROOTS="$d/vendor/etc/audio"
        export LHDC_ETC_TOPDIRS="$d/vendor/etc/audio $d/vendor/etc"
        export LHDC_HAL_DIRS="$d/vendor/lib64/hw"
        for kv in "$@"; do export "$kv"; done
        sh "$mod/customize.sh"
    )
}

echo "=== install_check 回归测试 ==="

# ---- 1. 完全符合 ----
D=$TMPROOT/c1; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 37
out=$(run_check "$D"); rc=$?
if [ "$rc" = 0 ] && grep -q '符合适用范围' <<<"$out"; then
    ok "SDK=37 + HAL + 可打补丁 → 通过"
else bad "SDK=37 + HAL + 可打补丁 → 应通过" "rc=$rc"; fi

# ---- 2. SDK 太低 ----
D=$TMPROOT/c2; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 36
out=$(run_check "$D"); rc=$?
if [ "$rc" = 1 ] && grep -q '不符合适用范围' <<<"$out" && grep -q 'SDK=36' <<<"$out"; then
    ok "SDK=36 → 拒绝并指明版本不满足"
else bad "SDK=36 → 应拒绝并指明版本" "rc=$rc"; fi

# ---- 3. 缺 HAL ----
D=$TMPROOT/c3; make_env "$D" "$FIX/policy_stock_7.0.xml" 0; set_props "$D" 37
out=$(run_check "$D"); rc=$?
if [ "$rc" = 1 ] && grep -q 'audio.bluetooth.default.so' <<<"$out"; then
    ok "缺 audio.bluetooth.default.so → 拒绝并点名缺的文件"
else bad "缺 HAL → 应拒绝并点名" "rc=$rc"; fi

# ---- 4. 无候选策略文件 ----
D=$TMPROOT/c4; make_env "$D" "" 1; set_props "$D" 37
out=$(run_check "$D"); rc=$?
if [ "$rc" = 1 ] && grep -q '找不到 audio_policy_configuration.xml\|找不到候选' <<<"$out"; then
    ok "无候选策略文件 → 拒绝"
else bad "无候选策略文件 → 应拒绝" "rc=$rc"; fi

# ---- 5. 策略文件里没有 A2DP 端口（补丁器试运行失败）----
D=$TMPROOT/c5; make_env "$D" "" 1; set_props "$D" 37
cat > "$D/vendor/etc/audio/sku_test/audio_policy_configuration.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<audioPolicyConfiguration version="7.0">
    <modules>
        <module name="primary" halVersion="3.0">
            <devicePorts>
                <devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink"/>
            </devicePorts>
            <routes/>
        </module>
    </modules>
</audioPolicyConfiguration>
XML
out=$(run_check "$D"); rc=$?
if [ "$rc" = 1 ] && grep -q '补丁器' <<<"$out"; then
    ok "无 A2DP 端口 → 补丁器试运行失败，拒绝"
else bad "无 A2DP 端口 → 应拒绝" "rc=$rc"; fi

# ---- 6. version=1.0（逗号风格）+ 已是目标形态 ----
D=$TMPROOT/c6; make_env "$D" "$FIX/policy_stock_1.0.xml" 1; set_props "$D" 37
out=$(run_check "$D"); rc=$?
if [ "$rc" = 0 ] && grep -q 'samplingRates=\[,\]' <<<"$out"; then
    ok "version=1.0 → 判为逗号风格（(version=1.0)）"
else bad "version=1.0 → 应判逗号风格" "rc=$rc"; fi

D=$TMPROOT/c6b; make_env "$D" "$FIX/policy_already_target.xml" 1; set_props "$D" 37
out=$(run_check "$D"); rc=$?
if [ "$rc" = 0 ] && grep -q '已是目标形态' <<<"$out"; then
    ok "已是目标形态（退出码 2）→ 视为通过"
else bad "已是目标形态 → 应视为通过" "rc=$rc"; fi

# ---- 7. FORCE=1 覆盖硬性要求 ----
D=$TMPROOT/c7; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 36
out=$(run_check "$D" FORCE=1); rc=$?
if [ "$rc" = 0 ] && grep -q 'FORCE=1' <<<"$out"; then
    ok "SDK=36 + FORCE=1 → 强制放行并说明"
else bad "FORCE=1 → 应强制放行" "rc=$rc"; fi

# ---- 8. 检查阶段必须只读（不建 state/）----
D=$TMPROOT/c8; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 36
out=$(run_check "$D"); rc=$?
if [ ! -d "$REPO/state" ]; then
    ok "检查失败后未创建 state/（DRY_RUN 生效）"
else bad "检查阶段写盘了" "$REPO/state 被创建"; rm -rf "$REPO/state"; fi

echo
echo "=== customize.sh 端到端 ==="

# ---- 9. 不符合 → abort，rc != 0，且不建 state ----
D=$TMPROOT/c9; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 36
out=$(run_customize "$D" 2>&1); rc=$?
if [ "$rc" != 0 ] && grep -q 'ABORT' <<<"$out" && [ ! -d "$D/module/state" ]; then
    ok "SDK=36 → 安装被 abort（rc=$rc），未创建 state/"
else bad "SDK=36 → 安装应失败且不留 state/" "rc=$rc"; fi

# ---- 10. 符合 → 安装完成 ----
D=$TMPROOT/c10; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 37
out=$(run_customize "$D" 2>&1); rc=$?
if [ "$rc" = 0 ] && grep -q '安装完成' <<<"$out"; then
    ok "SDK=37 → 安装继续并输出完成提示"
else bad "SDK=37 → 应安装成功" "rc=$rc"; fi

# ---- 11. 安装后脚本权限正确 ----
D=$TMPROOT/c11; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 37
out=$(run_customize "$D" 2>&1); rc=$?
if [ -x "$D/module/post-fs-data.sh" ] && [ -x "$D/module/service.sh" ] \
   && [ ! -x "$D/module/lib/common.sh" ]; then
    ok "权限：根脚本 755 / 库文件 644"
else bad "权限不正确" "post-fs-data.sh=$(stat -c %a "$D/module/post-fs-data.sh" 2>/dev/null) common.sh=$(stat -c %a "$D/module/lib/common.sh" 2>/dev/null)"; fi

# ---- 12. 安装期会清掉残留 state ----
D=$TMPROOT/c12; make_env "$D" "$FIX/policy_stock_7.0.xml" 1; set_props "$D" 37
mkdir -p "$D/module/state"; : > "$D/module/state/run.log"
out=$(run_customize "$D" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ ! -d "$D/module/state" ]; then
    ok "安装成功时清掉残留 state/"
else bad "应清掉残留 state/" "rc=$rc"; fi

echo
printf '结果: %d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
