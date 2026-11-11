#!/bin/sh
# Скачивает подписку и собирает конфиг вспомогательного sing-box: по выходу на каждый сервер,
# Clash API на 127.0.0.1:helper_port, mixed-вход 127.0.0.1:(base_port+N) на сервер N.
# Понимает Xray-JSON (Remnawave и т.п.) и обычный список ссылок (base64 или текст).
# Ссылки разбирает тем же кодом, что и сам podkop, — поддерживается всё, что умеет podkop.
# При любой ошибке остаётся прежний конфиг.

. /usr/libexec/podkop-monitor/common.sh

[ -n "$PM_SUB_URL" ] || { pm_log "подписка не задана"; exit 0; }

TMP=$PM_RUN/sub.$$
trap '[ -n "$TMP" ] && rm -f "$TMP".*' EXIT
: > $TMP.skip
echo '[]' > $TMP.yt

# состояние для уведомлений: «когда последний раз удачно|когда последняя ошибка|текст ошибки»
sub_fail() {
    local ok
    ok=$(cut -d'|' -f1 $PM_STATE/sub-status 2>/dev/null)
    echo "${ok:-0}|$(date +%s)|$1" > $PM_STATE/sub-status
    pm_log "подписка: $1, оставляю прежний список"
    exit 1
}

# HWID — постоянный идентификатор роутера. Провайдеры на Remnawave с ограничением числа устройств
# без него отдают заглушку вместо серверов; первый запрос с ним привязывает роутер к подписке.
# Создаётся один раз и хранится в конфиге (переживает обновления, попадает в бэкап настроек).
if [ -z "$PM_SUB_HWID" ]; then
    PM_SUB_HWID=$(cat /proc/sys/kernel/random/uuid)
    uci set podkop-monitor.main.subscription_hwid="$PM_SUB_HWID" && uci commit podkop-monitor
    pm_log "подписка: создан HWID роутера $PM_SUB_HWID"
fi
os_ver=$(. /etc/openwrt_release 2>/dev/null; echo "OpenWrt ${DISTRIB_RELEASE:-?}")
model=$(tr -cd '[:print:]' < /tmp/sysinfo/model 2>/dev/null)

code=$(curl -s -L -m 30 -A "$PM_SUB_UA" -H "x-hwid: $PM_SUB_HWID" -H "x-device-os: Linux" \
            -H "x-ver-os: $os_ver" -H "x-device-model: ${model:-OpenWrt router}" \
            -D $TMP.hdr -o $TMP.raw -w "%{http_code}" "$PM_SUB_URL")
[ "$code" = 200 ] || sub_fail "HTTP $code"

# Заглушка Remnawave (HWID не передан, лимит устройств, подписка неактивна…): одна фиктивная запись
# с нулевым UUID на 0.0.0.0, причина — в её имени. Это не новый список серверов, а ошибка скачивания.
ZERO=00000000-0000-0000-0000-000000000000
stub=
if jq -e . $TMP.raw >/dev/null 2>&1; then
    grep -q "$ZERO" $TMP.raw && stub=$(jq -r '(if type == "array" then .[0] else . end).remarks // "без описания"' $TMP.raw)
else
    l=$({ grep -q "://" $TMP.raw && cat $TMP.raw || base64 -d < $TMP.raw 2>/dev/null; } | tr -d '\r' | grep -m1 "$ZERO@")
    [ -n "$l" ] && stub=$(pm_link_name "$l")
fi
if [ -n "$stub" ]; then
    rm -f $PM_STATE/sub-warning $PM_RUN/sub-warning  # «серверов стало 1» из-за заглушки — не то, о чём стоит предупреждать
    case "$stub" in
        *HWID*|*[Уу]стройств*) sub_fail "провайдер вернул заглушку «$stub» — проверьте привязанные устройства в личном кабинете или боте провайдера (HWID роутера: $PM_SUB_HWID)" ;;
        *) sub_fail "провайдер вернул заглушку «$stub» вместо серверов" ;;
    esac
fi
# трафик и срок подписки из заголовка subscription-userinfo: «upload|download|total|expire»
grep -i '^subscription-userinfo:' $TMP.hdr | tail -1 | tr -d '\r' | sed 's/^[^:]*://' | tr ';' '\n' \
    | awk -F= '{ k = $1; gsub(/ /, "", k); if (k != "") { v[k] = $2 + 0; n++ } }
               END { if (n) print v["upload"] + 0 "|" v["download"] + 0 "|" v["total"] + 0 "|" v["expire"] + 0 }' > $TMP.ui
[ -s $TMP.ui ] && mv $TMP.ui $PM_STATE/sub-userinfo

if jq -e 'type == "array" and length > 0 and (.[0].outbounds | type == "array")' $TMP.raw >/dev/null 2>&1; then
    # Xray-JSON
    jq -f $PM_LIB/xray2singbox.jq $TMP.raw > $TMP.conv || sub_fail "ошибка разбора Xray-JSON"
    jq '.outbounds' $TMP.conv > $TMP.obs
    jq -r '.servers[]' $TMP.conv > $TMP.tsv
    jq -r '.links[]' $TMP.conv > $TMP.links
    jq -r '.skipped[]' $TMP.conv > $TMP.skip
    jq '.yt' $TMP.conv > $TMP.yt
else
    # список ссылок: base64 или как есть
    if grep -q "://" $TMP.raw; then cp $TMP.raw $TMP.dec; else base64 -d < $TMP.raw > $TMP.dec 2>/dev/null; fi
    tr -d "\r" < $TMP.dec | grep -E '^(vless|vmess|trojan|ss|hysteria2|hy2|socks[45]a?)://' > $TMP.list
    (
        for f in constants helpers logging sing_box_config_manager sing_box_config_facade; do
            . /usr/lib/podkop/$f.sh
        done
        log() { :; }  # не засорять журнал podkop
        n=0; config='{"outbounds":[]}'
        while read -r link; do
            case "$link" in *type=xhttp*|*type=splithttp*)  # sing-box не умеет XHTTP
                echo "$(pm_link_name "$link")|транспорт xhttp не поддерживается sing-box" >> $TMP.skip; continue ;; esac
            new=$(sing_box_cf_add_proxy_outbound "$config" "s$((n + 1))" "$link" "" 2>/dev/null)
            if [ -z "$new" ] || [ "$(echo "$new" | jq '.outbounds | length' 2>/dev/null)" -le "$(echo "$config" | jq '.outbounds | length')" ]; then
                echo "$(pm_link_name "$link")|podkop не смог разобрать ссылку" >> $TMP.skip; continue
            fi
            config=$new; n=$((n + 1))
            name=$(pm_link_name "$link")
            host=$(echo "$link" | sed 's#^[^:]*://##; s#^[^@]*@##; s#[:/?].*##')
            echo "$n|$name|${link%%://*}|$host" >> $TMP.tsv
            echo "$n|$link" >> $TMP.links
        done < $TMP.list
        echo "$config" | jq '.outbounds' > $TMP.obs
    )
fi

[ -s $TMP.tsv ] || sub_fail "не найдено ни одного поддерживаемого сервера"

# вход N → сервер N; домены YouTube — на отдельный YouTube-выход сервера, если он есть (как у клиента провайдера)
jq --argjson port "$PM_HELPER_PORT" --argjson base "$PM_BASE_PORT" --argjson n "$(wc -l < $TMP.tsv)" \
   --slurpfile yt $TMP.yt '
  . as $o
  | ($yt[0] | map({ (.key | tostring): . }) | add // {}) as $ytk
  | {
      log: { level: "error" },
      dns: { servers: [ { type: "udp", tag: "d", server: "77.88.8.8" } ] },
      inbounds: [ range(1; $n + 1) | { type: "mixed", tag: "in\(.)", listen: "127.0.0.1", listen_port: ($base + .) } ],
      outbounds: $o,
      route: { default_domain_resolver: "d",
               rules: [ range(1; $n + 1) | . as $k
                 | ($ytk[$k | tostring] // null) as $y
                 | (if $y then
                      { inbound: "in\($k)", outbound: $y.tag }
                      + (if ($y.domain_suffix | length) > 0 then { domain_suffix: $y.domain_suffix } else {} end)
                      + (if ($y.domain | length) > 0 then { domain: $y.domain } else {} end)
                      + (if ($y.domain_keyword | length) > 0 then { domain_keyword: $y.domain_keyword } else {} end)
                    else empty end),
                   { inbound: "in\($k)", outbound: "s\($k)-out" } ] },
      experimental: { clash_api: { external_controller: "127.0.0.1:\($port)" } }
    }' $TMP.obs > $TMP.cfg || { pm_log "подписка: ошибка сборки конфига"; exit 1; }

sing-box check -c $TMP.cfg 2>$TMP.err || sub_fail "sing-box check: $(head -c 200 $TMP.err | tr '\n|' '  ')"
echo "$(date +%s)|$(cut -d'|' -f2 $PM_STATE/sub-status 2>/dev/null)|" > $PM_STATE/sub-status  # скачалась и разобралась

# Защита от резкой потери серверов: если провайдер сменил формат и мы перестали понимать часть записей,
# лучше оставить прежний список и предупредить, чем молча потерять половину серверов.
# Не срабатывает при смене ссылки на подписку и при PM_SUB_FORCE=1 («Принять новый список»).
new_n=$(wc -l < $TMP.tsv); old_n=$(wc -l < $PM_STATE/servers.tsv 2>/dev/null || echo 0)
if [ -z "$PM_SUB_FORCE" ] && [ "$PM_SUB_URL" = "$(cat $PM_STATE/sub.url 2>/dev/null)" ] \
   && [ "$old_n" -ge 5 ] && [ $((new_n * 10)) -lt $((old_n * 6)) ]; then
    echo "$(date +%s)|$old_n|$new_n|$(cut -d'|' -f1 $TMP.skip | head -20 | tr '\n' ';')" > $PM_STATE/sub-warning
    cp $PM_STATE/sub-warning $PM_RUN/sub-warning
    pm_log "подписка: серверов стало $new_n вместо $old_n — список не обновлён (возможно, провайдер сменил формат). Принять: podkop-monitor sub-update --force"
    exit 2
fi
rm -f $PM_STATE/sub-warning $PM_RUN/sub-warning

echo "$PM_SUB_URL" > $PM_STATE/sub.url && chmod 600 $PM_STATE/sub.url  # для init: заметить смену ссылки

# ссылки серверов — для замены устаревших ссылок в podkop по кнопке (содержат ключи)
umask 077; cp $TMP.links $PM_STATE/links.tsv 2>/dev/null; umask 022
# пропущенные записи (с причиной) и серверы с отдельным YouTube-выходом: «номер|тег»
cp $TMP.skip $PM_STATE/skipped.tsv && cp $TMP.skip $PM_RUN/skipped.tsv
jq -r '.[] | "\(.key)|\(.tag)"' $TMP.yt > $PM_STATE/yt.tsv

if cmp -s $TMP.cfg $PM_STATE/sb.json && cmp -s $TMP.tsv $PM_STATE/servers.tsv; then
    pm_log "подписка: без изменений ($(wc -l < $PM_STATE/servers.tsv) серверов)"
else
    mv $TMP.cfg $PM_STATE/sb.json && chmod 600 $PM_STATE/sb.json
    mv $TMP.tsv $PM_STATE/servers.tsv
    /etc/init.d/podkop-monitor restart
    pm_log "подписка: обновлена, $(wc -l < $PM_STATE/servers.tsv) серверов"
fi

$PM_LIB/drift.sh
