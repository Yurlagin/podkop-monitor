#!/bin/sh
# Установка/обновление podkop-monitor из последнего релиза на GitHub.
#   wget -O /tmp/install.sh https://github.com/@REPO@/releases/latest/download/install.sh && sh /tmp/install.sh
# (в репозитории @REPO@ — заглушка, в релиз попадает файл с подставленным именем)
set -e

REPO="@REPO@"

[ -f /etc/openwrt_release ] || { echo "Это не OpenWrt"; exit 1; }
command -v opkg >/dev/null || { echo "Нужен opkg (OpenWrt 24.10 и раньше); OpenWrt 25.x с apk пока не поддерживается"; exit 1; }
opkg list-installed | grep -q '^podkop ' || { echo "Сначала установите podkop: https://github.com/itdoginfo/podkop"; exit 1; }

echo "Ищу последний релиз $REPO…"
URL=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" \
    | jsonfilter -e '@.assets[*].browser_download_url' | grep '\.ipk$' | head -1)
[ -n "$URL" ] || { echo "Не нашёл .ipk в последнем релизе"; exit 1; }

IPK=/tmp/podkop-monitor.ipk
echo "Скачиваю $URL"
wget -qO "$IPK" "$URL"
opkg install "$IPK"
rm -f "$IPK"

echo
echo "Готово. Откройте LuCI → Services → Podkop Monitor."
echo "Чтобы видеть все серверы VPN-провайдера, укажите ссылку на подписку во вкладке «Настройки»."
