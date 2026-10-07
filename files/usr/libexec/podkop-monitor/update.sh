#!/bin/sh
# Проверка обновлений и обновление из GitHub Releases.
#   update.sh check    — узнать последнюю версию, записать $PM_RUN/update.json
#   update.sh upgrade  — скачать .ipk последнего релиза и установить через opkg

. /usr/libexec/podkop-monitor/common.sh

STATE=$PM_RUN/update.json
API="${PM_GH_API:-https://api.github.com}/repos/$PM_REPO/releases/latest"   # PM_GH_API — для тестов

# 1, если версия $1 новее $2 (формат X.Y.Z, допускается префикс v)
newer() {
    awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= (n > m ? n : m); i++) {
            if (x[i] + 0 > y[i] + 0) { print 1; exit }
            if (x[i] + 0 < y[i] + 0) { print 0; exit }
        }
        print 0 }'
}

fetch_release() {
    [ -n "$PM_REPO" ] || { echo "не задан репозиторий (option repo)" >&2; return 1; }
    curl -s -L -m 20 --retry 2 --retry-delay 5 --retry-all-errors -H "Accept: application/vnd.github+json" -A "podkop-monitor/$PM_VERSION" -o $PM_RUN/release.json "$API" \
        && jq -e '.tag_name' $PM_RUN/release.json >/dev/null 2>&1
}

do_check() {
    if ! fetch_release; then
        rm -f $PM_RUN/release.json
        jq -n --arg cur "$PM_VERSION" --arg ts "$(date +%s)" \
            '{current: $cur, latest: null, available: false, checked: ($ts | tonumber), error: "не удалось получить данные о релизе"}' > $STATE
        return 1
    fi
    local latest url
    latest=$(jq -r '.tag_name' $PM_RUN/release.json)
    url=$(jq -r '[.assets[] | select(.name | endswith(".ipk")) | .browser_download_url][0] // empty' $PM_RUN/release.json)
    jq --arg cur "$PM_VERSION" --arg latest "${latest#v}" --arg url "$url" --arg ts "$(date +%s)" \
       --argjson avail "$( [ "$(newer "$latest" "$PM_VERSION")" = 1 ] && [ -n "$url" ] && echo true || echo false)" \
       '{current: $cur, latest: $latest, available: $avail, checked: ($ts | tonumber), url: $url,
         page: .html_url, notes: (.body // ""), published: .published_at}' $PM_RUN/release.json > $STATE
    rm -f $PM_RUN/release.json
    [ "$(jq -r .available $STATE)" = true ] && pm_log "доступна новая версия ${latest#v} (установлена $PM_VERSION)"
    return 0
}

do_upgrade() {
    # opkg перезапишет этот файл — работаем с копии
    case "$0" in
        /tmp/*) ;;
        *) cp "$0" /tmp/podkop-monitor-upgrade.sh && exec sh /tmp/podkop-monitor-upgrade.sh upgrade ;;
    esac
    trap 'rm -f /tmp/podkop-monitor-upgrade.sh' EXIT
    do_check || { echo "Не удалось проверить обновления"; exit 1; }
    [ "$(jq -r .available $STATE)" = true ] || { echo "Установлена последняя версия ($PM_VERSION)"; exit 0; }
    local url ipk=/tmp/podkop-monitor-upgrade.ipk
    url=$(jq -r .url $STATE)
    echo "Скачиваю $url"
    curl -s -L -m 120 -o $ipk "$url" || { echo "Ошибка загрузки"; exit 1; }
    tar -tzf $ipk 2>/dev/null | grep -q control.tar.gz || { rm -f $ipk; echo "Скачанный файл — не пакет .ipk"; exit 1; }
    opkg install $ipk; rc=$?
    rm -f $ipk
    [ $rc = 0 ] && pm_log "обновлено до $(jq -r .latest $STATE)" && echo "Готово" || echo "opkg завершился с ошибкой $rc"
    # пересчитать статус уже новой версией
    /usr/libexec/podkop-monitor/update.sh check >/dev/null 2>&1
    exit $rc
}

case "$1" in
    check) do_check ;;
    upgrade) do_upgrade ;;
    *) echo "usage: $0 check|upgrade"; exit 1 ;;
esac
