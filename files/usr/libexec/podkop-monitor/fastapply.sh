#!/bin/sh
# Быстро применить изменённые ссылки секции podkop без перезапуска podkop.
#   fastapply.sh <секция>...
# Полный «podkop reload» пересоздаёт правила nft, маршруты, синхронизирует время и перезапускает sing-box —
# прокси недоступен ~8 с. Для смены серверов секции это не нужно: меняется только блок выходов секции
# в конфиге sing-box. Собираем его теми же функциями podkop и с теми же параметрами секции, что и сам podkop
# при запуске, ставим на то же место, проверяем «sing-box check» и просим sing-box перечитать конфиг (SIGHUP,
# прокси недоступен ~0,1 с). Конфиг получается тем же, что собрал бы podkop, — при следующем его запуске
# он увидит «configuration is unchanged». Код возврата не 0 — вызывающий делает обычный podkop reload.

. /lib/functions.sh
for f in constants helpers logging sing_box_config_manager sing_box_config_facade; do
    [ -f /usr/lib/podkop/$f.sh ] || { echo "fastapply: нет /usr/lib/podkop/$f.sh"; exit 1; }
    . /usr/lib/podkop/$f.sh
done
log() { :; }  # не засорять журнал podkop

[ $# -gt 0 ] || { echo "fastapply: не указаны секции"; exit 1; }
config_load podkop
config_get CFG settings config_path /etc/sing-box/config.json
[ -s "$CFG" ] || { echo "fastapply: нет $CFG"; exit 1; }

T=$(mktemp -d /tmp/fastapply.XXXXXX)
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
cp "$CFG" $T/cfg.json

# блок выходов секции — так же, как в podkop (configure_outbound_handler)
section_block() {
    local sec="$1" ctype ptype udp links link i=1 tags= config='{"outbounds":[]}'
    config_get ctype "$sec" connection_type
    [ "$ctype" = proxy ] || return 1
    config_get ptype "$sec" proxy_config_type
    config_get udp "$sec" enable_udp_over_tcp
    case "$ptype" in
    url)
        config_get link "$sec" proxy_string
        [ -n "$link" ] || return 1
        config=$(sing_box_cf_add_proxy_outbound "$config" "$sec" "$link" "$udp") || return 1
        ;;
    selector|urltest)
        config_get links "$sec" "${ptype}_proxy_links"
        [ -n "$links" ] || return 1
        for link in $links; do
            config=$(sing_box_cf_add_proxy_outbound "$config" "$sec-$i" "$link" "$udp") || return 1
            tags="${tags:+$tags,}$(get_outbound_tag_by_section "$sec-$i")"
            i=$((i + 1))
        done
        if [ "$ptype" = selector ]; then
            config=$(sing_box_cm_add_selector_outbound "$config" "$(get_outbound_tag_by_section "$sec")" \
                "$(comma_string_to_json_array "$tags")" "${tags%%,*}") || return 1
        else
            local interval tolerance url
            config_get interval "$sec" urltest_check_interval "3m"
            config_get tolerance "$sec" urltest_tolerance 50
            config_get url "$sec" urltest_testing_url "https://www.gstatic.com/generate_204"
            config=$(sing_box_cm_add_urltest_outbound "$config" "$(get_outbound_tag_by_section "$sec-urltest")" \
                "$(comma_string_to_json_array "$tags")" "$url" "$interval" "$tolerance") || return 1
            config=$(sing_box_cm_add_selector_outbound "$config" "$(get_outbound_tag_by_section "$sec")" \
                "$(comma_string_to_json_array "$tags,$(get_outbound_tag_by_section "$sec-urltest")")" \
                "$(get_outbound_tag_by_section "$sec-urltest")") || return 1
        fi
        ;;
    *) return 1 ;;   # outbound (JSON), interface — не трогаем, пусть разбирается podkop
    esac
    echo "$config" | jq -c '.outbounds'
}

for sec in "$@"; do
    case "$sec" in ''|*[!A-Za-z0-9_]*) echo "fastapply: неверная секция «$sec»"; exit 1 ;; esac
    section_block "$sec" > $T/block.json && [ -s $T/block.json ] || { echo "fastapply: не удалось собрать секцию $sec"; exit 1; }
    # выходы секции: «<сек>-out», «<сек>-<N>-out», «<сек>-urltest-out» (в именах секций UCI нет «-»,
    # поэтому чужие секции под шаблон не попадут). Блок встаёт на место первого из них.
    jq --arg s "$sec" --slurpfile b $T/block.json '
        def mine: .tag as $t | ($t == "\($s)-out") or
            (($t | startswith("\($s)-")) and ($t | endswith("-out"))
             and (($t | .[($s | length) + 1 : -4]) as $m | $m == "urltest" or ($m | tonumber? // null) != null));
        ([ .outbounds | to_entries[] | select(.value | mine) | .key ] | .[0]) as $at
        | if $at == null then error("в конфиге нет выходов секции \($s)")
          else .outbounds = (.outbounds[:$at] + $b[0] + [ .outbounds[$at:][] | select(mine | not) ]) end
        ' $T/cfg.json > $T/new.json || { echo "fastapply: не удалось вставить секцию $sec"; exit 1; }
    mv $T/new.json $T/cfg.json
done

# сохраняем так же, как podkop (sing_box_cm_save_config_to_file): без служебной метки $SERVICE_TAG,
# в формате jq — тогда файл совпадёт с тем, что podkop соберёт сам
jq --arg tag "$SERVICE_TAG" 'walk(if type == "object" then del(.[$tag]) else . end)' $T/cfg.json > $T/out.json || exit 1
cmp -s $T/out.json "$CFG" && { echo "Конфиг sing-box не изменился — перезапуск не нужен"; exit 0; }
sing-box check -c $T/out.json 2>$T/err || { echo "fastapply: sing-box check: $(head -c 200 $T/err)"; exit 1; }

# процесс sing-box podkop: среди процессов sing-box — тот, что запущен с его конфигом
# (вспомогательный sing-box мониторинга — с другим)
pid=
for p in $(pidof sing-box); do
    tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- "-c $CFG " && pid=$p
done
[ -n "$pid" ] || { echo "fastapply: sing-box не запущен"; exit 1; }
cp "$CFG" $T/prev.json
cp $T/out.json "$CFG"
kill -HUP "$pid"
sleep 2
# sing-box перечитал конфиг и жив — тот же процесс
if kill -0 "$pid" 2>/dev/null; then
    echo "Применено без перезапуска podkop"
    exit 0
fi
cp $T/prev.json "$CFG"   # что-то пошло не так — вернуть конфиг, дальше вызывающий сделает podkop reload
echo "fastapply: sing-box не пережил перечитывание конфига"
exit 1
