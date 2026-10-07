#!/bin/sh
# Диагностика podkop для отправки тому, кто помогает с настройкой.
#   diag.sh   — собрать отчёт в $PM_RUN/podkop-diag-<время>.txt и вывести путь к нему
# Личные данные вычищаются (scrub.awk): ссылки и ключи серверов, их адреса, ссылка подписки, токен бота,
# внешние IP, свои домены и подсети, e-mail, MAC. Если после чистки в отчёте всё же нашлось известное
# секретное значение — отчёт не создаётся.

. /usr/libexec/podkop-monitor/common.sh

TS=$(date +%Y%m%d-%H%M)
OUT=$PM_RUN/podkop-diag-$TS.txt
W=$(mktemp -d /tmp/pm-diag.XXXXXX)
trap '[ -n "$W" ] && rm -rf "$W"' EXIT
RAW=$W/raw.txt
SEC=$W/secrets.tsv
: > $SEC

h() { printf '\n━━━━━━━━ %s ━━━━━━━━\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- секреты: всё, что есть в ссылках серверов podkop и подписки ---
add_link_secrets() {  # ссылка → строки H/S в $SEC
    local l="$1" rest ui hp host q kv k v
    case "$l" in *://*) ;; *) return ;; esac
    echo "S	$l" >> $SEC
    echo "N	$(pm_link_name "$l")" >> $SEC
    rest="${l#*://}"; rest="${rest%%#*}"
    q=; case "$rest" in *\?*) q="${rest#*\?}" ;; esac
    rest="${rest%%\?*}"; rest="${rest%%/*}"
    case "$rest" in *@*) ui="${rest%@*}"; hp="${rest##*@}"; echo "S	$ui" >> $SEC; echo "S	$(pm_urldec "$ui")" >> $SEC ;; *) hp="$rest" ;; esac
    host="${hp%:*}"; host="${host#[}"; host="${host%]}"
    [ -n "$host" ] && echo "H	$host" >> $SEC
    for kv in $(echo "$q" | tr '&' ' '); do
        k="${kv%%=*}"; v="$(pm_urldec "${kv#*=}")"
        case "$k" in
            sni|host|peer|servername) echo "H	$v" >> $SEC ;;
            pbk|sid|spx|password|obfs-password|auth|path|serviceName|authority|key|uuid|seed) echo "S	$v" >> $SEC ;;
        esac
    done
}
for l in $(uci -q show podkop | grep -E "\.(urltest_proxy_links|selector_proxy_links|proxy_string)=" | cut -d= -f2- | tr -d "'"); do
    add_link_secrets "$l"
done
[ -s "$PM_STATE/links.tsv" ] && cut -d'|' -f2- "$PM_STATE/links.tsv" | while read -r l; do add_link_secrets "$l"; done
if [ -n "$PM_SUB_URL" ]; then
    echo "S	$PM_SUB_URL" >> $SEC
    s="${PM_SUB_URL#*://}"; echo "H	${s%%/*}" >> $SEC; echo "S	${s#*/}" >> $SEC
fi
[ -s "$PM_STATE/sub.url" ] && echo "S	$(cat "$PM_STATE/sub.url")" >> $SEC
for o in bot_token chat_id; do v=$(uci -q get podkop-monitor.notify.$o) && echo "S	$v" >> $SEC; done
v=$(uci -q get podkop.settings.yacd_secret_key) && echo "S	$v" >> $SEC
v=$(uci -q get system.@system[0].hostname) && case "$v" in OpenWrt|'') ;; *) echo "S	$v" >> $SEC ;; esac
# длинные значения — первыми: иначе часть длинного заменится раньше целого
awk -F'\t' 'length($2) >= 4 || $1 == "N" { print length($2) "\t" $0 }' $SEC | sort -rn -k1,1 | cut -f2- | uniq > $SEC.sorted

# --- отчёт ---
{
echo "Диагностика podkop — podkop-monitor $PM_VERSION"
echo "Создано: $(date '+%Y-%m-%d %H:%M %Z')"
echo "Личные данные скрыты: ссылки и ключи серверов (адреса заменены на host-N), ссылка подписки,"
echo "токен бота, внешние IP (ip-N), свои домены и подсети, e-mail, MAC."

h "Система"
echo "Устройство:  $(cat /tmp/sysinfo/model 2>/dev/null)"
. /etc/openwrt_release 2>/dev/null
echo "OpenWrt:     $DISTRIB_RELEASE $DISTRIB_REVISION ($DISTRIB_TARGET, $DISTRIB_ARCH)"
echo "Ядро:        $(uname -r)"
echo "Время:       $(date '+%Y-%m-%d %H:%M:%S %Z') (если сильно неверное — TLS и прокси работать не будут)"
pidof ntpd >/dev/null && echo "ntpd:        запущен" || echo "ntpd:        НЕ запущен"
echo "Работает:    $(uptime | sed 's/^ *//')"
free | awk 'NR==2 { printf "Память:      свободно %d из %d МБ\n", $7 ? $7/1024 : $4/1024, $2/1024 }'
df -h /overlay /tmp 2>/dev/null | awk 'NR > 1 { printf "Диск %-8s свободно %s из %s\n", $6, $4, $2 }'

h "Пакеты"
opkg list-installed 2>/dev/null | grep -E "^(podkop|luci-app-podkop|luci-i18n-podkop|sing-box|podkop-monitor|dnsmasq|jq|curl|kmod-nft-tproxy|nftables|coreutils-base64) " \
    | sed 's/^/  /'
c=$(opkg list-installed 2>/dev/null | grep -iE "^(https-dns-proxy|adguardhome|stubby|dnscrypt|zapret|youtubeUnblock|byedpi|luci-app-passwall|passwall|ssclash|mihomo|xray|v2ray|openclash|luci-app-ssr|nikki|tailscale|wireguard-tools|amneziawg|openvpn)" | cut -d' ' -f1-3)
[ -n "$c" ] && { echo "Пакеты, которые могут влиять на DNS/маршрутизацию:"; echo "$c" | sed 's/^/  /'; }

h "Проверка podkop (podkop global_check)"
if [ -x /usr/bin/podkop ]; then
    if grep -q "global_check" /usr/bin/podkop; then
        /usr/bin/podkop global_check 2>&1 | head -400
    else
        /usr/bin/podkop show_version 2>&1; /usr/bin/podkop show_config 2>&1
    fi
    echo
    echo "Состояние: $(/usr/bin/podkop get_status 2>/dev/null)"
    echo "sing-box:  $(/usr/bin/podkop get_sing_box_status 2>/dev/null)"
else
    echo "podkop не установлен"
fi

h "Секции и серверы podkop"
API=$(pm_podkop_api)
[ -n "$API" ] && curl -s -m 5 "$API/proxies" > $W/proxies.json 2>/dev/null
for sec in $(uci -q show podkop | sed -n "s/^podkop\.\([A-Za-z0-9_]*\)=section$/\1/p"); do
    ct=$(uci -q get podkop.$sec.connection_type); pt=$(uci -q get podkop.$sec.proxy_config_type)
    echo "[$sec] $ct${pt:+ / $pt}  списки: $(uci -q get podkop.$sec.community_lists | tr ' ' ',')"
    [ "$ct" = proxy ] || { [ "$ct" = vpn ] && echo "  интерфейс: $(uci -q get podkop.$sec.interface)"; continue; }
    case "$pt" in
        url) links=$(uci -q get podkop.$sec.proxy_string) ;;
        selector|urltest) links=$(uci -q get podkop.$sec.${pt}_proxy_links) ;;
        *) links= ; echo "  выход задан JSON-ом (outbound)";;
    esac
    i=1
    for l in $links; do
        sch="${l%%://*}"; rest="${l#*://}"; name=$(pm_link_name "$l")
        q=; case "${rest%%#*}" in *\?*) q="${rest%%#*}"; q="${q#*\?}" ;; esac
        hp="${rest%%[?#]*}"; hp="${hp%%/*}"; hp="${hp##*@}"
        params=$(echo "$q" | tr '&' '\n' | while IFS='=' read -r k v; do
            case "$k" in
                (type|security|flow|fp|encryption|alpn|headerType|mode|allowInsecure|insecure|obfs|congestion_control|udp_relay_mode|packetEncoding)
                    printf ' %s=%s' "$k" "$(pm_urldec "$v")" ;;
                (sni|host) printf ' %s=%s' "$k" "$(pm_urldec "$v")" ;;   # адрес — превратится в host-N
                (pbk|sid|password|obfs-password|path|serviceName|spx) printf ' %s=<есть>' "$k" ;;
            esac
        done)
        tag="$sec-$i-out"; [ "$pt" = url ] && tag="$sec-out"
        hist=$(jq -r --arg t "$tag" '.proxies[$t].history[-1].delay // empty' $W/proxies.json 2>/dev/null)
        printf '  %-2s %s  %s %s%s%s\n' "$i" "$name" "$sch" "$hp" "$params" "${hist:+  [sing-box: ${hist} мс]}"
        i=$((i + 1))
    done
    if [ -s $W/proxies.json ]; then
        now=$(jq -r --arg t "$sec-out" '.proxies[$t].now // empty' $W/proxies.json)
        ut=$(jq -r --arg t "$sec-urltest-out" '.proxies[$t].now // empty' $W/proxies.json)
        [ -n "$now" ] && echo "  выбран: $now${ut:+ (urltest → $ut)}"
        url=$(uci -q get podkop.$sec.urltest_testing_url); url=${url:-https://www.gstatic.com/generate_204}
        echo "  проверка сейчас ($sec-out → $url): $(pm_delay "$API" "$sec-out" "$url") мс"
    fi
done
[ -n "$API" ] || echo "Clash API sing-box не найден в конфиге — проверки через секции пропущены"
[ -n "$API" ] && [ ! -s $W/proxies.json ] && echo "Clash API sing-box ($API) не отвечает — sing-box не запущен?"

h "Проверки связи с роутера"
for u in https://www.gstatic.com/generate_204 https://www.google.com https://www.youtube.com https://api.telegram.org; do
    r=$(curl -s -o /dev/null -m 10 -w '%{http_code} за %{time_total} с' "$u" 2>&1)
    echo "  напрямую $u: ${r:-нет ответа}"
done
for d in www.youtube.com www.google.com telegram.org www.gstatic.com; do
    r=$(nslookup $d 127.0.0.1 2>/dev/null | awk '/^Name:/ { f = 1 } f && /^Address/ { print $NF }' | head -2 | tr '\n' ' ')
    echo "  DNS $d → ${r:-не разрешился}"
done
LAN=$(uci -q get network.lan.ipaddr); LAN=${LAN%%/*}
for sec in $(uci -q show podkop | sed -n "s/^podkop\.\([A-Za-z0-9_]*\)\.mixed_proxy_enabled='1'$/\1/p"); do
    port=$(uci -q get podkop.$sec.mixed_proxy_port); port=${port:-2080}
    r=$(curl -s -o /dev/null -m 10 -x "http://${LAN:-127.0.0.1}:$port" -w '%{http_code} за %{time_total} с' https://www.gstatic.com/generate_204 2>&1)
    echo "  через прокси $sec (порт $port): ${r:-нет ответа}"
done

h "Мониторинг"
echo "Включён: $PM_ENABLED, каждые $PM_INTERVAL мин; подписка: $([ -n "$PM_SUB_URL" ] && echo задана || echo не задана); автообновление ссылок: $PM_AUTO_UPDATE"
echo "Уведомления: $(uci -q get podkop-monitor.notify.enabled || echo 0), через прокси: $(uci -q get podkop-monitor.notify.via_proxy || echo 1)"
if [ -s "$PM_STATE/sub-status" ]; then
    IFS='|' read -r ok_ts fail_ts err < "$PM_STATE/sub-status"
    echo "Подписка: последняя удачная загрузка $([ "${ok_ts:-0}" -gt 0 ] && date -d @$ok_ts '+%Y-%m-%d %H:%M' || echo никогда)"
    [ -n "$fail_ts" ] && echo "  последняя неудачная: $(date -d @$fail_ts '+%Y-%m-%d %H:%M')${err:+ — $err}"
fi
if [ -s "$PM_STATE/sub-userinfo" ]; then
    IFS='|' read -r up down total exp < "$PM_STATE/sub-userinfo"
    awk -v u="$up" -v d="$down" -v t="$total" 'BEGIN { if (t > 0) printf "Трафик: израсходовано %.0f%%\n", (u + d) * 100 / t }'
    [ "${exp:-0}" -gt 0 ] 2>/dev/null && echo "Подписка действует до: $(date -d @$exp '+%Y-%m-%d' 2>/dev/null)"
fi
[ -s "$PM_STATE/servers.tsv" ] && echo "Серверов в подписке: $(wc -l < "$PM_STATE/servers.tsv"), пропущено: $(cat "$PM_STATE/skipped.tsv" 2>/dev/null | wc -l)"
[ -s "$PM_RUN/sub-warning" ] && echo "Предупреждение подписки: $(cat "$PM_RUN/sub-warning" | cut -d'|' -f1-3)"
if [ -s "$PM_RUN/data.csv" ]; then
    last=$(tail -1 "$PM_RUN/data.csv" | cut -d, -f1)
    echo "Последняя проверка серверов: $(date -d @$last '+%Y-%m-%d %H:%M' 2>/dev/null)"
    awk -F, -v t="$last" '$1 == t && $2 != "_sub" && $4 != "" { printf "  %-10s %s → %s: %s\n", $2, $4, $5, ($6 < 0 ? "нет ответа" : $6 " мс") }' "$PM_RUN/data.csv"
    awk -F, -v t="$last" '$1 == t && $2 == "_sub" { n++; if ($6 >= 0) ok++ } END { if (n) printf "  серверы подписки: отвечают %d из %d\n", ok, n }' "$PM_RUN/data.csv"
fi
[ -s "$PM_RUN/drift.csv" ] && echo "Сверка с подпиской: $(cut -d, -f4 "$PM_RUN/drift.csv" | sort | uniq -c | awk '{ printf "%s %s; ", $2, $1 }')"
[ -s "$PM_RUN/auto.log" ] && { echo "Автообновление (последние):"; tail -3 "$PM_RUN/auto.log" | awk -F'|' '{ printf "  %s  %s\n", strftime("%Y-%m-%d %H:%M", $1), ($2 == "" ? "без замен" : $2) }'; }
[ -s "$PM_RUN/auto-errors" ] && { echo "Ошибки автообновления:"; sed 's/^/  /' "$PM_RUN/auto-errors"; }
[ -s "$PM_RUN/notify.last" ] && awk -F'|' '{ printf "Последняя отправка в Telegram: %s %s\n", strftime("%Y-%m-%d %H:%M", $1), ($2 == 1 ? "успешно" : "ошибка: " $3) }' "$PM_RUN/notify.last"
for f in check apply remove add sync upgrade sub-update; do
    [ -s "$PM_RUN/$f.rc" ] && [ "$(cat "$PM_RUN/$f.rc")" != 0 ] && { echo "Последний «$f» завершился с ошибкой:"; tail -5 "$PM_RUN/$f.log" | sed 's/^/  /'; }
done

h "Сеть"
echo "Интерфейсы: $(for i in /sys/class/net/*; do printf '%s(%s) ' "${i##*/}" "$(cat $i/operstate 2>/dev/null)"; done)"
echo "Правила маршрутизации:"; ip rule 2>/dev/null | sed 's/^/  /'
echo "Маршруты по умолчанию и podkop:"; ip route show table all 2>/dev/null | grep -E "^default|table podkop" | sed 's/^/  /'
echo "DNS dnsmasq: $(uci -q get dhcp.@dnsmasq[0].server | tr ' ' ',') noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv)"
nft list tables 2>/dev/null | sed 's/^/  /'

h "Журнал (podkop, sing-box, podkop-monitor — последние 200 строк)"
logread 2>/dev/null | grep -E "podkop|sing-box|dnsmasq.*(fail|error|refused)" | tail -200
} > $RAW 2>&1

awk -f $PM_LIB/scrub.awk $SEC.sorted $RAW > $W/out.txt || { echo "Не удалось обработать отчёт"; exit 1; }

# страховка: ни одно известное секретное значение не должно остаться
awk -v LIST=1 -f $PM_LIB/scrub.awk $SEC.sorted /dev/null > $W/check.lst
if [ -s $W/check.lst ] && grep -qF -f $W/check.lst $W/out.txt; then
    echo "В отчёте остались личные данные — отчёт не создан. Сообщите об этом автору podkop-monitor."
    exit 1
fi

rm -f $PM_RUN/podkop-diag-*.txt
cp $W/out.txt "$OUT"
echo "$OUT"
