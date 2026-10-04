#!/bin/sh
# Один прогон замеров. Запускается из cron раз в interval минут.
#  - секции podkop (connection_type=proxy) — через Clash API самого podkop;
#  - все серверы подписки — через вспомогательный sing-box (его история на автовыбор podkop не влияет).
# Строка данных: ts,section,key,name,target,ms  (ms=-1 — нет ответа; target=now — выбранный сервер)
# section «_sub» — серверы подписки, key — номер сервера в подписке.

. /usr/libexec/podkop-monitor/common.sh

[ "$PM_ENABLED" = 1 ] || exit 0

OUT=$PM_RUN/data.csv
LOCK=$PM_RUN/check.lock
# блокировка от убитого на середине прогона не должна останавливать мониторинг навсегда
[ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ] && rmdir "$LOCK"
mkdir "$LOCK" 2>/dev/null || exit 0
TMP=$PM_RUN/check.$$
trap 'rm -rf "$LOCK" "$TMP"' EXIT
: > "$TMP"

[ -f "$OUT" ] || { [ -f "$PM_STATE/data.csv" ] && cp "$PM_STATE/data.csv" "$OUT"; }  # после перезагрузки
[ -f "$PM_RUN/auto.log" ] || { [ -f "$PM_STATE/auto.log" ] && cp "$PM_STATE/auto.log" "$PM_RUN/"; }
[ -f "$PM_RUN/skipped.tsv" ] || { [ -f "$PM_STATE/skipped.tsv" ] && cp "$PM_STATE/skipped.tsv" "$PM_RUN/"; }
TS=$(date +%s)

# check api tag section key name url...
check_server() {
    local api="$1" tag="$2" sec="$3" key="$4" name="$5" url
    shift 5
    for url in "$@"; do
        echo "$TS,$sec,$key,$name,$(pm_target_label "$url"),$(pm_delay "$api" "$tag" "$url")" >> "$TMP"
    done
}

# --- секции podkop ---
PAPI=$(pm_podkop_api)

check_section() {
    local sec="$1" ctype ptype links url lists i=0 link now
    config_get ctype "$sec" connection_type
    [ "$ctype" = proxy ] || return 0
    config_get ptype "$sec" proxy_config_type

    # цели: по спискам секции + её собственный urltest-адрес последним
    # (delay через Clash API пишет в общую историю, которой пользуется автовыбор podkop)
    config_get lists "$sec" community_lists
    config_get url "$sec" urltest_testing_url https://www.gstatic.com/generate_204
    set --
    case " $lists " in *" telegram "*) [ "$url" = http://149.154.167.51/api ] || set -- "$@" http://149.154.167.51/api ;; esac
    case " $lists " in *" youtube "*) [ "$url" = https://www.youtube.com/generate_204 ] || set -- "$@" https://www.youtube.com/generate_204 ;; esac
    set -- "$@" "$url"

    case "$ptype" in
    urltest|selector)
        config_get links "$sec" "${ptype}_proxy_links"
        for link in $links; do
            i=$((i + 1))
            check_server "$PAPI" "$sec-$i-out" "$sec" "$i" "$(pm_link_name "$link")" "$@" &
            [ $((i % PM_PARALLEL)) -eq 0 ] && wait  # иначе часть проверок ложно падает
        done
        wait
        now=$(curl -s -m 5 "$PAPI/proxies/$sec-out" | jq -r '.now // ""')
        [ "$now" = "$sec-urltest-out" ] && now=$(curl -s -m 5 "$PAPI/proxies/$now" | jq -r '.now // ""')
        now=$(echo "$now" | sed -n "s/^$sec-\([0-9]*\)-out\$/\1/p")
        echo "$TS,$sec,${now:-0},,now,0" >> "$TMP"
        ;;
    url)
        config_get link "$sec" proxy_string
        check_server "$PAPI" "$sec-out" "$sec" 1 "$(pm_link_name "$link")" "$@"
        echo "$TS,$sec,1,,now,0" >> "$TMP"
        ;;
    esac
}

if [ -n "$PAPI" ]; then
    config_load podkop
    config_foreach check_section section
fi

# --- все серверы подписки ---
if [ -s "$PM_STATE/servers.tsv" ] && curl -s -m 3 -o /dev/null "$PM_HELPER_API/version"; then
    n=0
    while IFS='|' read key name type host; do
        # YouTube — через отдельный YouTube-выход сервера, если он есть (как у клиента провайдера)
        ytag=$(awk -F'|' -v k="$key" '$1 == k { print $2 }' "$PM_STATE/yt.tsv" 2>/dev/null)
        (
            check_server "$PM_HELPER_API" "s$key-out" _sub "$key" "$name" \
                http://149.154.167.51/api https://www.gstatic.com/generate_204
            check_server "$PM_HELPER_API" "${ytag:-s$key-out}" _sub "$key" "$name" https://www.youtube.com/generate_204
        ) &
        n=$((n + 1)); [ $((n % PM_PARALLEL)) -eq 0 ] && wait  # иначе часть проверок ложно падает
    done < "$PM_STATE/servers.tsv"
    wait
fi

# сверка ссылок podkop с подпиской (podkop могли поменять в любой момент — делаем каждый прогон)
$PM_LIB/drift.sh
# автообновление ссылок по подписке (если включено); $OUT пока содержит только прошлые прогоны
$PM_LIB/autoupdate.sh "$TMP" "$OUT"

# дописать, обрезать старше keep_days, раз в час — копия на флеш
{ [ -f "$OUT" ] && awk -F, -v min=$((TS - PM_KEEP_DAYS * 86400)) '$1 >= min' "$OUT"
  sort -t, -k2,2 -k3,3n "$TMP"; } > "$OUT.new" && mv "$OUT.new" "$OUT"
[ "$(date +%M)" -lt "$PM_INTERVAL" ] && cp "$OUT" "$PM_STATE/data.csv.new" && mv "$PM_STATE/data.csv.new" "$PM_STATE/data.csv"
exit 0
