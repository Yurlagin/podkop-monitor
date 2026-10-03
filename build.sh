#!/bin/sh
# Сборка podkop-monitor_<версия>_all.ipk без OpenWrt SDK (пакет из одних скриптов).
# Использование: ./build.sh [владелец/репозиторий]   (по умолчанию — из git remote origin)
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
REPO=${1:-$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}
[ -n "$REPO" ] || { echo "Укажите репозиторий: ./build.sh owner/podkop-monitor" >&2; exit 1; }

B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
mkdir -p "$B/data" "$B/control" dist
cp -R files/. "$B/data/"
echo "$VERSION" > "$B/data/usr/libexec/podkop-monitor/VERSION"
sed -i.bak "s#@REPO@#$REPO#" "$B/data/etc/config/podkop-monitor" && rm "$B/data/etc/config/podkop-monitor.bak"
find "$B/data" -name .DS_Store -delete

SIZE=$(du -sk "$B/data" | cut -f1)
sed "s#@VERSION@#$VERSION#; s#@REPO@#$REPO#; s#@SIZE@#$((SIZE * 1024))#" control/control > "$B/control/control"
cp control/conffiles control/postinst control/prerm control/postrm "$B/control/"
echo 2.0 > "$B/debian-binary"

# владелец root:root, без macOS-метаданных
if tar --version 2>/dev/null | grep -q GNU; then
	T="tar --format=ustar --owner=0 --group=0 --numeric-owner --sort=name"
else
	export COPYFILE_DISABLE=1
	T="tar --format ustar --uid 0 --gid 0 --uname root --gname root --no-mac-metadata"
fi
(cd "$B/data" && $T -czf ../data.tar.gz .)
(cd "$B/control" && $T -czf ../control.tar.gz .)
OUT="dist/podkop-monitor_${VERSION}_all.ipk"
(cd "$B" && $T -czf - ./debian-binary ./control.tar.gz ./data.tar.gz) > "$OUT"
echo "$OUT ($REPO)"
