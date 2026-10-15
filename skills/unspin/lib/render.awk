# render.awk: draw a flow file (see docs/protocol.md) for a terminal.
#
# Run under LC_ALL=C so every awk (gawk, mawk, busybox, BSD) sees bytes;
# widths are worked out here from the UTF-8 bytes.
#
#   -v mode=block   header + ROWS rows, padded to a fixed height (status line)
#   -v mode=line    a single line (tmux, compact status lines)
#   -v mode=full    header + up to ROWS rows, no padding (watch, show)
#   -v rows=4 -v width=100 -v color=1 -v ascii=0
#   -v now=EPOCH    defaults to the current second
#   -v spin=1       spinner frames per second (match the redraw rate)
#   -v procfs=1 -v myns=NNN   how to tell whether a step's shell is alive

BEGIN {
    if (rows == "") rows = 4
    rows += 0
    if (width == "" || width + 0 < 20) width = 100
    width += 0
    if (mode == "") mode = "block"
    if (color == "") color = 1
    if (spin == "") spin = 1
    if (now == "") { srand(); now = srand() }
    now += 0

    for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i

    if (ascii + 0) {
        G_RUN = ">"; G_OK = "+"; G_FAIL = "x"; G_NOTE = "-"; ELL = "..."
        SPIN = "|/-\\"; NSPIN = 4; UNI = 0; SEP = " - "; DOT = " - "
    } else {
        G_RUN = "▶"; G_OK = "✔"; G_FAIL = "✘"; G_NOTE = "·"; ELL = "…"
        SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"; NSPIN = 10; UNI = 1; SEP = " — "; DOT = " · "
    }

    E = sprintf("%c", 27)
    if (color + 0) {
        C_G = E "[32m"; C_R = E "[31m"; C_Y = E "[33m"; C_D = E "[2m"
        C_B = E "[1m"; C_0 = E "[0m"
    }
    # U+2800 (braille blank) survives the status line trimming blank lines.
    BLANK = (ascii + 0) ? "." : "⠀"

    N = 0; title = ""; TTS = ""; TOT = ""; steps = 0
}

# ---------------------------------------------------------------- parsing

function clean(s) {
    gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "", s)
    gsub(/[\001-\037\177]/, " ", s)
    return s
}

function is_num(s) { return s ~ /^[0-9]+(\.[0-9]+)?$/ }

# Strip "@ts" and the key=value tokens a glyph may carry (each key once).
# Sets M["ts"], M["id"], M["pid"], M["ns"]; returns the text that remains.
function meta(s, keys,   tok, k, v, eq) {
    M["ts"] = ""; M["id"] = ""; M["pid"] = ""; M["ns"] = ""
    if (substr(s, 1, 1) != "@") return s
    tok = s; sub(/ .*/, "", tok)
    if (!is_num(substr(tok, 2))) return s
    M["ts"] = substr(tok, 2)
    if (LAST_TS == "" || M["ts"] + 0 > LAST_TS + 0) LAST_TS = M["ts"]
    s = substr(s, length(tok) + 2)
    while (s != "") {
        tok = s; sub(/ .*/, "", tok)
        eq = index(tok, "=")
        if (eq < 2) break
        k = substr(tok, 1, eq - 1); v = substr(tok, eq + 1)
        if (index(" " keys " ", " " k " ") == 0 || M[k] != "") break
        M[k] = v
        s = substr(s, length(tok) + 2)
    }
    return s
}

function last_running(   j) {
    for (j = N; j >= 1; j--) if (S[j] == "run") return j
    return 0
}

function target(id) {
    if (id != "") return (id in BYID) ? BYID[id] : 0
    return last_running()
}

function new_item(state, text, ts) {
    N++; S[N] = state; TX[N] = text; T0[N] = ts; T1[N] = ""
    PC[N] = ""; PL[N] = ""; DT[N] = ""; PID[N] = ""; NSP[N] = ""
    return N
}

NR == 1 && $0 !~ /^(▶|✔|✘|·|%) / {
    line = clean($0)
    if (substr(line, 1, 1) == "@") {
        tok = line; sub(/ .*/, "", tok)
        if (is_num(substr(tok, 2))) { TTS = substr(tok, 2); line = substr(line, length(tok) + 2) }
    }
    if (match(line, / \[[0-9]+\]$/)) {
        TOT = substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, 1, RSTART - 1)
    }
    title = line
    next
}

/^▶ / {
    rest = meta(clean(substr($0, 5)), "id pid ns")
    i = new_item("run", rest, M["ts"])
    PID[i] = (M["pid"] ~ /^[0-9]+$/) ? M["pid"] : ""
    NSP[i] = M["ns"]
    if (M["id"] != "") BYID[M["id"]] = i
    steps++
    next
}

/^(✔|✘) / {
    st = (substr($0, 1, 3) == "✔") ? "ok" : "fail"
    rest = meta(clean(substr($0, 5)), "id")
    i = target(M["id"])
    if (i && S[i] == "run") {
        S[i] = st; T1[i] = M["ts"]; DT[i] = rest
    } else if (!i) {
        new_item(st, rest, M["ts"]); steps++
    }
    next
}

/^% / {
    rest = meta(clean(substr($0, 3)), "id")
    i = target(M["id"])
    if (!i || S[i] != "run") next
    cnt = rest; sub(/ .*/, "", cnt)
    lab = (length(rest) > length(cnt)) ? substr(rest, length(cnt) + 2) : ""
    PL[i] = lab
    if (cnt == "-" || cnt == "") next
    PC[i] = cnt
    # First and latest numeric reading, for the rate behind the ETA.
    if (frac(cnt)) {
        if (!(i in PN0)) { PN0[i] = FN; PT0[i] = (M["ts"] != "") ? M["ts"] : now }
        PNL[i] = FN
    }
    next
}

/^· / { new_item("note", meta(clean(substr($0, 4)), ""), M["ts"]); next }

/[^ \t]/ { new_item("note", clean($0), "") }

# ---------------------------------------------------------------- numbers

# Parse a count "N/T", "P%" with optional units ("12s/60s", "1.5G/4G").
# Sets FN (done), FT (total), FU (unit) and returns 1 for a fraction.
function frac(c,   a, b, ua, ub) {
    FU = ""
    if (c ~ /^[0-9]+(\.[0-9]+)?%$/) { FN = substr(c, 1, length(c) - 1) + 0; FT = 100; FU = "%"; return 1 }
    if (index(c, "/") == 0) return 0
    a = substr(c, 1, index(c, "/") - 1); b = substr(c, index(c, "/") + 1)
    if (!match(a, /^[0-9]+(\.[0-9]+)?/)) return 0
    ua = substr(a, RLENGTH + 1); a = substr(a, 1, RLENGTH) + 0
    if (!match(b, /^[0-9]+(\.[0-9]+)?/)) return 0
    ub = substr(b, RLENGTH + 1); b = substr(b, 1, RLENGTH) + 0
    FN = a * mult(ua); FT = b * mult(ub); FU = ub
    return FT > 0
}

function mult(u,   c) {
    c = toupper(substr(u, 1, 1))
    if (u ~ /^[KMGTP]i/) return (c == "K") ? 1024 : (c == "M") ? 1048576 : (c == "G") ? 1073741824 : (c == "T") ? 1099511627776 : 1
    return (c == "K") ? 1e3 : (c == "M") ? 1e6 : (c == "G") ? 1e9 : (c == "T") ? 1e12 : (c == "P") ? 1e15 : 1
}

function dur(d, precise) {
    if (d < 0) d = 0
    if (d < 10 && precise) return sprintf("%.1fs", d)
    if (d < 60) return sprintf("%ds", d)
    if (d < 3600) return sprintf("%dm%02ds", d / 60, d % 60)
    return sprintf("%dh%02dm", d / 3600, (d % 3600) / 60)
}

function has_frac(ts) { return index(ts, ".") > 0 }

# ---------------------------------------------------------------- widths

# Display columns of a UTF-8 string: wide East Asian and emoji count 2,
# combining marks 0, continuation bytes nothing.
function cp_at(s, i, n,   b, c1, c2, c3) {
    b = ORD[substr(s, i, 1)]
    c1 = ORD[substr(s, i + 1, 1)] - 128; c2 = ORD[substr(s, i + 2, 1)] - 128
    if (n == 2) return (b - 192) * 64 + c1
    if (n == 3) return (b - 224) * 4096 + c1 * 64 + c2
    c3 = ORD[substr(s, i + 3, 1)] - 128
    return (b - 240) * 262144 + c1 * 4096 + c2 * 64 + c3
}

function cw(cp) {
    if ((cp >= 768 && cp <= 879) || (cp >= 8203 && cp <= 8207) || (cp >= 8400 && cp <= 8447) || (cp >= 65024 && cp <= 65039)) return 0
    if ((cp >= 4352 && cp <= 4447) || (cp >= 11904 && cp <= 12350) || (cp >= 12353 && cp <= 13311) || \
        (cp >= 13312 && cp <= 19903) || (cp >= 19968 && cp <= 40959) || (cp >= 40960 && cp <= 42191) || \
        (cp >= 44032 && cp <= 55203) || (cp >= 63744 && cp <= 64255) || (cp >= 65072 && cp <= 65103) || \
        (cp >= 65280 && cp <= 65376) || (cp >= 65504 && cp <= 65510) || (cp >= 127744 && cp <= 128591) || \
        (cp >= 128640 && cp <= 128767) || (cp >= 129280 && cp <= 129535) || (cp >= 131072 && cp <= 262141)) return 2
    if (cp == 9989 || cp == 10060 || cp == 10024 || cp == 9889 || cp == 11088 || cp == 9203 || cp == 8987 || \
        cp == 10067 || cp == 10071 || cp == 10133 || cp == 10134 || cp == 10135 || cp == 11093) return 2
    return 1
}

# Width of s; with max > 0, also sets CUT to the longest byte prefix that
# fits in max columns.
function dw(s, max,   i, n, b, k, w, c) {
    w = 0; n = length(s); CUT = n
    for (i = 1; i <= n; i += k) {
        b = ORD[substr(s, i, 1)]
        if (b == 27 && match(substr(s, i), /^\033\[[0-9;]*[A-Za-z]/)) { k = RLENGTH; c = 0 }
        else if (b < 128) { k = 1; c = 1 }
        else if (b < 192) { k = 1; c = 0 }
        else {
            k = (b >= 240) ? 4 : (b >= 224) ? 3 : 2
            c = cw(cp_at(s, i, k))
        }
        if (max > 0 && w + c > max) { CUT = i - 1; return w }
        w += c
    }
    return w
}

# ---------------------------------------------------------------- drawing

# Ten cells: a heavy line for the part done and a light one for the rest,
# meeting in a half cell. [###.......] in ASCII.
function bar(n, t,   cells, f, h, out, rest, i) {
    cells = 10
    f = (t > 0) ? n / t : 0
    if (f < 0) f = 0
    if (f > 1) f = 1
    if (!UNI) {
        h = int(f * cells + 0.5); out = ""
        for (i = 0; i < cells; i++) out = out ((i < h) ? "#" : ".")
        return C_D "[" C_0 C_Y out C_0 C_D "]" C_0
    }
    h = int(f * cells * 2); out = ""; rest = ""
    for (i = 0; i < int(h / 2); i++) out = out "━"
    if (h % 2) out = out "╾"
    for (i = int((h + 1) / 2); i < cells; i++) rest = rest "─"
    return (out != "" ? C_Y out C_0 : "") (rest != "" ? C_D rest C_0 : "")
}

# Segments: SEGN[k] text, SEGC[k] colour, SEGA[k] set when it must not be
# cut in half (the bar). fit() joins them within w columns and cuts the
# first one that overflows; with cap > 0 the first segment gets at most cap
# columns, so a long title or step name cannot push everything else out.
function seg_reset() { SEGK = 0 }
function seg(text, col, atomic) {
    if (text == "") return
    SEGK++; SEGN[SEGK] = text; SEGC[SEGK] = col; SEGA[SEGK] = atomic
}
function fit(w, cap,   k, out, used, d, ellw, room) {
    out = ""; used = 0; ellw = dw(ELL, 0)
    for (k = 1; k <= SEGK; k++) {
        d = dw(SEGN[k], 0)
        room = w - used
        if (k == 1 && cap > 0 && cap < room && SEGK > 1) room = cap
        if (d <= room) { out = out SEGC[k] SEGN[k] (SEGC[k] != "" ? C_0 : ""); used += d; continue }
        if (room > ellw && !SEGA[k]) {
            dw(SEGN[k], room - ellw)
            out = out SEGC[k] substr(SEGN[k], 1, CUT) ELL (SEGC[k] != "" ? C_0 : "")
            used += dw(substr(SEGN[k], 1, CUT), 0) + ellw
            if (k == 1 && room < w) continue
        }
        break
    }
    return out
}

function spinner(   k) {
    k = int(now * spin) % NSPIN
    return UNI ? substr(SPIN, k * 3 + 1, 3) : substr(SPIN, k + 1, 1)
}

function alive(i,   f, x) {
    if (PID[i] == "") return 1
    if (NSP[i] != "" && myns != "" && NSP[i] != myns) return 1
    if (procfs + 0) {
        f = "/proc/" PID[i] "/stat"
        if ((getline x < f) > 0) { close(f); sub(/.*\) /, "", x); return substr(x, 1, 1) != "Z" }
        close(f)
        return 0
    }
    return system("kill -0 " PID[i] " 2>/dev/null") == 0
}

# The text of item i as segments, without the glyph.
function item_segs(i,   d, el, eta, cnt, rate) {
    seg(TX[i], (S[i] == "run") ? C_Y : "")
    if (S[i] == "run") {
        el = (T0[i] != "") ? now - T0[i] : -1
        cnt = PC[i]
        if (cnt != "" && frac(cnt)) {
            if (FU != "s" && el >= 1) seg(" " dur(el, 0), C_D)
            seg("  " bar(FN, FT) " ", "", 1)
            seg(cnt, "")
            if (FU != "s" && FU != "%" && FN < FT && (i in PT0) && now - PT0[i] >= 2 && PNL[i] > PN0[i]) {
                rate = (PNL[i] - PN0[i]) / (now - PT0[i])
                eta = (FT - FN) / rate
                if (eta >= 1) seg(DOT "eta " dur(eta, 0), C_D)
            }
        } else {
            if (el >= 1) seg(" " dur(el, 0), C_D)
            if (cnt != "") seg(DOT cnt, "")
        }
        if (PL[i] != "") seg(DOT PL[i], C_D)
        return
    }
    if (S[i] == "note") return
    cnt = PC[i]
    if (cnt != "" && frac(cnt) && FU == "s") cnt = ""
    if (cnt != "") seg(" " cnt, "")
    if (S[i] == "stale") { seg(SEP "interrupted", C_R); return }
    d = DT[i]
    if (d ~ /^[0-9.]+m?[0-9.]*s$/ && T0[i] == "") { seg(" " d, C_D); return }   # v1: duration only
    if (d != "") seg(SEP d, "")
    if (T0[i] != "" && T1[i] != "") seg(" " dur(T1[i] - T0[i], has_frac(T0[i]) && has_frac(T1[i])), C_D)
}

function glyph(i) {
    if (S[i] == "run") return C_Y spinner() C_0
    if (S[i] == "ok") return C_G G_OK C_0
    if (S[i] == "fail" || S[i] == "stale") return C_R G_FAIL C_0
    return C_D G_NOTE C_0
}

END {
    if (NR == 0) exit

    running = 0; failed = 0; stale = 0; last_t = (LAST_TS != "") ? LAST_TS : TTS
    for (i = 1; i <= N; i++) {
        if (S[i] == "run" && !alive(i)) { S[i] = "stale"; stale++ }
        if (S[i] == "run") running++
        if (S[i] == "fail") failed++
        if (T0[i] != "" && (last_t == "" || T0[i] + 0 > last_t + 0)) last_t = T0[i]
        if (T1[i] != "" && (last_t == "" || T1[i] + 0 > last_t + 0)) last_t = T1[i]
        if (first_t == "" && T0[i] != "") first_t = T0[i]
    }
    start_t = (TTS != "") ? TTS : first_t
    if (title == "") title = "flow"

    # Header.
    seg_reset()
    if (running) {
        hg = C_Y G_RUN C_0
        meta_s = "step " steps (TOT != "" ? "/" TOT : "")
        if (running > 1) meta_s = meta_s DOT running " running"
        if (start_t != "") meta_s = meta_s DOT dur(now - start_t, 0)
    } else {
        hg = (failed + stale) ? C_R G_FAIL C_0 : C_G G_OK C_0
        meta_s = steps " step" (steps == 1 ? "" : "s")
        if (failed) meta_s = meta_s ", " failed " failed"
        if (stale) meta_s = meta_s ", " stale " interrupted"
        if (start_t != "" && last_t != "") meta_s = meta_s DOT dur(last_t - start_t, 0)
    }

    if (mode == "line") {
        seg(title, C_B)
        seg(DOT meta_s, C_D)
        cur = 0
        for (i = N; i >= 1 && !cur; i--) if (S[i] == "run") cur = i
        if (cur) { seg(DOT, C_D); item_segs(cur) }
        print hg " " fit(width - 2, int((width - 2) * 0.3))
        exit
    }

    seg(title, C_B); seg("  " meta_s, C_D)
    print hg " " fit(width - 2, width - 2 - dw("  " meta_s, 0))

    # Rows: running steps first, then failures, then the most recent, shown
    # in their original order.
    want = (rows > 0) ? rows : 0
    taken = 0
    for (pass = 1; pass <= 3 && taken < want; pass++)
        for (i = N; i >= 1 && taken < want; i--) {
            if (i in SEL) continue
            if (pass == 1 && S[i] != "run") continue
            if (pass == 2 && S[i] != "fail" && S[i] != "stale") continue
            SEL[i] = 1; taken++
        }
    for (i = 1; i <= N; i++) {
        if (!(i in SEL)) continue
        seg_reset()
        item_segs(i)
        line = fit(width - 4, (S[i] == "run" && PC[i] != "") ? int((width - 4) * 0.45) : 0)
        if (S[i] == "note") line = C_D line C_0
        print "  " glyph(i) " " line
    }
    if (mode == "block") for (; taken < want; taken++) print BLANK
}
