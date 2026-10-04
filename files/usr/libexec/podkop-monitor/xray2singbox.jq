# Xray-JSON подписки (Remnawave, NetHaven и т.п.) → выходы sing-box для замеров.
# Результат: { servers: ["N|имя|тип|хост"], links: ["N|ссылка"], outbounds: [...], yt: [...], skipped: ["имя|причина"] }
# Теги выходов — sN-out; если у сервера YouTube идёт через отдельный выход (правило маршрутизации в записи
# подписки, как у NetHaven: «yt-ru»), он добавляется как sN-yt-out, а в yt — домены, которые на него идут.
# Ссылки (vless:// и hysteria2://) нужны, чтобы по кнопке заменить устаревшую ссылку в podkop.
# Пропускаем: записи с балансировщиком («Автовыбор»), записи без понятного основного выхода и XHTTP
# (sing-box его не умеет) — с причиной в skipped.
def tls_of($s; $ws):
  ($s.tlsSettings // $s.realitySettings // {}) as $t
  | { enabled: true, server_name: $t.serverName }
  + (if ($t.fingerprint // "") != "" then { utls: { enabled: true, fingerprint: $t.fingerprint } } else {} end)
  + (if $s.security == "reality" then { reality: { enabled: true, public_key: $t.publicKey, short_id: ($t.shortId // "") } } else {} end)
  # «Обход замедлений» (WS) приходит с alpn=h3,h2 и так не подключается — для WS ALPN не задаём,
  # для TCP выкидываем h3
  + (if $ws then {} else ([($t.alpn // [])[] | select(. != "h3")] as $a | if ($a | length) > 0 then { alpn: $a } else {} end) end);

def outbound($tag):
  .streamSettings as $s
  | if .protocol == "hysteria" then
      { type: "hysteria2", tag: $tag, server: .settings.address, server_port: .settings.port,
        password: $s.hysteriaSettings.auth,
        tls: { enabled: true, server_name: $s.tlsSettings.serverName, alpn: ($s.tlsSettings.alpn // ["h3"]) } }
    else
      .settings.vnext[0] as $v
      | { type: "vless", tag: $tag, server: $v.address, server_port: $v.port, uuid: $v.users[0].id }
      + (if ($v.users[0].flow // "") != "" then { flow: $v.users[0].flow } else {} end)
      + (if ($s.security // "none") != "none" then { tls: tls_of($s; $s.network == "ws") } else {} end)
      + (if $s.network == "ws" then
           { transport: { type: "ws", path: ($s.wsSettings.path // "/"),
                          headers: { Host: ($s.wsSettings.headers.Host // $s.wsSettings.host // $v.address) } } }
         else {} end)
    end;

# Xray-выход → ссылка в формате, который понимает podkop
def link($name):
  .streamSettings as $s
  | if .protocol == "hysteria" then
      "hysteria2://\($s.hysteriaSettings.auth | @uri)@\(.settings.address):\(.settings.port)?"
      + ([ "sni=\($s.tlsSettings.serverName | @uri)", "alpn=\(($s.tlsSettings.alpn // ["h3"]) | join(",") | @uri)" ] | join("&"))
      + "#\($name | @uri)"
    else
      .settings.vnext[0] as $v
      | ($s.tlsSettings // $s.realitySettings // {}) as $t
      | (if ($s.network // "tcp") == "raw" then "tcp" else ($s.network // "tcp") end) as $net
      | "vless://\($v.users[0].id)@\($v.address):\($v.port)?"
      + ([ "encryption=none",
           (if ($v.users[0].flow // "") != "" then "flow=\($v.users[0].flow)" else empty end),
           "type=\($net)",
           "security=\($s.security // "none")",
           (if $t.serverName then "sni=\($t.serverName | @uri)" else empty end),
           (if $t.fingerprint then "fp=\($t.fingerprint)" else empty end),
           (if $t.publicKey then "pbk=\($t.publicKey | @uri)" else empty end),
           (if $t.shortId then "sid=\($t.shortId)" else empty end),
           ([($t.alpn // [])[] | select(. != "h3" or $net == "quic")] as $a
              | if ($a | length) > 0 and $net != "ws" then "alpn=\($a | join(",") | @uri)" else empty end),
           (if $net == "ws" then "path=\(($s.wsSettings.path // "/") | @uri)" else empty end),
           (if $net == "ws" then "host=\(($s.wsSettings.headers.Host // $s.wsSettings.host // $v.address) | @uri)" else empty end)
         ] | join("&"))
      + "#\($name | @uri)"
    end;

def is_proxy: .protocol == "vless" or .protocol == "hysteria";
def supported: (.streamSettings.network // "tcp") | IN("tcp", "raw", "ws", "hysteria");
def net_name: (.streamSettings.network // "tcp");

# основной выход записи: по тегу «proxy» (так помечают основной выход Xray-клиенты и панели),
# иначе — единственный прокси-выход, иначе — цель последнего правила без условий
def main_outbound:
  [ .outbounds[] | select(is_proxy) ] as $p
  | ([ $p[] | select(.tag == "proxy") ] | .[0]) as $tagged
  | ([ .routing.rules[]?
       | select(.outboundTag and ((has("domain") or has("ip") or has("port") or has("protocol")) | not))
       | .outboundTag ] | .[-1]) as $last
  | if $tagged != null then $tagged
    elif ($p | length) == 1 then $p[0]
    elif $last != null then ([ $p[] | select(.tag == $last) ] | .[0])
    else null end;

# правило для YouTube: { tag, domain_suffix, domain, domain_keyword } или null.
# Берём первое правило с доменами YouTube, которое ведёт на прокси-выход (а не block/direct —
# например, NetHaven сначала блокирует QUIC YouTube, а TCP отправляет на отдельный выход «yt-ru»).
def youtube_rule:
  [ .outbounds[] | select(is_proxy) | .tag ] as $ptags
  | [ .routing.rules[]?
    | select(.outboundTag as $t | $ptags | index($t))
    | select((.domain // []) | map(tostring) | any(contains("youtube.com") or contains("googlevideo"))) ]
  | .[0]
  | if . == null then null else
      { tag: .outboundTag,
        domain_suffix: [ .domain[] | tostring | select(startswith("domain:")) | .[7:] ],
        domain: [ .domain[] | tostring | select(startswith("full:")) | .[5:] ],
        domain_keyword: [ .domain[] | tostring | select(startswith("keyword:")) | .[8:] ] }
    end;

[ .[]
  | (.remarks | explode | map(select(. != 44 and . != 124 and . != 34)) | implode) as $name
  | if ((.routing.balancers // []) | length) > 0 or ([ .routing.rules[]? | select(.balancerTag) ] | length) > 0 then
      { name: $name, skip: "несколько серверов с автовыбором" }
    else
      main_outbound as $m
      | if $m == null then { name: $name, skip: "не удалось определить основной выход" }
        elif ($m | supported | not) then { name: $name, skip: "транспорт \($m | net_name) не поддерживается sing-box" }
        else
          youtube_rule as $y
          | (if $y != null and $y.tag != $m.tag then ([ .outbounds[] | select(.tag == $y.tag and is_proxy and supported) ] | .[0]) else null end) as $yo
          | { name: $name, ob: $m, yt: (if $yo then $y + { ob: $yo } else null end) }
        end
    end ]
| (map(select(.skip)) | map("\(.name)|\(.skip)")) as $skipped
| map(select(.skip | not))
| to_entries
| map(.key += 1)
| {
    skipped: $skipped,
    links: map(. as $e | "\($e.key)|\($e.value.ob | link($e.value.name))"),
    servers: map("\(.key)|\(.value.name)|\(.value.ob.protocol)/\(.value.ob.streamSettings.network)|\(.value.ob.settings.vnext[0].address // .value.ob.settings.address)"),
    outbounds: (map(. as $e | $e.value.ob | outbound("s\($e.key)-out"))
                + map(select(.value.yt) | . as $e | $e.value.yt.ob | outbound("s\($e.key)-yt-out"))),
    yt: map(select(.value.yt) | { key, tag: "s\(.key)-yt-out",
            domain_suffix: .value.yt.domain_suffix, domain: .value.yt.domain, domain_keyword: .value.yt.domain_keyword })
  }
