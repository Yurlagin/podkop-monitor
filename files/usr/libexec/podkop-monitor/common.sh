# Общие настройки и функции podkop-monitor. Подключается остальными скриптами.

. /lib/functions.sh

PM_LIB=/usr/libexec/podkop-monitor
PM_RUN=${PM_RUN:-/tmp/podkop-monitor}      # рабочие данные (RAM)
PM_STATE=${PM_STATE:-/etc/podkop-monitor}  # то, что переживает перезагрузку (переопределяются для тестов)
PM_VERSION=$(cat "$PM_LIB/VERSION" 2>/dev/null || echo 0.0.0)

mkdir -p "$PM_RUN" "$PM_STATE"

config_load podkop-monitor
config_get PM_ENABLED main enabled 1
config_get PM_INTERVAL main interval 15
config_get PM_KEEP_DAYS main keep_days 7
config_get PM_SUB_URL main subscription_url ""
config_get PM_SUB_UA main subscription_ua "v2rayNG/1.9.30"
config_get PM_HELPER_PORT main helper_port 9092
config_get PM_BASE_PORT main base_port 32000
config_get PM_PARALLEL main parallel 8
config_get PM_TIMEOUT main timeout 5000
config_get PM_YT_COUNTRY main youtube_country 1
config_get PM_UPDATE_CHECK main update_check 1
config_get PM_REPO main repo ""
config_get PM_AUTO_UPDATE main auto_update off       # off | outdated | all

PM_HELPER_API="http://127.0.0.1:$PM_HELPER_PORT"

pm_log() { logger -t podkop-monitor "$*"; }

# Адрес Clash API основного sing-box podkop (берём из его конфига)
pm_podkop_api() {
    local cfg ctl
    cfg=$(uci -q get podkop.settings.config_path)
    ctl=$(jq -r '.experimental.clash_api.external_controller // empty' "${cfg:-/etc/sing-box/config.json}" 2>/dev/null)
    [ -n "$ctl" ] || return 1
    case "$ctl" in
        0.0.0.0:*|:*|\[::\]:*) ctl="127.0.0.1:${ctl##*:}" ;;
    esac
    echo "http://$ctl"
}

pm_urlenc() { printf '%s' "$1" | sed 's/%/%25/g; s/:/%3A/g; s#/#%2F#g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g; s/#/%23/g'; }
pm_urldec() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"; }

# Имя сервера из ссылки: фрагмент после #, без символов, ломающих CSV
pm_link_name() {
    local frag="${1##*#}"
    [ "$frag" = "$1" ] && frag="${1%%\?*}" && frag="${frag##*@}"
    pm_urldec "$frag" | tr -d ',|"\r\n'
}

# Задержка через Clash API: api tag url → мс или -1
pm_delay() {
    local r
    r=$(curl -s -m $((PM_TIMEOUT / 1000 + 3)) "$1/proxies/$2/delay?timeout=$PM_TIMEOUT&url=$(pm_urlenc "$3")" \
        | jq -r '.delay // -1' 2>/dev/null)
    echo "${r:--1}"
}

# Метка цели проверки по URL
pm_target_label() {
    case "$1" in
        *149.154.167.51*) echo "Telegram DC2" ;;
        *149.154.167.91*) echo "Telegram DC4" ;;
        *youtube.com*) echo "youtube.com" ;;
        *) local h="${1#*://}"; echo "${h%%/*}" ;;
    esac
}
