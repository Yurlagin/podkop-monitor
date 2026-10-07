# Обезличивание отчёта диагностики (diag.sh).
#   awk -f scrub.awk <секреты> <отчёт>
#   awk -v LIST=1 -f scrub.awk <секреты> /dev/null — значения, которых не должно остаться в отчёте
# Секреты — строки «тип<TAB>значение», собранные с роутера: H — адрес сервера (заменяется на host-N),
# S — прочее (ключи, токены, ссылка подписки…, заменяется на <скрыто>), N — имя сервера (остаётся как
# есть, даже если похоже на домен, как «St.Petersburg», — если в нём нет адресов и ключей). Они вычищаются дословно,
# а затем всё, что похоже на личные данные, — по шаблонам: ссылки, UUID, ключи, внешние IP, домены,
# e-mail, MAC. Одинаковые адреса получают одинаковые метки — видно, что речь об одном сервере.
# Пишется под busybox awk: без gensub/asort, регулярные выражения — ERE.

function lc(s) { return tolower(s) }

function hostid(h,   k) {
    k = lc(h)
    if (!(k in HM)) HM[k] = "host-" (++NH)
    return HM[k]
}

function ipid(a) {
    if (!(a in IM)) IM[a] = "ip-" (++NI)
    return IM[a]
}

# общеизвестные домены (DNS, проверочные адреса, сервисы) — не скрываем, они ничего не говорят о человеке
function allowed_host(h,   s, n) {
    h = lc(h)
    for (s in ALLOW) {
        if (h == s) return 1
        n = length(h) - length(s)
        if (n > 0 && substr(h, n) == "." s) return 1
    }
    return 0
}

function conv_ip4(t,   p, a, b) {
    split(t, p, ".")
    a = p[1] + 0; b = p[2] + 0
    if (p[1] > 255 || p[2] > 255 || p[3] > 255 || p[4] > 255) return t   # не адрес (версия и т.п.)
    if (a == 10 || a == 127 || a == 0 || a >= 224) return t
    if ((a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254)) return t
    if (a == 100 && b >= 64 && b <= 127) return t          # CGNAT / Tailscale
    if (a == 198 && (b == 18 || b == 19)) return t         # FakeIP podkop
    if ((a == 149 && b == 154) || (a == 91 && b == 108)) return t   # Telegram
    if (t in KEEPIP) return t
    return ipid(t)
}

function conv_ip6(t,   n, tmp) {
    if (t == "::" || t == "::1") return t
    tmp = t; n = gsub(/:/, ":", tmp)
    if (index(t, "::") == 0 && !(n >= 3 && t ~ /[A-Fa-f]/)) return t   # время 05:10:13 и т.п.
    if (lc(t) ~ /^fe80:/) return "fe80::<скрыто>"
    return "<ipv6>"
}

function conv_dom(t, pre,   n, lab, tld) {
    if (pre == "/" || pre == "@") return t                # путь к файлу; после @ — уже обработано
    n = split(t, lab, ".")
    tld = lc(lab[n])
    if (tld !~ /^[a-z][a-z]+$/ || (tld in NOTTLD)) return t
    if (t ~ /^[-_]/ || t ~ /_/) return t                   # идентификаторы (uci, имена функций)
    if (allowed_host(t)) return t
    return hostid(t)
}

function conv_url(t,   sch, rest, host, path, p, tail) {
    tail = ""
    while (t ~ /[],:;.)]$/) { tail = substr(t, length(t)) tail; t = substr(t, 1, length(t) - 1) }   # «…/x: 204»
    return conv_url1(t) tail
}

function conv_url1(t,   sch, rest, host, path, p) {
    sch = lc(substr(t, 1, index(t, "://") - 1))
    if (sch != "http" && sch != "https") return "<ссылка " sch ">"
    rest = substr(t, length(sch) + 4)
    p = match(rest, /[\/?#]/)
    host = p ? substr(rest, 1, RSTART - 1) : rest
    path = p ? substr(rest, RSTART) : ""
    sub(/^.*@/, "", host)                                   # логин:пароль@
    p = host; sub(/:[0-9]+$/, "", p)
    if (allowed_host(p) || p ~ /^(127\.|192\.168\.|10\.|198\.1[89]\.)/ || p ~ /^149\.154\./) return sch "://" host path
    if (p ~ /^[0-9.]+$/) return sch "://" conv_ip4(p) (path != "" ? "/<скрыто>" : "")
    return sch "://" hostid(p) (path != "" ? "/<скрыто>" : "")
}

# заменить все совпадения re результатом conv(kind, совпадение)
# (conv_* сами вызывают match — позицию запоминаем до них)
function repl(s, re, kind,   out, t, pre, st, ln) {
    out = ""
    while (match(s, re)) {
        st = RSTART; ln = RLENGTH
        if (ln < 1) { out = out substr(s, 1, st); s = substr(s, st + 1); continue }
        t = substr(s, st, ln)
        pre = st > 1 ? substr(s, st - 1, 1) : ""
        out = out substr(s, 1, st - 1)
        if (kind == "url") out = out conv_url(t)
        else if (kind == "ip4") out = out conv_ip4(t)
        else if (kind == "ip6") out = out conv_ip6(t)
        else if (kind == "dom") out = out conv_dom(t, pre)
        else if (kind == "hex") out = out (t ~ /[A-Fa-f]/ && t ~ /[0-9]/ ? "<hex>" : t)
        else if (kind == "b64") out = out (t ~ /[A-Z]/ && t ~ /[a-z]/ && t ~ /[0-9]/ ? "<ключ>" : t)
        else out = out kind
        s = substr(s, st + ln)
    }
    return out s
}

BEGIN {
    FS = "\t"
    split("gstatic.com google.com googleapis.com youtube.com googlevideo.com ytimg.com youtu.be " \
          "cloudflare.com cloudflare-dns.com one.one.one.one dns.google quad9.net adguard-dns.com " \
          "yandex.ru yandex.net telegram.org t.me github.com githubusercontent.com openwrt.org " \
          "itdog.info sagernet.org example.com gl.inet cloudflareclient.com", a, " ")
    for (i in a) ALLOW[a[i]] = 1
    split("1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 77.88.8.8 77.88.8.1 " \
          "94.140.14.14 94.140.15.15 208.67.222.222 208.67.220.220", a, " ")
    for (i in a) KEEPIP[a[i]] = 1
    # «домены», которые на деле имена файлов и уровни журнала (user.notice, config.json)
    split("json sh js css db srs lst txt ipk conf log tsv csv awk jq html md gz tar pid lock " \
          "notice err info warn warning debug crit alert emerg " \
          "backup tmp old new bak orig", a, " ")
    for (i in a) NOTTLD[a[i]] = 1
}

# файл секретов
FILENAME == ARGV[1] {
    if ($1 == "N") { if ($2 ~ /[.:]/) NAME[++NN] = $2; next }   # защищать нужно только имена с точками
    if ($2 == "" || length($2) < 4) next
    if ($1 == "H" && allowed_host($2)) next
    NS++; SV[NS] = $2; ST[NS] = $1
    if (LIST && length($2) >= 6) print $2      # -v LIST=1: только перечислить, что должно исчезнуть
    next
}

LIST { next }

# имена серверов, в которых нет ничего из секретов
!namesdone {
    namesdone = 1
    for (j = 1; j <= NN; j++) {
        bad = 0
        for (i = 1; i <= NS; i++) if (index(NAME[j], SV[i])) bad = 1
        if (!bad) KEEPN[++NK] = NAME[j]
    }
}

{
    line = $0
    gsub(/\033\[[0-9;]*m/, "", line)                       # цвета журнала sing-box
    gsub(/\r/, "", line)

    # многострочные списки пользователя (свои домены и подсети) — только количество
    if (skip) {
        skipn++
        if (line ~ /'[ \t]*$/) { print skiphead "'<скрыто: " skipn " шт.>'"; skip = 0 }
        next
    }
    if (line ~ /^[ \t]*option [a-z_]*_text '/) {
        skiphead = substr(line, 1, index(line, "'") - 1)
        rest = substr(line, index(line, "'") + 1)
        skipn = (rest ~ /^[ \t]*'?[ \t]*$/) ? 0 : 1
        if (rest ~ /'[ \t]*$/ && rest !~ /^'?[ \t]*$/) { print skiphead "'<скрыто: 1 шт.>'"; next }
        if (rest ~ /^'[ \t]*$/) { print line; next }
        skip = 1; next
    }
    if (line ~ /^[ \t]*list (user_domains|user_subnets|[a-z_]*_ips) /) { sub(/'.*$/, "'<скрыто>'", line); print line; next }
    if (line ~ /^[ \t]*(option|list) [a-z_]*(password|passwd|token|secret|username|uuid|psk|key|chat_id|subscription_url|proxy_string|proxy_links|outbound_json)[a-z_]* /) {
        sub(/'.*$/, "'<скрыто>'", line); print line; next
    }

    # дословно — всё, что известно о серверах и подписке на этом роутере (длинные значения — первыми)
    for (i = 1; i <= NS; i++) {
        v = SV[i]
        while ((p = index(line, v)) > 0)
            line = substr(line, 1, p - 1) (ST[i] == "H" ? hostid(v) : "<скрыто>") substr(line, p + length(v))
    }

    for (i = 1; i <= NK; i++)                                # имена серверов — не трогать
        while ((p = index(line, KEEPN[i])) > 0)
            line = substr(line, 1, p - 1) "\001" i "\002" substr(line, p + length(KEEPN[i]))

    line = repl(line, "[A-Za-z][A-Za-z0-9+.-]*://[^ \t'\"<>]+", "url")
    line = repl(line, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z][A-Za-z]+", "<email>")
    line = repl(line, "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "<uuid>")
    line = repl(line, "([0-9A-Fa-f][0-9A-Fa-f][:-]){5}[0-9A-Fa-f][0-9A-Fa-f]", "<mac>")
    line = repl(line, "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", "ip4")
    line = repl(line, "[0-9A-Fa-f]*(:[0-9A-Fa-f]*){2,7}", "ip6")
    line = repl(line, "[0-9A-Fa-f]{16,}", "hex")
    line = repl(line, "[A-Za-z0-9_+=-]{32,}", "b64")
    line = repl(line, "[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+", "dom")
    while (match(line, /\001[0-9]+\002/))
        line = substr(line, 1, RSTART - 1) KEEPN[substr(line, RSTART + 1, RLENGTH - 2) + 0] substr(line, RSTART + RLENGTH)
    print line
}
