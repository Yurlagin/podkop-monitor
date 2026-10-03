# Xray-JSON подписки (Remnawave, NetHaven и т.п.) → выходы sing-box для замеров.
# Результат: { servers: ["N|имя|тип|хост"], links: ["N|ссылка"], outbounds: [...] }, теги выходов — sN-out.
# Ссылки (vless:// и hysteria2://) нужны, чтобы по кнопке заменить устаревшую ссылку в podkop.
# Берём конфиги с одним прокси-выходом (пропускаем «Автовыбор»), XHTTP пропускаем — sing-box его не умеет.
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

[ .[]
  | { name: (.remarks | explode | map(select(. != 44 and . != 124 and . != 34)) | implode),
      obs: [ .outbounds[] | select(.protocol == "vless" or .protocol == "hysteria") ] }
  | select((.obs | length) == 1)
  | select((.obs[0].streamSettings.network // "tcp") | IN("tcp", "raw", "ws", "hysteria"))
  | { name, ob: .obs[0] } ]
| to_entries
| map(.key += 1)
| {
    links: map(. as $e | "\($e.key)|\($e.value.ob | link($e.value.name))"),
    servers: map("\(.key)|\(.value.name)|\(.value.ob.protocol)/\(.value.ob.streamSettings.network)|\(.value.ob.settings.vnext[0].address // .value.ob.settings.address)"),
    outbounds: map(. as $e | $e.value.ob | outbound("s\($e.key)-out"))
  }
