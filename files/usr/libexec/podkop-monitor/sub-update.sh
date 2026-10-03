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

code=$(curl -s -L -m 30 -A "$PM_SUB_UA" -o $TMP.raw -w "%{http_code}" "$PM_SUB_URL")
[ "$code" = 200 ] || { pm_log "подписка: HTTP $code, оставляю прежний список"; exit 1; }

if jq -e 'type == "array" and length > 0 and (.[0].outbounds | type == "array")' $TMP.raw >/dev/null 2>&1; then
    # Xray-JSON
    jq -f $PM_LIB/xray2singbox.jq $TMP.raw > $TMP.conv || { pm_log "подписка: ошибка разбора Xray-JSON"; exit 1; }
    jq '.outbounds' $TMP.conv > $TMP.obs
    jq -r '.servers[]' $TMP.conv > $TMP.tsv
    jq -r '.links[]' $TMP.conv > $TMP.links
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
            case "$link" in *type=xhttp*|*type=splithttp*) continue ;; esac  # sing-box не умеет XHTTP
            new=$(sing_box_cf_add_proxy_outbound "$config" "s$((n + 1))" "$link" "" 2>/dev/null) || continue
            [ "$(echo "$new" | jq '.outbounds | length' 2>/dev/null)" -gt "$(echo "$config" | jq '.outbounds | length')" ] || continue
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

jq --argjson port "$PM_HELPER_PORT" --argjson base "$PM_BASE_PORT" '
  . as $o
  | {
      log: { level: "error" },
      dns: { servers: [ { type: "udp", tag: "d", server: "77.88.8.8" } ] },
      inbounds: [ range(0; $o | length) | { type: "mixed", tag: "in\(. + 1)", listen: "127.0.0.1", listen_port: ($base + . + 1) } ],
      outbounds: $o,
      route: { default_domain_resolver: "d",
               rules: [ range(0; $o | length) | { inbound: "in\(. + 1)", outbound: $o[.].tag } ] },
      experimental: { clash_api: { external_controller: "127.0.0.1:\($port)" } }
    }' $TMP.obs > $TMP.cfg || { pm_log "подписка: ошибка сборки конфига"; exit 1; }

sing-box check -c $TMP.cfg 2>$TMP.err || { pm_log "подписка: sing-box check: $(head -c 300 $TMP.err)"; exit 1; }

echo "$PM_SUB_URL" > $PM_STATE/sub.url && chmod 600 $PM_STATE/sub.url  # для init: заметить смену ссылки

# ссылки серверов — для замены устаревших ссылок в podkop по кнопке (содержат ключи)
umask 077; cp $TMP.links $PM_STATE/links.tsv 2>/dev/null; umask 022

if cmp -s $TMP.cfg $PM_STATE/sb.json && cmp -s $TMP.tsv $PM_STATE/servers.tsv; then
    pm_log "подписка: без изменений ($(wc -l < $PM_STATE/servers.tsv) серверов)"
else
    mv $TMP.cfg $PM_STATE/sb.json && chmod 600 $PM_STATE/sb.json
    mv $TMP.tsv $PM_STATE/servers.tsv
    /etc/init.d/podkop-monitor restart
    pm_log "подписка: обновлена, $(wc -l < $PM_STATE/servers.tsv) серверов"
fi

$PM_LIB/drift.sh
