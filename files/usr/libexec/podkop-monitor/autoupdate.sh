#!/bin/sh
# Автообновление ссылок в секциях podkop по подписке (option auto_update, по умолчанию off).
#   outdated — только неработающие: ссылка отличается от подписки, через podkop сервер не ответил
#              в этой и в прошлой проверке, а одноимённый сервер подписки в этой проверке ответил;
#   all      — любые расхождения с подпиской (затрёт намеренные правки, например SNI — используйте исключения).
# В обоих режимах однозначные переименования (тот же сервер под новым именем) применяются сразу:
# меняется только имя ссылки, история переносится.
# Вызывается из check.sh после drift.sh: autoupdate.sh <файл замеров этого прогона> <файл истории>
# Все секции правятся с одним перезапуском podkop.

. /usr/libexec/podkop-monitor/common.sh

case "$PM_AUTO_UPDATE" in outdated|all) ;; *) exit 0 ;; esac
CUR="$1"; HIST="$2"
DRIFT=$PM_RUN/drift.csv
[ -s "$DRIFT" ] && [ -s "$PM_STATE/links.tsv" ] || exit 0

TMP=$PM_RUN/auto.$$
trap 'rm -f $TMP.*' EXIT

# исключения (имена могут содержать пробелы — читаем список UCI поэлементно)
: > $TMP.excl
add_excl() { printf '%s\n' "$1" >> $TMP.excl; }
config_list_foreach main auto_update_exclude add_excl

# последнее значение основной цели: файл секция имя цель → мс (или пусто)
last_ms() { awk -F, -v s="$2" -v n="$3" -v t="$4" '$2 == s && $4 == n && $5 == t { v = $6 } END { print v }' "$1"; }

config_load podkop
: > $TMP.plan; : > $TMP.ren
while IFS=, read -r sec key name status fields; do
    grep -Fxq -- "$name" $TMP.excl && continue
    if [ "$status" = renamed ]; then
        # только однозначные: ровно один кандидат «имя|старое|новое»
        case "$fields" in *";"*) continue ;; esac
        printf '%s\t%s\t%s\n' "$sec" "$name" "${fields##*|}" >> $TMP.ren
        continue
    fi
    [ "$status" = differs ] || continue
    if [ "$PM_AUTO_UPDATE" = outdated ]; then
        config_get url "$sec" urltest_testing_url https://www.gstatic.com/generate_204
        t=$(pm_target_label "$url")
        now=$(last_ms "$CUR" "$sec" "$name" "$t")
        [ "$now" = -1 ] || continue
        # и в прошлой проверке тоже не отвечал — не реагируем на разовый сбой
        prev=$(last_ms "$HIST" "$sec" "$name" "$t")
        [ "$prev" = -1 ] || continue
        sub=$(last_ms "$CUR" _sub "$name" www.gstatic.com)
        [ -n "$sub" ] && [ "$sub" != -1 ] || continue
    fi
    printf '%s\t%s\n' "$sec" "$name" >> $TMP.plan
done < "$DRIFT"
[ -s $TMP.plan ] || [ -s $TMP.ren ] || exit 0

: > $TMP.log
TAB=$(printf '\t')
for sec in $(cut -f1 $TMP.plan $TMP.ren | sort -u); do
    set --
    while IFS="$TAB" read -r s n; do [ "$s" = "$sec" ] && set -- "$@" "$n"; done < $TMP.plan
    set -- "$@" --
    while IFS="$TAB" read -r s o nn; do [ "$s" = "$sec" ] && set -- "$@" "$o" "$nn"; done < $TMP.ren
    PM_NO_RELOAD=1 PM_IN_CHECK=1 PM_EXTRA_DATA="$CUR" $PM_LIB/edit.sh sync "$sec" "$@" >> $TMP.log 2>&1
done
[ -n "$PM_TEST" ] || /etc/init.d/podkop reload >/dev/null 2>&1
sleep 5
$PM_LIB/drift.sh

# журнал для страницы: последние 20 событий
{ echo "$(date +%s)|$(grep -E '^  (↻|✎) ' $TMP.log | sed 's/^  ↻ //; s/^  ✎ //' | tr '\n' ';')|$PM_AUTO_UPDATE"
  if [ -f $PM_STATE/auto.log ]; then head -19 $PM_STATE/auto.log; fi; } > $TMP.new && mv $TMP.new $PM_STATE/auto.log
cp $PM_STATE/auto.log $PM_RUN/auto.log
pm_log "автообновление ($PM_AUTO_UPDATE): $(grep -E '^  (↻|✎) ' $TMP.log | sed 's/^  //' | tr '\n' ' ')"
