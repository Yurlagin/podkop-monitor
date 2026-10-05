#!/bin/sh
# Скачивает подписку и собирает конфиг вспомогательного sing-box: по выходу на каждый сервер,
# Clash API на 127.0.0.1:helper_port, mixed-вход 127.0.0.1:(base_port+N) на сервер N.
# Понимает Xray-JSON (Remnawave и т.п.) и обычный список ссылок (base64 или текст).
# Ссылки разбирает тем же кодом, что и сам podkop, — поддерживается всё, что умеет podkop.
# При любой ошибке остаётся прежний конфиг.

. /usr/libexec/podkop-monitor/common.sh

[ -n "$PM_SUB_URL" ] || { pm_log "подписка не задана"; exit 0; }

TMP=$PM_RUN/sub.$$
trap 'rm -f $TMP.*' EXIT
: > $TMP.skip
echo '[]' > $TMP.yt

code=$(curl -s -L -m 30 -A "$PM_SUB_UA" -o $TMP.raw -w "%{http_code}" "$PM_SUB_URL")
[ "$code" = 200 ] || { pm_log "подписка: HTTP $code, оставляю прежний список"; exit 1; }

if jq -e 'type == "array" and length > 0 and (.[0].outbounds | type == "array")' $TMP.raw >/dev/null 2>&1; then
    # Xray-JSON
    jq -f $PM_LIB/xray2singbox.jq $TMP.raw > $TMP.conv || { pm_log "подписка: ошибка разбора Xray-JSON"; exit 1; }
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

[ -s $TMP.tsv ] || { pm_log "подписка: не найдено ни одного поддерживаемого сервера"; exit 1; }

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

sing-box check -c $TMP.cfg 2>$TMP.err || { pm_log "подписка: sing-box check: $(head -c 300 $TMP.err)"; exit 1; }

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
