# patch_policy.awk
#
# 把一个 Android audio_policy_configuration.xml 改成「LHDC 可出声」的形态。
#
# 将 A2DP devicePort 迁移到 bluetooth module，补全 AUDIO_FORMAT_LHDC、
# 采样率、a2dp output mixPort 和 route。已有 bluetooth module 时直接修改；
# module 位于 xi:include 文件中时先合并，再删除原 include。
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

# 在缺少有效根元素 version 时，从现有属性值推测列表分隔符。
# 这里不解析 XML 注释，因此只作为 sep_by_version() 的回退。
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

# 只在 audioPolicyConfiguration 根标签内读取 version，避免使用子节点或注释中的
# 同名属性。APM 根据此版本选择列表分隔符。
function detect_root_version(t,    k, gt, seg, a, b) {
    k = index(t, "<audioPolicyConfiguration")
    if (k == 0) return ""
    gt = index(substr(t, k), ">")
    if (gt == 0) return ""
    seg = substr(t, k, gt)              # 仅根元素标签本身，不含后续内容
    a = index(seg, "version=\"")
    if (a == 0) return ""
    a = a + length("version=\"")
    b = index(substr(seg, a), "\"")
    if (b == 0) return ""
    return substr(seg, a, b - 1)
}

# version → samplingRates / channelMasks 的分隔符。
# 对应 AOSP Serializer.cpp 的 mSamplingRatesSeparator / mChannelMasksSeparator 规则。
# 返回 "" = 版本缺失或不是 1.0/7.0/7.1，调用方需回退到内容探测。
function sep_by_version(v) {
    if (v == "7.0" || v == "7.1") return " "
    if (v == "1.0") return ","
    return ""
}

# 向 encodedFormats 添加 LHDC。AOSP 对此属性固定使用空格分隔，
# 与根元素 version 无关。
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

# 保留并去重已有采样率，再补齐 44100/48000/88200/96000，统一使用 RSEP。
# 通过 seen 参数创建局部数组，不依赖非 POSIX 的 delete array。
function normrate(t,    k, a, b, v, out, rest, sep, i, arr, n2, nt, targets, seen, res, tok) {
    sep = (RSEP != "" ? RSEP : ",")
    # 目标集合：AOSP 蓝牙 HAL 的标准采样率（顺序即输出顺序）
    nt = split("44100 48000 88200 96000", targets, " ")
    out = ""
    rest = t
    while ((k = index(rest, "samplingRates=\"")) > 0) {
        a = k + length("samplingRates=\"")
        b = index(substr(rest, a), "\"")
        if (b == 0) break
        v = substr(rest, a, b - 1)

        # 按词元处理可同时覆盖空列表、重复项和混用分隔符的输入。
        res = ""
        n2 = split(v, arr, "[, \t]+")
        for (i = 1; i <= n2; i++) {
            tok = arr[i]
            if (tok == "" || (tok in seen)) continue
            seen[tok] = 1
            res = (res == "" ? tok : res sep tok)
        }
        for (i = 1; i <= nt; i++) {
            tok = targets[i]
            if (tok in seen) continue
            seen[tok] = 1
            # 44100 是最低采样率，AOSP 习惯放首位；其余按标准顺序追加到尾部
            if (i == 1 && res != "") res = tok sep res
            else res = (res == "" ? tok : res sep tok)
        }
        v = res

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

# 检查目标 module 是否已有指定属性值，避免生成重复端口或路由。
function has_attr_val(seg, attrname, val) {
    if (seg == "" || val == "") return 0
    return index(seg, attrname "=\"" val "\"") > 0
}

# 仅 A2DP 类型需要修改；助听器等端口继续使用各自的格式和采样率。
function is_a2dp_port(t) {
    return index(t, "AUDIO_DEVICE_OUT_BLUETOOTH_A2DP") > 0
}

# 修补目标 module 内已经存在、但格式或采样率不完整的 A2DP 端口。
function fix_ports_in(seg,    out, pos, i, p, e, pe) {
    out = ""
    pos = 1
    while ((i = index(substr(seg, pos), "<devicePort ")) > 0) {
        p = pos + i - 1
        e = elemend(seg, p, "devicePort")
        if (e < 0) break
        pe = substr(seg, p, e - p)
        out = out substr(seg, pos, p - pos)
        if (is_a2dp_port(pe) && needsfix(pe)) out = out addlhdc(normrate(pe))
        else out = out pe
        pos = e
    }
    return out substr(seg, pos)
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

    # 0. 根据根元素 version 确定输出列表格式。
    RV = detect_root_version(s)
    RSEP = sep_by_version(RV)
    RSRC = "version=" RV
    if (RSEP == "") {
        # 版本缺失或非 1.0/7.0/7.1（后者本来就会被 APM 拒绝加载）→ 退回内容探测
        RSEP = detect_sep(s, "samplingRates")
        if (RSEP == "") RSEP = detect_sep(s, "channelMasks")
        if (RSEP == "") RSEP = ","
        RSRC = "探测(version 不可用)"
    }
    # encodedFormats 固定使用空格。
    ESEP = " "
    printf "INFO: separator samplingRates=[%s] (%s) encodedFormats=[%s] (AOSP 固定)\n", \
           RSEP, RSRC, ESEP > "/dev/stderr"

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

    # 完整策略必须同时具有 A2DP 端口、LHDC、a2dp output 和对应 route。
    # 先定位现有或 include 中的目标 module，再判断是否需要修改。
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

    # 目标 module 现有的正文 —— 用来判断「它是不是已经有这个端口 / route / mixPort」。
    #   bt > 0      ：目标就是本文件里那个 bluetooth module
    #   bthref != ""：目标来自被 include 的文件
    #   两者都没有  ：目标将由我们新建，现有内容视作空
    tgtbody = ""
    if (bt > 0) tgtbody = substr(s, ms[bt], me[bt] - ms[bt])
    else if (bthref != "") tgtbody = modbody(inchtxt, "bluetooth")

    needout = 0
    if (tgtbody == "") {
        needout = 1                                  # 目标都不存在，出口自然缺
    } else {
        if (index(tgtbody, "name=\"a2dp output\"") == 0) needout = 1
        # 已在目标 module 里的端口，若没有 route 指向 a2dp output 也算缺
        for (k = 1; k <= pc; k++)
            if (pm[k] == "bluetooth" && !has_attr_val(tgtbody, "sink", pn[k])) needout = 1
        # 目标 module 里已有端口但没有 a2dp output 时上面已置 1；
        # 另有「端口在 primary、要搬进来」的情形由 needmove 覆盖。
    }

    if (!needmove && !needlhdc && !needout) { printf "%s", s; exit 2 }

    # ---------- 3a. 情形一：端口已在 bluetooth module 下，且出口齐备
    #            → 只需就地补 LHDC / 采样率 ----------
    # 注意 needout 为真时**不能**走这条捷径：那条路只补 devicePort，
    # 不会补 a2dp output mixPort 与 route。
    if (!needmove && !needout) {
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

    # ---------- 3b. 需要搬迁 / 或需补出口 ----------

    # 目标缩进：新增 module 对齐本文件已有 <module> 的写法；
    # 并入已有 module 时对齐那个 module 自己的写法。
    mind = indent_of(s, ms[1])
    mi = mind "    "
    if (bt > 0) {
        q = index(substr(s, ms[bt], me[bt] - ms[bt]), "<mixPorts>")
        if (q > 0) mi = indent_of(substr(s, ms[bt], me[bt] - ms[bt]), q)
    } else if (tgtbody != "") {
        q = index(tgtbody, "<mixPorts>")
        if (q > 0) mi = indent_of(tgtbody, q)
    }

    # 只添加目标 module 尚不存在的端口；已有端口单独就地修补。
    np = ""
    for (k = 1; k <= pc; k++) {
        if (pm[k] == "bluetooth") continue
        if (has_attr_val(tgtbody, "tagName", pn[k])) continue
        if (np != "") np = np "\n"
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

    # 为所有缺失路由的 A2DP 端口补充到 a2dp output 的连接。
    nrt = ""
    for (k = 1; k <= pc; k++) {
        if (has_attr_val(tgtbody, "sink", pn[k])) continue
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

        # 修补 bluetooth module 内已有的 A2DP 端口。
        for (k = 1; k <= pc; k++) {
            if (pm[k] != "bluetooth") continue
            if (!needsfix(px[k])) continue
            ne++
            es[ne] = ps[k]; ee[ne] = pe[k]; ex[ne] = addlhdc(normrate(px[k]))
        }

        okd = 0; okr = 0; okm = 0
        if (havemix) okm = 1
        # 没有待插入内容时保持原有段落不变。
        if (np != "" && cdp > 0) { if (insbefore(bs + cdp - 1, np, mi)) okd = 1 } else if (np == "") okd = 1
        if (nrt != "" && cdr > 0) { if (insbefore(bs + cdr - 1, nrt, mi)) okr = 1 } else if (nrt == "") okr = 1
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

        # include 文件内已有的 A2DP 端口也需要检查格式和采样率。
        hb = fix_ports_in(hb)

        # 已有 a2dp output 时不重复创建。
        if (index(hb, "name=\"a2dp output\"") == 0) {
            q = insert_before_close(hb, "</mixPorts>", MIXPORT)
            if (q != "") hb = q
            else hb = hb "\n" mi "<mixPorts>\n" MIXPORT "\n" mi "</mixPorts>"
        }

        # np / nrt 为空表示「要搬的端口在目标模块里都已存在」（去重后无剩余），
        # 此时不该插入空段落。
        if (np != "") {
            q = insert_before_close(hb, "</devicePorts>", np)
            if (q != "") hb = q
            else hb = hb "\n" mi "<devicePorts>\n" np "\n" mi "</devicePorts>"
        }

        if (nrt != "") {
            q = insert_before_close(hb, "</routes>", nrt)
            if (q != "") hb = q
            else hb = hb "\n" mi "<routes>\n" nrt "\n" mi "</routes>"
        }

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
