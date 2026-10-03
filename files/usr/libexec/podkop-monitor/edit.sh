#!/bin/sh
# Правка секции podkop по именам серверов:
#   edit.sh apply  <секция> <имя>...   — заменить ссылки ссылками одноимённых серверов из подписки
#   edit.sh remove <секция> <имя>...   — убрать серверы из секции
#   edit.sh add    <секция> <имя>...   — добавить серверы подписки в конец секции
# Серверы ищутся по имени (фрагмент ссылки после #), а не по номеру: номера сдвигаются, если podkop правили.
# Перед правкой — копия /etc/config/podkop в /etc/podkop-monitor/podkop.backup-<время> (хранятся 5 последних).
# Все изменения — одним коммитом и одним перезапуском podkop.

. /usr/libexec/podkop-monitor/common.sh

MODE="$1"; SEC="$2"; shift 2
case "$MODE" in apply|remove|add) ;; *) echo "Режим: apply|remove|add"; exit 1 ;; esac
case "$SEC" in ''|*[!A-Za-z0-9_]*) echo "Неверное имя секции"; exit 1 ;; esac
[ $# -gt 0 ] || { echo "Не указаны серверы"; exit 1; }

NAMES=$PM_RUN/edit.$$
trap 'rm -f $NAMES' EXIT
for n in "$@"; do printf '%s\n' "$n"; done > $NAMES
wanted() { grep -Fxq -- "$1" $NAMES; }

ptype=$(uci -q get podkop.$SEC.proxy_config_type)
case "$ptype" in
    urltest|selector) opt="${ptype}_proxy_links" ;;
    url) [ "$MODE" = apply ] || { echo "В секции типа url один сервер — удалять и добавлять нечего"; exit 1; }
         opt=proxy_string ;;
    *) echo "Секция $SEC: тип «$ptype» не поддерживается"; exit 1 ;;
esac

# ссылка сервера подписки по имени; h3 в ALPN для TCP/WS ломает подключение — убираем
sub_link() {
    local k l
    k=$(awk -F'|' -v n="$1" '$2 == n { print $1; exit }' "$PM_STATE/servers.tsv")
    [ -n "$k" ] || return 1
    l=$(awk -v k="$k" 'index($0, k "|") == 1 { print substr($0, length(k) + 2); exit }' "$PM_STATE/links.tsv")
    [ -n "$l" ] || return 1
    case "$l" in
        *type=ws*) l=$(echo "$l" | sed 's/&alpn=[^&#]*//') ;;
        *alpn=*) l=$(echo "$l" | sed 's/alpn=h3%2C/alpn=/; s/%2Ch3//; s/alpn=h3,/alpn=/; s/,h3//; s/&alpn=h3\([&#]\)/\1/') ;;
    esac
    echo "$l"
}

if [ "$MODE" != remove ]; then
    [ -s "$PM_STATE/links.tsv" ] || { echo "Нет ссылок подписки — нажмите «Обновить подписку»"; exit 1; }
    while IFS= read -r n; do
        sub_link "$n" >/dev/null || { echo "В подписке нет сервера «$n»"; exit 1; }
    done < $NAMES
fi

old=$(uci -q get podkop.$SEC.$opt)
new=; CHANGES=; kept=0
for l in $old; do
    n=$(pm_link_name "$l")
    if wanted "$n"; then
        case "$MODE" in
            apply)  l=$(sub_link "$n"); CHANGES="$CHANGES
  ↻ $n" ;;
            remove) CHANGES="$CHANGES
  ✕ $n"; continue ;;
            add)    echo "«$n» уже есть в секции $SEC — пропускаю" ;;
        esac
    fi
    new="$new $l"; kept=$((kept + 1))
done
if [ "$MODE" = add ]; then
    while IFS= read -r n; do
        for l in $old; do [ "$(pm_link_name "$l")" = "$n" ] && continue 2; done
        new="$new $(sub_link "$n")"; kept=$((kept + 1)); CHANGES="$CHANGES
  + $n"
    done < $NAMES
fi

if [ -z "$CHANGES" ]; then
    [ "$MODE" = add ] && echo "Все выбранные серверы уже есть в секции $SEC" || echo "Нечего менять: в секции $SEC нет таких серверов"
    exit 1
fi
[ $kept -gt 0 ] || { echo "Нельзя убрать из секции все серверы — podkop не запустится"; exit 1; }

ts=$(date +%Y%m%d-%H%M%S)
cp /etc/config/podkop "$PM_STATE/podkop.backup-$ts"
ls -1t "$PM_STATE"/podkop.backup-* 2>/dev/null | tail -n +6 | xargs -r rm -f

if [ "$opt" = proxy_string ]; then
    uci set "podkop.$SEC.proxy_string=${new# }"
else
    uci delete "podkop.$SEC.$opt"
    for l in $new; do uci add_list "podkop.$SEC.$opt=$l"; done
fi
uci commit podkop

echo "Секция $SEC:$CHANGES"
echo "Копия прежнего конфига: $PM_STATE/podkop.backup-$ts"
# PM_NO_RELOAD — вызывающий (автообновление) сам перезапустит podkop один раз после всех секций
if [ -z "$PM_NO_RELOAD" ]; then
    echo "Перезапускаю podkop…"
    [ -n "$PM_TEST" ] || /etc/init.d/podkop reload >/dev/null 2>&1
    sleep 5
    $PM_LIB/drift.sh
fi
pm_log "$SEC: $MODE$(echo "$CHANGES" | tr '\n' ' ') (бэкап podkop.backup-$ts)"
echo "Готово. Свежие замеры — после ближайшей проверки или по кнопке «Проверить сейчас»."
