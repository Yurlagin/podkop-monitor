#!/bin/sh
# Уведомления в Telegram о том, что требует вмешательства.
#   notify.sh run [<файл замеров текущего прогона>]  — собрать события, отправить новое/изменившееся/решённое
#   notify.sh test   <токен> <chat_id> <через_прокси 0|1> — тестовое сообщение
#   notify.sh chatid <токен> <через_прокси 0|1>           — ID чата из последнего сообщения боту
#
# Событие — строка «ключ<TAB>текст». Состояние ($PM_STATE/notify.state): «ключ<TAB>отпечаток<TAB>когда отправлено».
# Новое или изменившееся событие отправляется сразу, неизменное — напоминание раз в repeat_hours,
# пропавшее — «решено». Всё за прогон — одним сообщением. Не отправилось — повторим в следующий прогон.

. /usr/libexec/podkop-monitor/common.sh

config_get N_ENABLED notify enabled 0
config_get N_TOKEN notify bot_token ""
config_get N_CHAT notify chat_id ""
config_get N_PROXY notify via_proxy 1
config_get N_ATTENTION notify ev_attention 1
config_get N_SUB notify ev_subscription 1
config_get N_QUOTA notify quota_levels "80 90 95"
config_get N_REPEAT notify repeat_hours 24
config_get N_SUB_STALE notify sub_stale_hours 24

STATE=$PM_STATE/notify.state
TAB=$(printf '\t')

# локальный прокси podkop (mixed-вход sing-box) — Telegram API в России может блокироваться
proxy_addr() {
    local cfg
    cfg=$(uci -q get podkop.settings.config_path)
    jq -r '[.inbounds[]? | select(.type == "mixed") | "\(.listen // "127.0.0.1"):\(.listen_port)"][0] // empty' \
        "${cfg:-/etc/sing-box/config.json}" 2>/dev/null | sed 's/^0\.0\.0\.0:/127.0.0.1:/; s/^::/127.0.0.1/'
}

# tg <метод> <через_прокси> <токен> [curl -d …] → тело ответа
tg() {
    local method="$1" via="$2" token="$3" px=""
    shift 3
    [ "$via" = 1 ] && px=$(proxy_addr) && [ -n "$px" ] && px="-x http://$px"
    curl -s -m 25 $px "${PM_TG_API:-https://api.telegram.org}/bot$token/$method" "$@"   # PM_TG_API — для тестов
}

send() { # токен chat_id через_прокси текст → 0 при успехе
    local r
    r=$(tg sendMessage "$3" "$1" -d chat_id="$2" -d parse_mode=HTML -d disable_web_page_preview=true --data-urlencode text="$4")
    [ "$(echo "$r" | jq -r '.ok // false' 2>/dev/null)" = true ] && return 0
    echo "$r" | jq -r '.description // "нет ответа от Telegram"' 2>/dev/null || echo "нет ответа от Telegram"
    return 1
}

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

page_url() {
    local ip
    ip=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
    echo "https://${ip:-192.168.1.1}/cgi-bin/luci/admin/services/podkop-monitor"
}

# --- текущие события ---------------------------------------------------------------------------
events() {
    local cur="$1" now drift="$PM_RUN/drift.csv"
    now=$(date +%s)

    if [ "$N_ATTENTION" = 1 ]; then
        # подписка резко изменилась — список не обновлён (защита 0.1.3)
        if [ -s "$PM_RUN/sub-warning" ]; then
            IFS='|' read -r ts was got skipped < "$PM_RUN/sub-warning"
            printf 'subwarn\t⚠️ <b>Подписка резко изменилась</b>: серверов %s вместо %s, список не обновлён. Не разобраны: %s. Если провайдер действительно убрал серверы — примите новый список, иначе проверьте обновление мониторинга.\n' \
                "$got" "$was" "$(echo "$skipped" | tr ';' '\n' | grep -v '^$' | head -8 | tr '\n' ',' | sed 's/,$//; s/,/, /g' | esc)"
        fi
        if [ -s "$drift" ]; then
            while IFS=, read -r sec key name status fields; do
                n=$(echo "$name" | esc)
                case "$status" in
                    missing)
                        case "$fields" in дубль\|*) continue ;; esac   # дубль в секции — не срочно
                        like=""
                        [ -n "$fields" ] && like=" Похож: $(echo "$fields" | tr ';' '\n' | cut -d'|' -f2 | head -3 | tr '\n' ',' | sed 's/,$//; s/,/, /g' | esc)."
                        printf 'missing|%s|%s\t⚠️ <b>%s</b>: «%s» больше нет в подписке.%s\n' "$sec" "$name" "$sec" "$n" "$like" ;;
                    renamed)
                        case "$fields" in *";"*) ;; *) continue ;; esac  # однозначное — не требует выбора
                        printf 'ambig|%s|%s\t⚠️ <b>%s</b>: «%s» переименован? Кандидаты: %s — выберите на странице.\n' "$sec" "$name" "$sec" "$n" \
                            "$(echo "$fields" | tr ';' '\n' | cut -d'|' -f3 | tr '\n' ',' | sed 's/,$//; s/,/, /g' | esc)" ;;
                    differs)
                        # «устарел»: через podkop не отвечает в двух проверках подряд, по ссылке из подписки отвечает.
                        # Автообновление уже отработало в этом прогоне — раз событие есть, само оно не починилось.
                        [ -n "$cur" ] && [ -f "$cur" ] || continue
                        url=$(uci -q get podkop.$sec.urltest_testing_url); t=$(pm_target_label "${url:-https://www.gstatic.com/generate_204}")
                        last=$(awk -F, -v s="$sec" -v n="$name" -v t="$t" '$2==s && $4==n && $5==t { v=$6 } END { print v }' "$cur")
                        prev=$(awk -F, -v s="$sec" -v n="$name" -v t="$t" '$2==s && $4==n && $5==t { v=$6 } END { print v }' "$PM_RUN/data.csv")
                        sub=$(awk -F, -v n="$name" '$2=="_sub" && $4==n && $5=="www.gstatic.com" { v=$6 } END { print v }' "$cur")
                        [ "$last" = -1 ] && [ "$prev" = -1 ] && [ -n "$sub" ] && [ "$sub" != -1 ] || continue
                        printf 'outdated|%s|%s\t⚠️ <b>%s</b>: «%s» не отвечает, а по ссылке из подписки работает (%s мс) — обновите ссылку.\n' "$sec" "$name" "$sec" "$n" "$sub" ;;
                esac
            done < "$drift"
        fi
    fi

    # автообновление пыталось, но не смогло
    if [ "$N_ATTENTION" = 1 ] && [ -s "$PM_RUN/auto-errors" ]; then
        while IFS='|' read -r sec name why; do
            printf 'autofail|%s|%s\t⚠️ <b>%s</b>: автообновление не смогло обновить «%s»: %s\n' "$sec" "$name" "$sec" "$(echo "$name" | esc)" "$(echo "$why" | esc)"
        done < "$PM_RUN/auto-errors"
    fi

    if [ "$N_SUB" = 1 ] && [ -n "$PM_SUB_URL" ] && [ -s "$PM_STATE/sub-status" ]; then
        IFS='|' read -r ok_ts fail_ts err < "$PM_STATE/sub-status"
        if [ "${fail_ts:-0}" -gt "${ok_ts:-0}" ] && [ $((now - ${ok_ts:-0})) -ge $((N_SUB_STALE * 3600)) ]; then
            since=$([ "${ok_ts:-0}" -gt 0 ] && date -d "@$ok_ts" '+%d.%m %H:%M' || echo "давно")
            printf 'subfail\t⚠️ <b>Подписка не скачивается</b> (последний раз удачно: %s): %s.\n' "$since" "$(echo "$err" | esc)"
        fi
        if [ -s "$PM_STATE/sub-userinfo" ]; then
            IFS='|' read -r up down total expire < "$PM_STATE/sub-userinfo"
            if [ "${total:-0}" -gt 0 ]; then
                pct=$(( (up + down) * 100 / total ))
                # только последний пройденный порог: при переходе через следующий придёт новое сообщение
                top=$(for lvl in $N_QUOTA; do [ "$pct" -ge "$lvl" ] && echo "$lvl"; done | sort -n | tail -1)
                [ -n "$top" ] && printf 'quota|%s\tℹ️ <b>Трафик подписки</b>: израсходовано %s%% — больше %s%% (%s из %s ГиБ).\n' "$top" "$pct" "$top" \
                    "$(( (up + down) / 1073741824 ))" "$(( total / 1073741824 ))"
            fi
            if [ "${expire:-0}" -gt 0 ] && [ $((expire - now)) -lt $((3 * 86400)) ]; then
                printf 'expire\t⚠️ <b>Подписка заканчивается</b> %s.\n' "$(date -d "@$expire" '+%d.%m.%Y %H:%M')"
            fi
        fi
    fi
}

do_run() {
    [ "$N_ENABLED" = 1 ] && [ -n "$N_TOKEN" ] && [ -n "$N_CHAT" ] || exit 0
    # T — глобальная: очистка по trap выполняется после выхода из функции, local к тому времени уже пуст
    # (с пустым T получилось бы «rm -f .*» в текущей папке)
    local now cur="$1"
    T=$PM_RUN/notify.$$
    trap '[ -n "$T" ] && rm -f "$T".*' EXIT
    now=$(date +%s)
    # порядок в сообщении — по важности
    events "$cur" | sort -u | awk -F'\t' '{ k = $1; sub(/\|.*/, "", k)
        p = (k == "subwarn") ? 1 : (k == "subfail") ? 2 : (k == "expire") ? 3 : (k == "autofail") ? 4 : (k == "outdated") ? 4 : (k == "missing") ? 5 : (k == "ambig") ? 6 : 9
        print p "\t" $0 }' | sort -n -k1,1 -s | cut -f2- > $T.ev
    [ -f "$STATE" ] || : > "$STATE"

    : > $T.msg; : > $T.state
    # активные: новые, изменившиеся, давно не напоминали
    while IFS="$TAB" read -r key text; do
        fp=$(printf '%s' "$text" | md5sum | cut -c1-12)
        old=$(awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3; exit }' "$STATE")
        ofp=${old%%"$TAB"*}; ots=${old##*"$TAB"}
        if [ -z "$old" ] || [ "$ofp" != "$fp" ]; then
            echo "$text" >> $T.msg; printf '%s\t%s\t%s\n' "$key" "$fp" "$now" >> $T.state
        elif [ $((now - ots)) -ge $((N_REPEAT * 3600)) ] && [ "${key%%|*}" != quota ]; then
            echo "🔁 $text" >> $T.msg; printf '%s\t%s\t%s\n' "$key" "$fp" "$now" >> $T.state
        else
            printf '%s\t%s\t%s\n' "$key" "$ofp" "$ots" >> $T.state
        fi
    done < $T.ev
    # решённые: были в состоянии, сейчас нет (о снижении трафика — молча: это новый период)
    while IFS="$TAB" read -r key fp ts; do
        awk -F'\t' -v k="$key" '$1 == k { f = 1 } END { exit !f }' $T.ev && continue
        case "$key" in
            quota*) ;;
            missing\|*|outdated\|*|ambig\|*|autofail\|*)
                s=${key#*|}; echo "✅ <b>${s%%|*}</b>: «$(echo "${s#*|}" | esc)» — решено." >> $T.msg ;;
            subwarn) echo "✅ Список серверов подписки снова в порядке." >> $T.msg ;;
            subfail) echo "✅ Подписка снова скачивается." >> $T.msg ;;
            expire) echo "✅ Подписка продлена." >> $T.msg ;;
        esac
    done < "$STATE"

    if [ -s $T.msg ]; then
        text="$(cat $T.msg)

<a href=\"$(page_url)\">Открыть мониторинг</a>"
        # результат последней отправки — для страницы: «время|ok|ошибка» (если Telegram не работает, сообщить больше некуда)
        if err=$(send "$N_TOKEN" "$N_CHAT" "$N_PROXY" "$text"); then
            mv $T.state "$STATE"
            echo "$now|1|" > $PM_RUN/notify.last
            pm_log "уведомление отправлено ($(wc -l < $T.msg) строк)"
        else
            echo "$now|0|$(echo "$err" | tr '\n|' '  ')" > $PM_RUN/notify.last
            pm_log "уведомление не отправлено: $err"   # состояние не меняем — повторим в следующий прогон
        fi
    else
        mv $T.state "$STATE"
    fi
}

case "$1" in
    run) shift; do_run "$1" ;;
    test)
        [ -n "$2" ] && [ -n "$3" ] || { echo "Нужны токен бота и ID чата"; exit 1; }
        if err=$(send "$2" "$3" "${4:-1}" "✅ <b>podkop-monitor</b>: тестовое сообщение. Уведомления будут приходить сюда.

<a href=\"$(page_url)\">Открыть мониторинг</a>"); then
            echo "Отправлено"
        else
            echo "Не отправилось: $err"; exit 1
        fi ;;
    chatid)
        [ -n "$2" ] || { echo "Нужен токен бота"; exit 1; }
        r=$(tg getUpdates "${3:-1}" "$2" -d limit=20)
        [ "$(echo "$r" | jq -r '.ok // false' 2>/dev/null)" = true ] || { echo "Ошибка: $(echo "$r" | jq -r '.description // "нет ответа от Telegram"' 2>/dev/null)"; exit 1; }
        id=$(echo "$r" | jq -r '[.result[] | (.message // .edited_message // .channel_post).chat.id | select(. != null)] | last // empty')
        [ -n "$id" ] || { echo "Сообщений боту не найдено — напишите ему что-нибудь и повторите"; exit 1; }
        echo "$id" ;;
    *) echo "usage: $0 run [файл] | test <токен> <chat_id> [0|1] | chatid <токен> [0|1]"; exit 1 ;;
esac
