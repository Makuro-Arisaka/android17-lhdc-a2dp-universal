# patch_policy.awk
#
# 把一个 Android audio_policy_configuration.xml 改成「LHDC 可出声」的形态。
#
# 背景
# ----
# 混合架构设备（AOSP 蓝牙栈 + 高通音频 HAL）上，A2DP 只有两条互斥通路：
#   (a) QCOM offload —— PAL 驱动厂商 BT HAL。需要蓝牙栈去开 QTI HIDL session，
#       AOSP 栈永远不会做，于是永远拿不到 encoder config：
#           E PAL: Bluetooth: startPlayback: invalid encoder config
#           E AHAL: onWriteError: write error -22
#       表现是持续静音（并约每 50ms 重试）。
#   (b) AOSP 软件编码 —— APM 打开 audio.bluetooth.default.so 的 a2dp output，
#       蓝牙栈进程内编码。Android 17 内置 LHDCv5 编码器（lhdcv5BT_enc）。
#       只有这条通路能跑 LHDC。
#
# 原厂把 A2DP 端口声明在 primary 下（通路 a），通路 b 不可达。本脚本把 A2DP
# 端口搬到名为 bluetooth 的 module（映射 audio.<moduleName>.default.so），
# 并补上 AUDIO_FORMAT_LHDC。
#
# 三种情形
# --------
#   1) 本文件里已有名为 bluetooth 的 module      → 只补 LHDC / 采样率，不动结构
#   2) 本文件里没有，但某个 xi:include 的文件里有 → 把那个 module 吸收进本文件，
#      删掉该 include（否则运行时会同时存在两个同名 module），再补 A2DP 端口
#   3) 都没有                                    → 新建一个 module
#
# 用法:  awk -f patch_policy.awk < input.xml > output.xml
# 退出码: 0=已打补丁   2=本来就是目标形态   1=失败/找不到 A2DP 端口
#
# 只依赖 POSIX awk（toybox awk / mawk / busybox awk 均可），
# 刻意避开 gensub / match(arr) 等 GNU 扩展。

# ------------------------------------------------------------------ 小工具

function attr(tag, name,    k, a, b) {
    k = index(tag, name "=\"")
    if (k == 0) return ""
    a = k + length(name) + 2
    b = index(substr(tag, a), "\"")
    if (b == 0) return ""
    return substr(tag, a, b - 1)
}

function tagend(s, p,    e) {
    e = index(substr(s, p), ">")
    if (e == 0) return -1
    return p + e - 1
}

# 元素结束位置（end-exclusive）
function elemend(s, p, name,    e, c) {
    e = tagend(s, p)
    if (e < 0) return -1
    if (substr(s, e - 1, 1) == "/") return e + 1
    c = index(substr(s, e + 1), "</" name ">")
    if (c == 0) return -1
    return e + c + length(name) + 3
}

# 向左吃掉该行缩进和它前面的换行，避免删除后留下空行
function leadtrim(s, p,    j, ch) {
    j = p
    while (j > 1) {
        ch = substr(s, j - 1, 1)
        if (ch == " " || ch == "\t") { j--; continue }
        if (ch == "\n") { j-- }
        break
    }
    return j
}

function lstrip(x) { sub(/^[ \t]+/, "", x); return x }

# 取行首空白。注意：传入多行字符串时只看第一行 ——
# 否则 /[^ \t].*$/ 里的 $ 跨不过换行，会一路匹配到最后一行。
function leadws(x,    m, k) {
    m = x
    k = index(m, "\n")
    if (k > 0) m = substr(m, 1, k - 1)
    sub(/[^ \t].*$/, "", m)
    return m
}

function indent_of(s, p,    j, ln) {
    j = p
    while (j > 1 && substr(s, j - 1, 1) != "\n") j--
    ln = substr(s, j, p - j)
    sub(/[^ \t].*$/, "", ln)
    return ln
}

# 把多行文本重新缩进到 pad 深度（保留相对缩进，丢弃空行）
# base = 该文本在原处的行首缩进基准
function nlre(t, pad, base,    n, i, arr, l, rel, out) {
    n = split(t, arr, "\n")
    if (n == 0) return ""
    out = pad lstrip(arr[1])
    for (i = 2; i <= n; i++) {
        l = arr[i]
        if (l ~ /^[ \t]*$/) continue
        rel = leadws(l)
        if (base != "" && index(rel, base) == 1) rel = substr(rel, length(base) + 1)
        out = out "\n" pad rel lstrip(l)
    }
    return out
}

# 整段文本重新缩进（以首行缩进为基准）
function rebody(t, pad,    base) {
    # 只剥掉开头的空行，保留第一行有内容那行自身的缩进（它就是基准）
    sub(/^[ \t]*\n+/, "", t)
    sub(/[ \t\n]+$/, "", t)
    base = leadws(t)
    return nlre(t, pad, base)
}
# ------------------------------------------------------------------ XML 编辑

# 探测这份 XML 里某个「列表型属性」的分隔符风格（"," 或 " "），探测不到返回 ""。
#
# ★ 为什么必须探测，不能写死
#   实测：同一个 AOSP 属性的分隔符风格**随 ROM 而变**——
#     Redmi K20 Pro (Android 17)：samplingRates / channelMasks 用逗号，
#                                  encodedFormats 用空格
#     POCO F5      (Android 16)：全部用空格
#   写死任何一种，换台机器就翻车。而**列表分隔符写错不会报任何错**：
#   解析器只是把该 profile 悄悄降级成 "[dynamic rates]"（采样率表为空），
#   随后 APM 在 openOutputWithProfileAndDevice() 里 "missing param" 返回失败，
#   表现为 "checkOutputsForDevice(): No output available for device 0080" →
#   A2DP 输出永远打不开 → A2DP 设备永远不可用 → 蓝牙彻底无声。
#   现场日志里既没有 XML 语法错误、也没有 seccomp/权限错误，极难定位。
#
#   判据：属性值里出现逗号 → 逗号风格；只出现空格（且无逗号）→ 空格风格。
#   单值属性（无任何分隔符）两种都不计。
function detect_sep(t, prop,    k, a, b, v, nc, ns, rest) {
    nc = 0; ns = 0
    rest = t
    while ((k = index(rest, prop "=\"")) > 0) {
        a = k + length(prop) + 2
        b = index(substr(rest, a), "\"")
        if (b == 0) break
        v = substr(rest, a, b - 1)
        if (index(v, ",") > 0) nc++
        else if (v ~ /[ \t]/) ns++
        rest = substr(rest, a + b - 1)
    }
    if (nc > 0 && ns == 0) return ","
    if (ns > 0 && nc == 0) return " "
    if (nc > ns) return ","
    if (ns > nc) return " "
    return ""
}

# 给 encodedFormats 追加 AUDIO_FORMAT_LHDC（已存在则原样返回）
function addlhdc(t,    k, a, b, v, e, sep) {
    sep = (ESEP != "" ? ESEP : " ")
    k = index(t, "encodedFormats=\"")
    if (k == 0) {
        e = index(t, ">")
        if (e == 0) return t
        if (substr(t, e - 1, 1) == "/") e = e - 1     # 自闭合标签插在 / 之前
        return substr(t, 1, e - 1) \
               " encodedFormats=\"AUDIO_FORMAT_SBC" sep "AUDIO_FORMAT_AAC" sep "AUDIO_FORMAT_LHDC\"" \
               substr(t, e)
    }
    a = k + length("encodedFormats=\"")
    b = index(substr(t, a), "\"")
    if (b == 0) return t
    v = substr(t, a, b - 1)
    if (index(v, "AUDIO_FORMAT_LHDC") > 0) return t
    if (v == "") v = "AUDIO_FORMAT_SBC" sep "AUDIO_FORMAT_AAC"
    return substr(t, 1, a - 1) v sep "AUDIO_FORMAT_LHDC" substr(t, a + b - 1)
}

# 采样率补齐到 AOSP 蓝牙 HAL 的标准集合 44100/48000/88200/96000（只增不减）。
# 原厂 A2DP 端口常只声明 48000（那是给压缩 offload 用的）；改走 AOSP 软件编码后
# 44.1kHz 耳机很常见，96kHz 也在 LHDC V5 能力范围内。
#
# ⚠️ 拼接时用的分隔符必须是 RSEP（从原厂文件探测来的），不能写死空格：
#    在逗号风格的 ROM 上写空格会得到 "44100 48000,88200,96000" 这种混血列表，
#    解析器直接放弃 → profile 变 "[dynamic rates]" → A2DP 静默失效（见 detect_sep 注释）。
function normrate(t,    k, a, b, v, out, rest, sep) {
    sep = (RSEP != "" ? RSEP : ",")
    out = ""
    rest = t
    while ((k = index(rest, "samplingRates=\"")) > 0) {
        a = k + length("samplingRates=\"")
        b = index(substr(rest, a), "\"")
        if (b == 0) break
        v = substr(rest, a, b - 1)
        if (index(v, "44100") == 0) v = "44100" sep v
        if (index(v, "88200") == 0) v = v sep "88200"
        if (index(v, "96000") == 0) v = v sep "96000"
        out = out substr(rest, 1, a - 1) v
        rest = substr(rest, a + b - 1)
    }
    return out rest
}

# 这个 devicePort 是否需要动
function needsfix(t,    k, a, b, v, rest) {
    if (index(t, "AUDIO_FORMAT_LHDC") == 0) return 1
    rest = t
    while ((k = index(rest, "samplingRates=\"")) > 0) {
        a = k + length("samplingRates=\"")
        b = index(substr(rest, a), "\"")
        if (b == 0) break
        v = substr(rest, a, b - 1)
        if (index(v, "44100") == 0 || index(v, "88200") == 0 || index(v, "96000") == 0) return 1
        rest = substr(rest, a + b - 1)
    }
    return 0
}

# 取出字符串 t 中名为 name 的 module 的"内部正文"
function modbody(t, name,    p, i, pp, e, st, se, be) {
    p = 1
    while (1) {
        i = index(substr(t, p), "<module ")
        if (i == 0) return ""
        pp = p + i - 1
        e = elemend(t, pp, "module")
        if (e < 0) return ""
        st = substr(t, pp, tagend(t, pp) - pp + 1)
        if (attr(st, "name") == name) {
            se = tagend(t, pp)
            be = e - length("</module>")
            return substr(t, se + 1, be - se - 1)
        }
        p = e
    }
}

# 把 txt 插到 t 中 closeTag 之前，并接管该标签前那一段纯缩进，使排版干净
function insert_before_close(t, closeTag, txt,    k, j, ch) {
    k = index(t, closeTag)
    if (k == 0) return ""
    j = k - 1
    while (j >= 1) {
        ch = substr(t, j, 1)
        if (ch == " " || ch == "\t") { j--; continue }
        break
    }
    if (j < 1) return ""
    if (substr(t, j, 1) != "\n") return ""
    return substr(t, 1, j) txt "\n" substr(t, j + 1)
}

# 扫描本文件的 xi:include，找出第一个定义了 module name="bluetooth" 的文件。
# 命中时设置全局：bthref / inchtxt / xipos / xiend
function find_bt_include(    pos, i, p, e, st, href, txt, ln) {
    bthref = ""; inchtxt = ""; xipos = 0; xiend = 0
    pos = 1
    while (1) {
        i = index(substr(s, pos), "<xi:include")
        if (i == 0) return 0
        p = pos + i - 1
        e = elemend(s, p, "xi:include")
        if (e < 0) return 0
        st = substr(s, p, tagend(s, p) - p + 1)
        href = attr(st, "href")
        if (href != "" && substr(href, 1, 1) == "/") {
            txt = ""
            while ((getline ln < href) > 0) txt = txt ln "\n"
            close(href)
            if (txt != "" && index(txt, "name=\"bluetooth\"") > 0) {
                bthref = href; inchtxt = txt; xipos = p; xiend = e
                return 1
            }
        }
        pos = e
    }
}

# ------------------------------------------------------------------ 主流程

{ buf = buf $0 "\n" }

END {
    s = buf
    if (length(s) < 100) { print "ERR: input too small" > "/dev/stderr"; exit 1 }

    # ---------- 0. 探测本文件的分隔符风格（决定我们生成的文本该怎么写）----------
    # 采样率：跟随本文件；本文件没有多值采样率时退而参考 channelMasks；
    # 再没有就用 AOSP 规范值逗号。
    RSEP = detect_sep(s, "samplingRates")
    if (RSEP == "") RSEP = detect_sep(s, "channelMasks")
    if (RSEP == "") RSEP = ","
    # encodedFormats：AOSP 规范是空格，而且两台实测设备都是空格；仍以探测为准。
    ESEP = detect_sep(s, "encodedFormats")
    if (ESEP == "") ESEP = " "
    printf "INFO: separator samplingRates=[%s] encodedFormats=[%s]\n", RSEP, ESEP > "/dev/stderr"

    # ---------- 1. module 索引 ----------
    mc = 0; pos = 1
    while (1) {
        i = index(substr(s, pos), "<module ")
        if (i == 0) break
        p = pos + i - 1
        e = elemend(s, p, "module")
        if (e < 0) break
        mc++
        ms[mc] = p; me[mc] = e
        mn[mc] = attr(substr(s, p, tagend(s, p) - p + 1), "name")
        pos = e
    }
    bt = 0
    for (j = 1; j <= mc; j++) if (mn[j] == "bluetooth") bt = j

    # ---------- 2. 收集 A2DP devicePort ----------
    pc = 0; pos = 1
    while (1) {
        i = index(substr(s, pos), "<devicePort ")
        if (i == 0) break
        p = pos + i - 1
        e = elemend(s, p, "devicePort")
        if (e < 0) break
        st = substr(s, p, tagend(s, p) - p + 1)
        if (attr(st, "type") ~ /AUDIO_DEVICE_OUT_BLUETOOTH_A2DP/) {
            pc++
            ps[pc] = p; pe[pc] = e
            pn[pc] = attr(st, "tagName")
            px[pc] = substr(s, p, e - p)
            pm[pc] = ""
            for (j = 1; j <= mc; j++) if (p >= ms[j] && p < me[j]) pm[pc] = mn[j]
        }
        pos = e
    }

    if (pc == 0) { print "ERR: no A2DP devicePort found" > "/dev/stderr"; exit 1 }

    needmove = 0; needlhdc = 0
    for (k = 1; k <= pc; k++) {
        if (pm[k] != "bluetooth") needmove = 1
        if (needsfix(px[k])) needlhdc = 1
    }
    if (!needmove && !needlhdc) { printf "%s", s; exit 2 }

    # ---------- 3a. 情形一：端口已在 bluetooth module 下 → 只补 LHDC/采样率 ----------
    if (!needmove) {
        ne = 0
        for (k = 1; k <= pc; k++) {
            if (needsfix(px[k])) {
                ne++
                es[ne] = ps[k]; ee[ne] = pe[k]; ex[ne] = addlhdc(normrate(px[k]))
            }
        }
        emit(s, ne)
        exit 0
    }

    # ---------- 3b. 需要搬迁 ----------
    # 判断 bluetooth module 是否来自被 include 的文件（情形二）
    bthref = ""; inchtxt = ""; xipos = 0; xiend = 0
    if (bt == 0) find_bt_include()

    if (bthref != "") {
        nm = 0; pos = 1
        while (index(substr(inchtxt, pos), "<module ") > 0) {
            i = index(substr(inchtxt, pos), "<module ")
            e = elemend(inchtxt, pos + i - 1, "module")
            if (e < 0) break
            nm++; pos = e
        }
        if (nm != 1) {
            print "ERR: " bthref " defines " nm " modules; refusing to merge (expected exactly 1)" > "/dev/stderr"
            exit 1
        }
    }

    # 目标缩进：新增 module 对齐本文件已有 <module> 的写法；
    # 并入已有 module 时对齐那个 module 自己的写法。
    mind = indent_of(s, ms[1])
    mi = mind "    "
    if (bt > 0) {
        q = index(substr(s, ms[bt], me[bt] - ms[bt]), "<mixPorts>")
        if (q > 0) mi = indent_of(substr(s, ms[bt], me[bt] - ms[bt]), q)
    }

    # 新的 devicePort 文本（补 LHDC、补齐采样率、重新缩进）
    np = ""
    for (k = 1; k <= pc; k++) {
        if (k > 1) np = np "\n"
        np = np nlre(addlhdc(normrate(px[k])), mi "    ", indent_of(s, ps[k]))
    }

    # 要删掉的端口（不在 bluetooth module 下的）与其 route
    ne = 0
    for (k = 1; k <= pc; k++) {
        if (pm[k] == "bluetooth") continue
        ne++
        es[ne] = leadtrim(s, ps[k]); ee[ne] = pe[k]; ex[ne] = ""
    }
    pos = 1
    while (1) {
        i = index(substr(s, pos), "<route ")
        if (i == 0) break
        p = pos + i - 1
        e = elemend(s, p, "route")
        if (e < 0) break
        sk = attr(substr(s, p, tagend(s, p) - p + 1), "sink")
        for (k = 1; k <= pc; k++) {
            if (sk == pn[k] && pm[k] != "bluetooth") {
                ne++
                es[ne] = leadtrim(s, p); ee[ne] = e; ex[ne] = ""
            }
        }
        pos = e
    }

    nrt = ""
    for (k = 1; k <= pc; k++) {
        if (pm[k] == "bluetooth") continue
        if (nrt != "") nrt = nrt "\n"
        nrt = nrt mi "    <route type=\"mix\" sink=\"" pn[k] "\" sources=\"a2dp output\"/>"
    }

    MIXPORT = mi "    <mixPort name=\"a2dp output\" role=\"source\">\n" \
              mi "        <profile name=\"\" format=\"AUDIO_FORMAT_PCM_16_BIT\"\n" \
              mi "                 samplingRates=\"44100" RSEP "48000" RSEP "88200" RSEP "96000\"\n" \
              mi "                 channelMasks=\"AUDIO_CHANNEL_OUT_STEREO\"/>\n" \
              mi "    </mixPort>"

    if (bt > 0) {
        # ---- 情形一之变体：本文件已有 bluetooth module，把端口并进去 ----
        bs = ms[bt]; be = me[bt]
        bseg = substr(s, bs, be - bs)
        cdp = index(bseg, "</devicePorts>")
        cdr = index(bseg, "</routes>")
        cmp = index(bseg, "</mixPorts>")
        havemix = index(bseg, "name=\"a2dp output\"") > 0

        okd = 0; okr = 0; okm = 0
        if (havemix) okm = 1
        if (cdp > 0) { if (insbefore(bs + cdp - 1, np, mi)) okd = 1 }
        if (cdr > 0) { if (insbefore(bs + cdr - 1, nrt, mi)) okr = 1 }
        if (!havemix) { if (cmp > 0) { if (insbefore(bs + cmp - 1, MIXPORT, mi)) okm = 1 } }

        if (!okd || !okr || !okm) {
            print "WARN: existing bluetooth module structure unexpected; appending missing sections" > "/dev/stderr"
            extra = ""
            if (!okd) extra = extra "\n" mi "<devicePorts>\n" np "\n" mi "</devicePorts>"
            if (!okr) extra = extra "\n" mi "<routes>\n" nrt "\n" mi "</routes>"
            if (!okm) extra = extra "\n" mi "<mixPorts>\n" MIXPORT "\n" mi "</mixPorts>"
            ne++
            es[ne] = be - length("</module>"); ee[ne] = es[ne]; ex[ne] = extra "\n" mind
        }
    } else if (bthref != "") {
        # ---- 情形二：bluetooth module 来自 include → 吸收进本文件后并入 ----
        hb = modbody(inchtxt, "bluetooth")
        if (hb == "") { print "ERR: cannot extract bluetooth module body from " bthref > "/dev/stderr"; exit 1 }
        hb = rebody(hb, mi)

        q = insert_before_close(hb, "</mixPorts>", MIXPORT)
        if (q != "") hb = q
        else hb = hb "\n" mi "<mixPorts>\n" MIXPORT "\n" mi "</mixPorts>"

        q = insert_before_close(hb, "</devicePorts>", np)
        if (q != "") hb = q
        else hb = hb "\n" mi "<devicePorts>\n" np "\n" mi "</devicePorts>"

        q = insert_before_close(hb, "</routes>", nrt)
        if (q != "") hb = q
        else hb = hb "\n" mi "<routes>\n" nrt "\n" mi "</routes>"

        # 删掉那个 xi:include，避免运行时出现两个同名 module
        ne++
        es[ne] = leadtrim(s, xipos); ee[ne] = xiend; ex[ne] = ""

        BLK = mind "<!-- AOSP Bluetooth A2DP HAL (merged from " bthref ") -->\n" \
              mind "<module name=\"bluetooth\" halVersion=\"2.0\">\n" \
              hb "\n" \
              mind "</module>\n\n"
        ne++
        es[ne] = index(s, "</modules>"); ee[ne] = es[ne]; ex[ne] = BLK
    } else {
        # ---- 情形三：新建 module ----
        em = index(s, "</modules>")
        if (em == 0) { print "ERR: </modules> not found" > "/dev/stderr"; exit 1 }
        BLK = mind "<!-- AOSP Bluetooth A2DP HAL (audio.bluetooth.default.so) -->\n" \
              mind "<module name=\"bluetooth\" halVersion=\"2.0\">\n" \
              mi "<mixPorts>\n" \
              MIXPORT "\n" \
              mi "</mixPorts>\n" \
              mi "<devicePorts>\n" \
              np "\n" \
              mi "</devicePorts>\n" \
              mi "<routes>\n" \
              nrt "\n" \
              mi "</routes>\n" \
              mind "</module>\n\n"
        ne++
        es[ne] = em; ee[ne] = em; ex[ne] = BLK
    }

    emit(s, ne)
    exit 0
}

# 把 txt 插到 s 中 closepos（收尾标签 '<' 的位置）之前，接管其前行内缩进
function insbefore(closepos, txt, mi,    j, ch) {
    j = closepos - 1
    while (j >= 1) {
        ch = substr(s, j, 1)
        if (ch == " " || ch == "\t") { j--; continue }
        break
    }
    if (j < 1) return 0
    if (substr(s, j, 1) != "\n") return 0
    ne++
    es[ne] = j + 1
    ee[ne] = closepos
    ex[ne] = txt "\n" mi
    return 1
}

# 按起点排序后一次性重建文本
function emit(s, ne,    k, j, t, cur, out) {
    for (k = 1; k <= ne; k++)
        for (j = k + 1; j <= ne; j++)
            if (es[j] < es[k] || (es[j] == es[k] && ee[j] < ee[k])) {
                t = es[k]; es[k] = es[j]; es[j] = t
                t = ee[k]; ee[k] = ee[j]; ee[j] = t
                t = ex[k]; ex[k] = ex[j]; ex[j] = t
            }
    out = ""; cur = 1
    for (k = 1; k <= ne; k++) {
        if (es[k] > cur) out = out substr(s, cur, es[k] - cur)
        out = out ex[k]
        if (ee[k] > cur) cur = ee[k]
    }
    out = out substr(s, cur)
    printf "%s", out
}
