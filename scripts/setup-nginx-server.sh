#!/usr/bin/env bash
set -eo pipefail
source "$(pwd)/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 7 ]]; then
  error "Usage: $0 <domain> <C> <ST> <L> <O> <OU> <CN>"
fi

# --- Require not root privileges --------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0"
fi

# --- Check Docker and Compose availability -----------------------------------
for cmd in docker "docker compose" ufw openssl; do
  if ! $cmd version &>/dev/null; then error "Missing dependency: $cmd"; fi
done

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
DN_C="$2"
DN_ST="$3"
DN_L="$4"
DN_O="$5"
DN_OU="$6"
DN_CN="$7"
NETWORK_NAME="internal_net"

COMPOSE_DIR="$HOME/Projects/projects/nginx"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
NGINX_CONF="$COMPOSE_DIR/nginx.conf"

CONF_DIR="$COMPOSE_DIR/conf.d"
DEFAULT_CONF="$CONF_DIR/default.conf"
HOME_CONF="$CONF_DIR/home.conf"
SSL_INC="$CONF_DIR/ssl.inc"

SUBDOMAINS_DIR="$COMPOSE_DIR/subdomains"

HTML_DIR="$COMPOSE_DIR/html"
HTML_FILE="$HTML_DIR/index.html"

CERTS_DIR="$HOME/Projects/projects/certs"
ROOT_KEY="$CERTS_DIR/root-ca.key"
ROOT_CRT="$CERTS_DIR/root-ca.crt"
ROOT_CNF="$CERTS_DIR/root-ca.cnf"
ROOT_SRL="$CERTS_DIR/root-ca.srl"
DOMAIN_KEY="$CERTS_DIR/$DOMAIN.key"
DOMAIN_CSR="$CERTS_DIR/$DOMAIN.csr"
DOMAIN_CRT="$CERTS_DIR/$DOMAIN.crt"
DOMAIN_CNF="$CERTS_DIR/$DOMAIN.cnf"
CACERTS_PEM="$CERTS_DIR/cacerts.pem"
FULLCHAIN_PEM="$CERTS_DIR/fullchain.pem"
PRIVKEY_PEM="$CERTS_DIR/privkey.pem"
CERT_SYM="$CERTS_DIR/cert.pem"
KEY_SYM="$CERTS_DIR/key.pem"

DNS_SH="$HOME/Projects/projects/dns/dns.sh"

# --- Ensure directories exist ------------------------------------------------
mkdir -p "$COMPOSE_DIR" "$CONF_DIR" "$SUBDOMAINS_DIR" "$HTML_DIR" "$CERTS_DIR"

# --- load dns ip -------------------------------------------------------------
source "$DNS_SH" 

# --- Create Root CA (once) ---------------------------------------------------
if [[ ! -f "$ROOT_KEY" || ! -f "$ROOT_CRT" ]]; then
  log "Creating $ROOT_CNF..."
  write "$ROOT_CNF" "
    [ req ]
    default_bits       = 4096
    prompt             = no
    default_md         = sha256
    x509_extensions    = v3_ca
    distinguished_name = dn

    [ dn ]
    C  = $DN_C
    ST = $DN_ST
    L  = $DN_L
    O  = $DN_O
    OU = $DN_OU
    CN = $DN_CN

    [ v3_ca ]
    basicConstraints = critical, CA:true, pathlen:0
    keyUsage         = critical, keyCertSign, cRLSign
    subjectKeyIdentifier = hash
    authorityKeyIdentifier = keyid:always"

  openssl req -x509 -new -nodes -sha256 -days 3650 -newkey rsa:4096 -keyout "$ROOT_KEY" -out "$ROOT_CRT" -config "$ROOT_CNF"

  sudo install -m 0644 "$ROOT_CRT" /usr/local/share/ca-certificates/nginx-root-ca.crt
  sudo update-ca-certificates
fi

# --- Create wildcard + apex leaf cert (if missing) ---------------------------
if [[ ! -f "$DOMAIN_CRT" || ! -f "$DOMAIN_KEY" ]]; then
  log "Creating $DOMAIN_CNF..."
  write "$DOMAIN_CNF" "
    [req]
    default_bits = 3072
    prompt = no
    default_md = sha256
    distinguished_name = dn
    req_extensions = v3_req

    [dn]
    C  = $DN_C
    ST = $DN_ST
    L  = $DN_L
    O  = $DN_O
    OU = $DN_OU
    CN = *.$DOMAIN

    [v3_req]
    subjectAltName = @alt
    keyUsage = critical, digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth

    [alt]
    DNS.1 = $DOMAIN
    DNS.2 = *.$DOMAIN
    DNS.3 = *.infra.$DOMAIN"

  openssl req -new -newkey rsa:3072 -nodes \
    -keyout "$DOMAIN_KEY" -out "$DOMAIN_CSR" -config "$DOMAIN_CNF"

  openssl x509 -req -in "$DOMAIN_CSR" \
    -CA "$ROOT_CRT" -CAkey "$ROOT_KEY" -CAcreateserial -CAserial "$ROOT_SRL" \
    -out "$DOMAIN_CRT" -days 825 -sha256 \
    -extensions v3_req -extfile "$DOMAIN_CNF"

  cp -f "$ROOT_CRT" "$CACERTS_PEM"
  cat "$DOMAIN_CRT" "$ROOT_CRT" > "$FULLCHAIN_PEM"
  cp -f "$DOMAIN_KEY" "$PRIVKEY_PEM"

  ln -sf "$(basename "$FULLCHAIN_PEM")" "$CERT_SYM"
  ln -sf "$(basename "$PRIVKEY_PEM")"   "$KEY_SYM"

  chmod 644 "$CACERTS_PEM" "$FULLCHAIN_PEM"
  chmod 600 "$ROOT_KEY" "$DOMAIN_KEY" "$FULLCHAIN_PEM" "$PRIVKEY_PEM" || true
fi

# --- docker-compose.yml -------------------------------------------------------
log "Creating $COMPOSE_FILE..."
write "$COMPOSE_FILE" "
  services:
    nginx:
      image: nginx:1.28-alpine3.21
      container_name: nginx
      restart: unless-stopped
      ports:
        - '80:80'
        - '443:443'
      volumes:
        - ./nginx.conf:/etc/nginx/nginx.conf:ro
        - ./conf.d:/etc/nginx/conf.d:ro
        - ./subdomains:/etc/nginx/subdomains:ro
        - $CERTS_DIR:/etc/nginx/certs:ro
        - ./html:/usr/share/nginx/html:ro
      healthcheck:
        test: ['CMD-SHELL', 'nginx -t']
        interval: 30s
        timeout: 5s
        retries: 3
      dns:
        - $DNS_IP
      networks:
        - $NETWORK_NAME

  networks:
    $NETWORK_NAME:
      external: true"

# --- nginx.conf (top-level) ---------------------------------------------------
log "Creating $NGINX_CONF..."
write "$NGINX_CONF" "
  user  nginx;
  worker_processes  auto;

  events {
    worker_connections  1024;
  }

  http {
    # Core & logging
    sendfile        on;
    tcp_nopush      on;
    types_hash_max_size 4096;

    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    access_log  /var/log/nginx/access.log;
    error_log   /var/log/nginx/error.log;

    keepalive_timeout 65;

    # Name resolution for docker-compose service names (adjust if not using Docker)
    resolver         127.0.0.11 valid=30s ipv6=off;
    resolver_timeout 5s;

    # WebSocket upgrade helper (used in your Rancher vhost)
    map \$http_upgrade \$connection_upgrade {
      default upgrade;
      ''      close;
    }

    # Compression
    gzip on;
    gzip_types
      text/plain
      text/css
      application/json
      application/javascript
      application/xml
      text/xml;

    # Load site/vhost configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/subdomains/*.conf;
  }"

log "Creating $SSL_INC..."
write "$SSL_INC" "
  ssl_certificate     /etc/nginx/certs/$DOMAIN.crt;
  ssl_certificate_key /etc/nginx/certs/$DOMAIN.key;

  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;

  # Enable when clients trust your CA/cert
  # add_header Strict-Transport-Security \"max-age=31536000\" always;"

# --- Default site (serves local HTML on root host) ----------------------------
write "$HOME_CONF" "
  # HTTP -> HTTPS redirect for default host
  server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name infra.$DOMAIN *.infra.$DOMAIN;
    location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
    return 301 https://\$host\$request_uri;
  }

  # HTTPS default site
  server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name infra.$DOMAIN;

    include /etc/nginx/conf.d/ssl.inc;
    client_max_body_size 200M;

    root   /usr/share/nginx/html;
    index  index.html;

    location / {
      try_files \$uri \$uri/ =404;
    }

    location /certs/ {
      alias /etc/nginx/certs/;
      autoindex off;
      types { application/x-x509-ca-cert crt; }
    }
  }"

write "$HTML_FILE" "
  <!DOCTYPE html>
  <html lang='en'>
  <head>
  <meta charset='UTF-8' />
  <title>Services · infra.$DOMAIN</title>
  <meta name='viewport' content='width=device-width, initial-scale=1' />
  <style>
    :root{
      --bg:#0b1020; --panel:#0f162b; --panel-2:#0c1326; --muted:#9aa4b2; --text:#f6f8fc;
      --brand:#6aa6ff; --accent:#22c55e; --border:#22304a; --danger:#ef4444; --warning:#f59e0b; --ring:#335fdd;
    }
    @media (prefers-color-scheme: light) {
      :root{ --bg:#f5f7fb; --panel:#ffffff; --panel-2:#f6f8fc; --text:#0b1020; --muted:#516074; --border:#d6deea; --ring:#2563eb; }
    }
    *{ box-sizing:border-box }
    html,body{ height:100% }
    body{
      margin:0; color:var(--text);
      background:
        radial-gradient(1100px 700px at 15% -10%, #18244a44, transparent),
        radial-gradient(900px 500px at 100% 0%, #0f1a3644, transparent),
        var(--bg);
      font:16px/1.55 system-ui,-apple-system,'Segoe UI',Roboto,Ubuntu,Cantarell,'Noto Sans',Arial,sans-serif;
    }

    .topbar{
      position:sticky; top:0; z-index:50; backdrop-filter: blur(6px);
      background:color-mix(in oklab, var(--bg) 80%, transparent);
      border-bottom:1px solid var(--border);
    }
    .container{ max-width:1100px; margin:0 auto; padding:1rem 1.25rem }
    .row{ display:flex; gap:1rem; align-items:center; justify-content:space-between; flex-wrap:wrap }
    h1{ margin:0; font-size:1.35rem; letter-spacing:.2px }
    .muted{ color:var(--muted) }
    .sub{ font-size:.92rem }
    .search{
      flex:1 1 280px; display:flex; align-items:center; gap:.5rem; background:var(--panel-2);
      border:1px solid var(--border); border-radius:.65rem; padding:.5rem .7rem;
    }
    .search input{ flex:1; border:0; background:transparent; color:inherit; outline:none; font-size:.95rem }

    main{ max-width:1100px; margin:1rem auto 2rem; padding:0 1.25rem; display:grid; gap:1.25rem }
    section.block{
      border:1px solid var(--border); background:linear-gradient(180deg, var(--panel), var(--panel-2));
      border-radius:.85rem; padding:1rem;
    }

    .cards{ display:grid; gap:.85rem; grid-template-columns:repeat(auto-fit, minmax(500px, 1fr)); padding:0; margin:0; list-style:none }
    .card{
      border:1px solid var(--border); border-radius:.75rem; background:linear-gradient(180deg,#121a31,#0f1527);
      display:flex; flex-direction:column; padding:.85rem .9rem; gap:.6rem;
      transition: transform .15s ease, border-color .15s ease, box-shadow .15s ease;
    }
    @media (prefers-color-scheme: light){ .card{ background:linear-gradient(180deg,#ffffff,#f7f9ff) } }
    .card:hover{ transform:translateY(-2px); border-color:#345; box-shadow:0 10px 28px rgba(0,0,0,.25) }
    .card-head{ display:flex; align-items:center; justify-content:space-between; gap:.6rem }
    .card-title{ font-weight:700; font-size:1.02rem; margin:0 }
    .card-sub{ color:var(--muted); font-size:.9rem; margin-top:-.25rem }
    .badge{ display:inline-block; font-size:.75rem; padding:.15rem .45rem; border:1px solid var(--border); border-radius:.45rem; color:var(--muted) }
    .card-actions{ display:flex; gap:.5rem; flex-wrap:wrap }
    .card-actions .btn.link{ text-decoration:none }

    .panel{
      border:1px solid var(--border); border-radius:.6rem; background:var(--panel-2);
      max-height:0; overflow:hidden; transition:max-height .25s ease;
    }
    .panel-inner{
      padding:.75rem .8rem; display:grid; gap:.6rem;
      max-height:280px; overflow:auto; /* own scroll when tall */
    }
    .card.open .panel{ max-height:360px } /* enough to reveal inner's 280px + paddings */

    .actions{ display:flex; gap:.5rem; flex-wrap:wrap; margin:.2rem 0 .2rem }
    .btn{
      appearance:none; border:1px solid var(--border); background:var(--panel-2); color:var(--text);
      padding:.5rem .75rem; border-radius:.55rem; cursor:pointer; font-weight:600; font-size:.95rem;
      transition: transform .05s ease, background .15s ease, border-color .15s ease;
    }
    .btn:hover{ transform:translateY(-1px) }
    .btn.primary{ border-color:#3b82f6; background:linear-gradient(180deg,#2563eb,#1d4ed8); color:#fff; box-shadow:inset 0 1px 0 rgba(255,255,255,.15) }
    .btn.success{ border-color:#16a34a; background:linear-gradient(180deg,#22c55e,#16a34a); color:#06110b }
    .btn.ghost{ background:transparent }

    code,pre{ font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,'Liberation Mono',Consolas,monospace }
    pre{
      position:relative; margin:.6rem 0 0; padding:.8rem .9rem; background:#0c1328; border:1px solid var(--border);
      border-radius:.6rem; overflow:auto;
    }
    @media (prefers-color-scheme: light){ pre{ background:#f1f5ff } }
    .copy-btn{
      position:absolute; top:.5rem; right:.5rem; font-size:.8rem; padding:.35rem .6rem;
      background:#0f1a36; color:var(--text); border:1px solid var(--border); border-radius:.45rem; cursor:pointer;
    }
    .copy-btn.ok{ background:linear-gradient(180deg,#22c55e,#16a34a); border-color:#16a34a; color:#06110b }

    details{ border:1px solid var(--border); border-radius:.6rem; padding:.75rem; background:#0c1328 }
    details+details{ margin-top:.5rem }
    @media (prefers-color-scheme: light){ details{ background:#eef4ff } }
    summary{ cursor:pointer; user-select:none; color:var(--brand); font-weight:700 }

    .grid-2{ display:grid; gap:1rem; grid-template-columns:1fr }
    @media (min-width:900px){ .grid-2{ grid-template-columns:1.25fr .75fr } }

    .toast{
      position:fixed; left:50%; bottom:18px; transform:translateX(-50%); z-index:100;
      background:linear-gradient(180deg,#1a2a50,#132244); color:#e9f2ff; border:1px solid var(--ring);
      padding:.6rem .8rem; border-radius:.6rem; box-shadow:0 6px 24px rgba(0,0,0,.35); opacity:0; pointer-events:none;
      transition: opacity .15s ease, transform .15s ease;
    }
    .toast.show{ opacity:1; transform:translateX(-50%) translateY(-4px) }
    @media (prefers-reduced-motion: reduce){ .card,.btn,.toast{ transition:none } }
  </style>
  </head>
  <body>

    <div class='topbar'>
      <div class='container'>
        <div class='row'>
          <div>
            <h1>Internal Services</h1>
            <div class='sub muted'>served on <strong>infra.$DOMAIN</strong></div>
          </div>
          <label class='search' title='Filter services (name or host)'>
            <svg width='18' height='18' viewBox='0 0 24 24' fill='none' aria-hidden='true'><path d='m21 21-4.2-4.2M10.5 18a7.5 7.5 0 1 1 0-15 7.5 7.5 0 0 1 0 15Z' stroke='currentColor' stroke-width='2' stroke-linecap='round'/></svg>
            <input id='filter' type='search' placeholder='Search services…' autocomplete='off' />
          </label>
        </div>
      </div>
    </div>

    <main>
      <section class='block' aria-labelledby='svc-h'>
        <h2 id='svc-h' style='margin:.25rem 0 1rem'>Available Services</h2>

        <ul class='cards' id='services'>
          <!-- Generic service template -->
          <li>
            <article class='card' data-name='gitea' data-host='gitea.infra.$DOMAIN' data-url='https://gitea.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Gitea</div>
                  <div class='card-sub'>gitea.infra.$DOMAIN</div>
                </div>
                <div class='badge'>Git hosting</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://gitea.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://gitea.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Lightweight Git service with issues, PRs, and CI integrations.</p>
                </div>
              </div>
            </article>
          </li>

          <li>
            <article class='card' data-name='grafana' data-host='grafana.infra.$DOMAIN' data-url='https://grafana.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Grafana</div>
                  <div class='card-sub'>grafana.infra.$DOMAIN</div>
                </div>
                <div class='badge'>Dashboards</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://grafana.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://grafana.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Visualize metrics and logs across environments.</p>
                </div>
              </div>
            </article>
          </li>

          <li>
            <article class='card' data-name='jenkins' data-host='jenkins.infra.$DOMAIN' data-url='https://jenkins.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Jenkins</div>
                  <div class='card-sub'>jenkins.infra.$DOMAIN</div>
                </div>
                <div class='badge'>CI/CD</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://jenkins.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://jenkins.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Build, test, and deploy pipelines.</p>
                </div>
              </div>
            </article>
          </li>

          <li>
            <article class='card' data-name='keycloak' data-host='keycloak.infra.$DOMAIN' data-url='https://keycloak.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Keycloak</div>
                  <div class='card-sub'>keycloak.infra.$DOMAIN</div>
                </div>
                <div class='badge'>Auth</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://keycloak.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://keycloak.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Identity and access management (OIDC/SAML).</p>
                </div>
              </div>
            </article>
          </li>

          <li>
            <article class='card' data-name='nexus' data-host='nexus.infra.$DOMAIN' data-url='https://nexus.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Nexus Repository</div>
                  <div class='card-sub'>nexus.infra.$DOMAIN</div>
                </div>
                <div class='badge'>Artifacts</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://nexus.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://nexus.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Hosted Maven/NPM/Docker registries.</p>
                </div>
              </div>
            </article>
          </li>

          <!-- Registry card: shows Docker catalogs on expand -->
          <li>
            <article class='card' id='registry-card' data-name='registry' data-host='nexus.infra.$DOMAIN' data-url='https://nexus.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Registry (Docker)</div>
                  <div class='card-sub'>nexus.infra.$DOMAIN/v2/_catalog</div>
                </div>
                <div class='badge'>Images</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://nexus.infra.$DOMAIN/' target='_blank' rel='noopener'>Open Nexus</a>
                <button class='btn ghost copy-inline' data-copy='https://nexus.infra.$DOMAIN/v2/_catalog'>Copy API URL</button>
                <button class='btn' id='reload-catalogs' type='button'>Reload catalogs</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Catalog of repositories exposed by the Docker registry API:</p>
                  <div id='catalog-status' class='muted'>Loading…</div>
                  <ul id='catalog-list' style='margin:.25rem 0 0; padding-left:1.1rem'></ul>
                </div>
              </div>
            </article>
          </li>

          <li>
            <article class='card' data-name='prometheus' data-host='prometheus.infra.$DOMAIN' data-url='https://prometheus.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Prometheus</div>
                  <div class='card-sub'>prometheus.infra.$DOMAIN</div>
                </div>
                <div class='badge'>Metrics</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://prometheus.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://prometheus.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Time-series metrics and alerting.</p>
                </div>
              </div>
            </article>
          </li>

          <li>
            <article class='card' data-name='rancher' data-host='rancher.infra.$DOMAIN' data-url='https://rancher.infra.$DOMAIN/'>
              <div class='card-head'>
                <div>
                  <div class='card-title'>Rancher</div>
                  <div class='card-sub'>rancher.infra.$DOMAIN</div>
                </div>
                <div class='badge'>K8s mgmt</div>
              </div>
              <div class='card-actions'>
                <a class='btn link' href='https://rancher.infra.$DOMAIN/' target='_blank' rel='noopener'>Open</a>
                <button class='btn ghost copy-inline' data-copy='https://rancher.infra.$DOMAIN/'>Copy URL</button>
              </div>
              <div class='panel' aria-hidden='true'>
                <div class='panel-inner'>
                  <p class='muted'>Manage clusters, apps, and access.</p>
                </div>
              </div>
            </article>
          </li>
        </ul>
      </section>

      <!-- Trust Root CA -->
      <section class='block' aria-labelledby='ca-h'>
        <div class='grid-2'>
          <div>
            <h2 id='ca-h' style='margin:.25rem 0 .6rem'>Trust the $DOMAIN Root CA</h2>
            <p class='muted' style='margin:.25rem 0 1rem'>
              Our services use a private CA. Install it so browsers, Docker, JVM tools, and CLIs trust <span class='badge'>*.infra.$DOMAIN</span>.
            </p>
            <div class='actions'>
              <a class='btn primary' href='/certs/root-ca.crt' download>⬇ Download root-ca.crt</a>
              <button class='btn' data-copy='curl'>Copy curl</button>
              <button class='btn' data-copy='wget'>Copy wget</button>
              <button class='btn ghost' data-copy='sha'>Copy sha256 verify</button>
            </div>

            <details>
              <summary>Linux (Ubuntu/Debian) – system trust</summary>
              <pre><button class='copy-btn' title='Copy'>Copy</button><code>sudo install -m 0644 root-ca.crt /usr/local/share/ca-certificates/nginx-root-ca.crt
  sudo update-ca-certificates</code></pre>
            </details>

            <details>
              <summary>macOS – System Keychain</summary>
              <pre><button class='copy-btn' title='Copy'>Copy</button><code>sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root-ca.crt</code></pre>
            </details>

            <details>
              <summary>Windows (PowerShell as Admin)</summary>
              <pre><button class='copy-btn' title='Copy'>Copy</button><code>Import-Certificate -FilePath .\root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root</code></pre>
            </details>

            <!-- Split: Java and Gradle -->
            <details>
              <summary>Java – JVM truststore (user)</summary>
              <pre><button class='copy-btn' title='Copy'>Copy</button><code>keytool -importcert -alias nginx-root -keystore ~/.jvm-truststore.jks -storepass changeit -file root-ca.crt -noprompt</code></pre>
              <p class='muted'>Creates a user-scoped truststore containing the Root CA.</p>
            </details>

            <details>
              <summary>Gradle – use the truststore</summary>
              <pre><button class='copy-btn' title='Copy'>Copy</button><code>printf '%s\n' 'org.gradle.jvmargs=-Djavax.net.ssl.trustStore=/home/\$USER/.jvm-truststore.jks -Djavax.net.ssl.trustStorePassword=changeit' >> ~/.gradle/gradle.properties
  ./gradlew --stop && ./gradlew build</code></pre>
            </details>
          </div>

          <div>
            <details open>
              <summary>Why this is needed</summary>
              <p class='muted'>Public CAs rarely fit internal/private networks. Installing the Root CA lets your system validate our TLS certs.</p>
            </details>

            <details>
              <summary>Troubleshooting</summary>
              <ul class='muted' style='margin:0; padding-left:1.1rem'>
                <li><strong>Browser ‘Not secure’</strong> → import CA into OS trust; restart browser.</li>
                <li><strong>Gradle PKIX path building failed</strong> → ensure Gradle points to the truststore and restart the daemon.</li>
                <li><strong>CLI still fails</strong> → confirm download and <code>sha256sum root-ca.crt</code>.</li>
              </ul>
            </details>
          </div>
        </div>
      </section>

      <footer class='muted' style='text-align:center; font-size:.9rem'>
        Need help? Ping <span class='badge'>server.taila5359d.ts.net</span> on Tailscale.
      </footer>
    </main>

    <div id='toast' class='toast' role='status' aria-live='polite'>Copied to clipboard</div>

  <script>
    // domain helpers
    const DOMAIN = (document.title.split('·')[1] || '$DOMAIN').trim() || '$DOMAIN';
    const cmds = {
      curl: \`curl -fsSLk https://${DOMAIN}/certs/root-ca.crt -o root-ca.crt\`,
      wget: \`wget --no-check-certificate https://${DOMAIN}/certs/root-ca.crt -O root-ca.crt\`,
      sha: \`sha256sum root-ca.crt || shasum -a 256 root-ca.crt\`
    };

    // filter
    const filter = document.getElementById('filter');
    const svcList = document.getElementById('services');
    if (filter && svcList){
      filter.addEventListener('input', () => {
        const q = filter.value.toLowerCase().trim();
        svcList.querySelectorAll('.card').forEach(card => {
          const name = (card.dataset.name || '').toLowerCase();
          const host = (card.dataset.host || '').toLowerCase();
          card.parentElement.style.display = (name.includes(q) || host.includes(q)) ? '' : 'none';
        });
      });
    }

    // toast
    const toast = document.getElementById('toast');
    function showToast(msg='Copied to clipboard'){
      if (!toast) return;
      toast.textContent = msg;
      toast.classList.add('show');
      setTimeout(()=>toast.classList.remove('show'), 1200);
    }

    // copy helper
    async function copyText(text){
      try{
        if (navigator.clipboard && window.isSecureContext){
          await navigator.clipboard.writeText(text);
        }else{
          const ta = document.createElement('textarea');
          ta.value = text; ta.style.position='fixed'; ta.style.left='-9999px';
          document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove();
        }
        showToast();
        return true;
      }catch(e){
        alert('Copy failed. Select manually:\n\n' + text);
        return false;
      }
    }

    // wire inline copy buttons
    document.querySelectorAll('[data-copy]').forEach(b=>{
      b.addEventListener('click', async ()=>{
        const key = b.dataset.copy;
        const text = cmds[key] || key;
        const ok = await copyText(text);
        if (ok){ b.classList.add('success'); setTimeout(()=>b.classList.remove('success'), 900); }
      });
    });

    // add copy buttons for all pre blocks
    document.querySelectorAll('pre').forEach(pre=>{
      let btn = pre.querySelector('.copy-btn');
      if (!btn){
        btn = document.createElement('button');
        btn.className='copy-btn'; btn.type='button'; btn.textContent='Copy';
        pre.appendChild(btn);
      }
      const code = pre.querySelector('code');
      btn.addEventListener('click', async ()=>{
        const text = (code ? code.innerText : pre.innerText).trimEnd();
        if (await copyText(text)){ btn.classList.add('ok'); setTimeout(()=>btn.classList.remove('ok'), 900); }
      });
    });

    // card expand/collapse with smooth scroll to panel
    document.querySelectorAll('.card').forEach(card=>{
      const panel = card.querySelector('.panel');
      const head  = card.querySelector('.card-head');
      const url   = card.dataset.url;

      // Clicking the head opens the service
      head.addEventListener('click', ev=>{
        ev.stopPropagation();
        if (url) window.open(url, '_blank','noopener');
      });

      // Keep inline "Open" buttons working
      card.querySelectorAll('.btn.link').forEach(a=>{
        a.addEventListener('click', ev => ev.stopPropagation());
      });

      if (panel){
        panel.addEventListener('click', ev => ev.stopPropagation());
      }

      // Whole card toggles details when clicking outside head/links
      card.addEventListener('click', ev=>{
        if (ev.target.closest('.card-head') || ev.target.closest('.btn.link')) return;
        const isOpen = card.classList.contains('open');
        document.querySelectorAll('.card.open').forEach(c=>{ if(c!==card) c.classList.remove('open'); });
        card.classList.toggle('open', !isOpen);
        if (!isOpen && panel){
          setTimeout(()=>{
            panel.scrollTop=0;
            panel.scrollIntoView({behavior:'smooth', block:'nearest'});
          },100);
        }
      });
    });

    // Registry catalogs loader
    async function loadCatalogs(){
      const status = document.getElementById('catalog-status');
      const list = document.getElementById('catalog-list');
      if (!status || !list) return;

      status.textContent = 'Loading…';
      list.innerHTML = '';

      try{
        const url = \`https://nexus.${DOMAIN}/v2/_catalog\`;
        const res = await fetch(url, { credentials:'include' });
        if (!res.ok){ throw new Error(\`HTTP \${res.status}\`); }
        const data = await res.json();
        const repos = (data && data.repositories) ? data.repositories : [];
        if (!repos.length){
          status.textContent = 'No repositories found.';
          return;
        }
        status.textContent = '';
        repos.sort().forEach(name=>{
          const li = document.createElement('li');
          const a = document.createElement('a');
          a.href = \`https://nexus.${DOMAIN}/repository/\${encodeURIComponent(name)}/\`;
          a.textContent = name;
          a.target = '_blank'; a.rel = 'noopener';
          li.appendChild(a);
          list.appendChild(li);
        });
      }catch(err){
        status.textContent = 'Failed to load catalogs (CORS/auth?). Try opening Nexus and ensuring the Docker registry is reachable.';
      }
    }

    // auto-load catalogs on first expand of the Registry card
    const registryCard = document.getElementById('registry-card');
    let catalogsLoaded = false;
    if (registryCard){
      registryCard.addEventListener('click', ()=>{
        if (!catalogsLoaded && registryCard.classList.contains('open')){
          catalogsLoaded = true;
          loadCatalogs();
        }
      });
      const reloadBtn = document.getElementById('reload-catalogs');
      if (reloadBtn){
        reloadBtn.addEventListener('click', ev=>{
          ev.stopPropagation();
          catalogsLoaded = true;
          loadCatalogs();
        });
      }
    }
  </script>
  </body>
  </html>"

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Bring up Nginx -----------------------------------------------------------
log "Validating docker-compose.yml"
docker compose -f "$COMPOSE_FILE" config >/dev/null

log "Starting Nginx container"
( cd "$COMPOSE_DIR" && docker compose up -d )

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 80, 443)"
sudo ufw allow 80/tcp  || true
sudo ufw allow 443/tcp || true
sudo ufw reload || true
sudo ufw --force enable

# --- Summary -----------------------------------------------------------------
info "Nginx reverse proxy is up."
info "Default site: https://$DOMAIN (serves /usr/share/nginx/html/index.html)"
info "Put your vhost files under: $SUBDOMAINS_DIR (each as its own .conf)"
info "Join your app containers to the '$NETWORK_NAME' network so 'proxy_pass http://service:port;' works."