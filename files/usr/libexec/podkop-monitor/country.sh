#!/bin/sh
# Какую страну и IP видит YouTube через каждый сервер подписки. От страны зависит реклама:
# в регионе RU YouTube её не показывает. youtube.com/sw.js_data (~3 КБ) отдаёт [..,"RU",null,"<IP>"..].
# Это недокументированный ответ YouTube — может перестать работать.
# Строго последовательно: при десятках параллельных запросов YouTube отвечает не всем.

. /usr/libexec/podkop-monitor/common.sh

[ "$PM_YT_COUNTRY" = 1 ] && [ -s "$PM_STATE/servers.tsv" ] || exit 0
curl -s -m 3 -o /dev/null "$PM_HELPER_API/version" || exit 0

TS=$(date +%s)
TMP=$PM_RUN/country.$$
trap 'rm -f $TMP' EXIT
: > $TMP

while IFS='|' read key name type host; do
    r=
    for try in 1 2; do
        r=$(curl -s -m 12 -x "http://127.0.0.1:$((PM_BASE_PORT + key))" -A "Mozilla/5.0 (Macintosh) Chrome/130" \
                "https://www.youtube.com/sw.js_data" \
            | sed -n 's/.*"yt\.sw\.adr",null,\[\[\["[^"]*","\([A-Z]*\)",null,"\([^"]*\)".*/\1,\2/p' | head -1)
        [ -n "$r" ] && break
    done
    echo "$TS,$key,$name,${r:-,}" >> $TMP
done < "$PM_STATE/servers.tsv"

sort -t, -k2,2n $TMP > $PM_RUN/country.csv
cp $PM_RUN/country.csv $PM_STATE/country.csv
