#!/bin/sh
# Сверка ссылок в секциях podkop с одноимёнными серверами подписки: провайдер меняет адреса, ключи, SNI —
# а в podkop остаётся старая ссылка. Результат: $PM_RUN/drift.csv
#   section,key,name,status,fields
#   status: same — совпадает; differs — отличается; missing — в подписке нет;
#           unsupported — есть в подписке, но мониторинг не может его проверить (fields — причина);
#           renamed — под этим именем в подписке нет, но есть сервер с теми же параметрами подключения
#                     (провайдер его переименовал); fields — «имя|старое|новое» для каждого кандидата
#   Для missing в fields может быть подсказка «похож|имя|что отличается» — тот же адрес, другие параметры,
#   или «дубль|имя|» — такой же сервер уже стоит в этой секции под другим именем.
#   fields: «поле|было|стало» через «;» (для UUID/пароля и ключа значения не пишем)
# Сравниваются только параметры подключения. Не сравниваются: отпечаток (utls) и ALPN — их часто меняют сознательно;
# short id Reality — подписка выдаёт случайный из списка, который принимает сервер, при каждом запросе свой.

. /usr/libexec/podkop-monitor/common.sh

OUT=$PM_RUN/drift.csv
[ -s "$PM_STATE/sb.json" ] && [ -s "$PM_STATE/servers.tsv" ] || { rm -f "$OUT"; exit 0; }

TMP=$PM_RUN/drift.$$
trap '[ -n "$TMP" ] && rm -f "$TMP".*' EXIT

# выходы podkop по ссылкам из его конфига — тем же кодом, что и сам podkop
(
    for f in constants helpers logging sing_box_config_manager sing_box_config_facade; do
        . /usr/lib/podkop/$f.sh
    done
    log() { :; }

    one() { # section key link
        local ob
        ob=$(sing_box_cf_add_proxy_outbound '{"outbounds":[]}' x "$3" "" 2>/dev/null | jq -c '.outbounds[0] // empty' 2>/dev/null)
        [ -n "$ob" ] && jq -cn --arg sec "$1" --arg key "$2" --arg name "$(pm_link_name "$3")" --argjson ob "$ob" \
            '{sec: $sec, key: $key, name: $name, ob: $ob}'
    }
    section() {
        local sec="$1" ctype ptype links link i=0
        config_get ctype "$sec" connection_type
        [ "$ctype" = proxy ] || return 0
        config_get ptype "$sec" proxy_config_type
        case "$ptype" in
            urltest|selector)
                config_get links "$sec" "${ptype}_proxy_links"
                for link in $links; do i=$((i + 1)); one "$sec" "$i" "$link"; done ;;
            url)
                config_get link "$sec" proxy_string
                one "$sec" 1 "$link" ;;
        esac
    }
    config_load podkop
    config_foreach section section
) > $TMP.podkop

# имя сервера подписки → его выход
awk -F'|' '{ printf "{\"name\":\"%s\",\"tag\":\"s%s-out\"}\n", $2, $1 }' "$PM_STATE/servers.tsv" > $TMP.names

# пропущенные записи подписки: имя → причина
awk -F'|' '{ gsub(/"/, "", $0); printf "{\"name\":\"%s\",\"why\":\"%s\"}\n", $1, $2 }' "$PM_STATE/skipped.tsv" 2>/dev/null > $TMP.skip

jq -rn --slurpfile pk $TMP.podkop --slurpfile nm $TMP.names --slurpfile sb "$PM_STATE/sb.json" --slurpfile sk $TMP.skip '
  def norm: {
      "адрес": .server, "порт": (.server_port | tostring), "UUID/пароль": (.uuid // .password),
      "flow": (.flow // ""), "SNI": (.tls.server_name // ""),
      "защита": (if .tls.reality.enabled then "reality" elif .tls.enabled then "tls" else "none" end),
      "ключ Reality": (.tls.reality.public_key // ""),
      "транспорт": (.transport.type // "tcp"), "путь": (.transport.path // ""),
      "host": (.transport.headers.Host // "")
    };
  def clean: tostring | split(",") | join(" ") | split(";") | join(" ") | split("|") | join(" ");
  # что отличается: «поле|было|стало»; UUID и ключ — без значений
  def diff($a; $b): [ $a | keys_unsorted[] | select($a[.] != $b[.])
      | if IN("UUID/пароль", "ключ Reality") then "\(.)||" else "\(.)|\($a[.] | clean)|\($b[.] | clean)" end ];
  ($sb[0].outbounds | map({ (.tag): . }) | add) as $obs
  | ($nm | map({ name, n: ($obs[.tag] | norm) })) as $subs
  | ($nm | map({ (.name): $obs[.tag] }) | add // {}) as $byname
  | $pk[]
  | . as $p
  | ($p.ob | norm) as $a
  | $byname[$p.name] as $s
  | ([ $sk[] | select(.name == $p.name) ] | .[0]) as $skip
  | if $s == null and $skip != null then [$p.sec, $p.key, $p.name, "unsupported", $skip.why]
    elif $s == null then
      # имена, которые уже стоят в этой секции, — не кандидаты (это дубль, а не переименование)
      ([ $pk[] | select(.sec == $p.sec) | .name ]) as $taken
      | [ $subs[] | select(.n == $a) | .name ] as $sameall
      | [ $sameall[] | . as $x | select($taken | index($x) | not) ] as $same
      | if ($same | length) > 0 then
          [$p.sec, $p.key, $p.name, "renamed", ($same | map("имя|\($p.name | clean)|\(clean)") | join(";"))]
        elif ($sameall | length) > 0 then
          [$p.sec, $p.key, $p.name, "missing", ($sameall | map("дубль|\(clean)|") | join(";"))]
        else
          [ $subs[] | select(.n["адрес"] == $a["адрес"] and .n["порт"] == $a["порт"])
            | "похож|\(.name | clean)|\(diff($a; .n) | map(split("|")[0]) | join(" "))" ] as $like
          | [$p.sec, $p.key, $p.name, "missing", ($like | .[0:3] | join(";"))]
        end
    else
      diff($a; $s | norm) as $d
      | [$p.sec, $p.key, $p.name, (if ($d | length) == 0 then "same" else "differs" end), ($d | join(";"))]
    end
  | join(",")' > $TMP.out && mv $TMP.out "$OUT"
