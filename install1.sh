#!/usr/bin/env bash
set -euo pipefail

# Режимы:
#   install.sh            -> STAGING (тестовые сертификаты, acme-staging.json)
#   install.sh --prod     -> PROD (боевые сертификаты, acme.json)
#   install.sh --update   -> обновление образов/контейнеров без смены настроек

DOMAIN_BASE="autmatization-bot.ru"
SITE_DOMAIN="$DOMAIN_BASE"
N8N_DOMAIN="n8n.$DOMAIN_BASE"
SUPABASE_DOMAIN="supabase.$DOMAIN_BASE"
STUDIO_DOMAIN="studio.supabase.$DOMAIN_BASE"
TRAEFIK_DOMAIN="traefik.$DOMAIN_BASE"
SERVER_IP=$(curl -s ifconfig.me || echo "")
LETSENCRYPT_EMAIL="ppcdolar@gmail.com"

PROJECT_NAME="project"
PROJECT_DIR="$HOME/project"
SUPABASE_DIR="$PROJECT_DIR/supabase"
SUPABASE_DOCKER_DIR="$SUPABASE_DIR/docker"
TRAEFIK_DIR="$PROJECT_DIR/traefik"
LE_DIR="$PROJECT_DIR/letsencrypt"

BASE_COMPOSE="$PROJECT_DIR/base.compose.yml"
SUPA_TRAEFIK_OVERRIDE="$PROJECT_DIR/supabase.traefik.override.yml"
SUPA_DISABLE_SITE_OVERRIDE="$PROJECT_DIR/supabase.disable-site.override.yml"

MODE="staging"
[[ "${1:-}" == "--update" ]] && MODE="update"
[[ "${1:-}" == "--prod"   ]] && MODE="prod"

msg(){ echo -e "$*"; }
gen_secret(){ openssl rand -base64 48 | tr -d '\n'; }
gen_hex(){ openssl rand -hex 32; }

wait_https_ready() {
  local domain="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-5}"
  msg "⏳ Жду доступности https://${domain} ..."
  for ((i=1;i<=tries;i++)); do
    if curl -k -sS -o /dev/null -w "%{http_code}" "https://${domain}" | grep -Eq '^(200|301|302|401|403)$'; then
      msg "✅ HTTP(S) доступен на https://${domain}"
      return 0
    fi
    sleep "$sleep_s"
  done
  msg "❌ Не дождался ответа от https://${domain}"
  return 1
}

check_cert_issuer() {
  local domain="$1"
  local expect_staging="$2" # "yes"|"no"
  local issuer
  issuer=$(openssl s_client -connect "${domain}:443" -servername "${domain}" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
  [[ -z "$issuer" ]] && { msg "⚠️  Не удалось прочитать сертификат для ${domain}"; return 1; }
  msg "🔎 Issuer для ${domain}: ${issuer}"
  if [[ "$expect_staging" == "yes" ]]; then
    echo "$issuer" | grep -qi "Fake LE" && { msg "✅ STAGING сертификат (issuer содержит 'Fake LE')"; return 0; }
    msg "❌ Ожидался STAGING сертификат (issuer 'Fake LE')"; return 1
  else
    echo "$issuer" | grep -qi "Let's Encrypt" && ! echo "$issuer" | grep -qi "Fake LE" && { msg "✅ PROD сертификат Let's Encrypt"; return 0; }
    msg "❌ Ожидался PROD сертификат Let's Encrypt (не 'Fake LE')"; return 1
  fi
}

compose_down() {
  docker compose \
    --env-file "$SUPABASE_DOCKER_DIR/.env" \
    -f "$SUPABASE_DOCKER_DIR/docker-compose.yml" \
    -f "$BASE_COMPOSE" \
    -f "$SUPA_TRAEFIK_OVERRIDE" \
    -f "$SUPA_DISABLE_SITE_OVERRIDE" \
    --project-name "$PROJECT_NAME" down --remove-orphans || true
}

compose_pull() {
  docker compose \
    --env-file "$SUPABASE_DOCKER_DIR/.env" \
    -f "$SUPABASE_DOCKER_DIR/docker-compose.yml" \
    -f "$BASE_COMPOSE" \
    -f "$SUPA_TRAEFIK_OVERRIDE" \
    -f "$SUPA_DISABLE_SITE_OVERRIDE" \
    --project-name "$PROJECT_NAME" pull
}

compose_up() {
  docker compose \
    --env-file "$SUPABASE_DOCKER_DIR/.env" \
    -f "$SUPABASE_DOCKER_DIR/docker-compose.yml" \
    -f "$BASE_COMPOSE" \
    -f "$SUPA_TRAEFIK_OVERRIDE" \
    -f "$SUPA_DISABLE_SITE_OVERRIDE" \
    --project-name "$PROJECT_NAME" up -d --build
}

# ---------- UPDATE ----------
if [[ "$MODE" == "update" ]]; then
  msg "🔄 Обновление (единый проект: $PROJECT_NAME)..."
  [[ ! -d "$PROJECT_DIR" ]] && { msg "❌ $PROJECT_DIR не найден. Сначала установка."; exit 1; }
  [[ ! -d "$SUPABASE_DOCKER_DIR" ]] && { msg "❌ $SUPABASE_DOCKER_DIR не найден. Сначала установка."; exit 1; }

  (docker network ls --format '{{.Name}}' | grep -q "^traefik-net$") || docker network create traefik-net
  compose_down
  compose_pull
  compose_up
  msg "✅ Обновление завершено."
  exit 0
fi

# ---------- INSTALL ----------
msg "📁 Установка в: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR" "$SUPABASE_DOCKER_DIR" "$TRAEFIK_DIR" "$LE_DIR"

msg "📦 Обновляем систему…"
sudo apt update && sudo apt upgrade -y

# Git + jq для sparse-checkout и диагностики
msg "🔧 Устанавливаю git и jq…"
sudo apt-get update -y
sudo apt-get install -y git jq

# Docker / Compose
if ! command -v docker >/dev/null 2>&1; then
  msg "🐳 Ставлю Docker/Compose…"
  sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/sharekeyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
fi

# DNS sanity
if [[ -n "$SERVER_IP" ]]; then
  msg "🔍 Проверяю DNS → $SERVER_IP"
  for DOMAIN in $SITE_DOMAIN $N8N_DOMAIN $SUPABASE_DOMAIN $STUDIO_DOMAIN $TRAEFIK_DOMAIN; do
    DNS_IP=$(dig +short "$DOMAIN" | tail -n1)
    [[ "$DNS_IP" != "$SERVER_IP" ]] && { msg "❌ $DOMAIN → $DNS_IP (ожидалось $SERVER_IP)"; exit 1; }
    msg "✅ $DOMAIN → $SERVER_IP"
  done
else
  msg "⚠️ Не получил внешний IP, пропускаю строгую проверку DNS."
fi

# ---------- КЛОНИРОВАНИЕ SUPABASE (sparse-checkout только папки docker) ----------
if [ -d "$SUPABASE_DOCKER_DIR" ] && [ -f "$SUPABASE_DOCKER_DIR/docker-compose.yml" ]; then
  msg "ℹ️ Найдена папка $SUPABASE_DOCKER_DIR и файл docker-compose.yml — пропускаю загрузку."
else
  msg "⬇️ Загружаю только папку docker из репозитория supabase (sparse checkout)…"
  rm -rf "$SUPABASE_DIR"
  git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase.git "$SUPABASE_DIR"
  ( cd "$SUPABASE_DIR" && git sparse-checkout set docker )
  if [ ! -f "$SUPABASE_DOCKER_DIR/docker-compose.yml" ]; then
    msg "❌ Не найден $SUPABASE_DOCKER_DIR/docker-compose.yml после клонирования."
    msg "   Проверь соединение с GitHub или попробуй позже."
    exit 1
  fi
fi

# Traefik config (staging/prod)
ACME_FILE="acme.json"; CASERVER_LINE=""; EXPECT_STAGING="no"
if [[ "$MODE" == "staging" ]]; then
  ACME_FILE="acme-staging.json"
  CASERVER_LINE="      caServer: https://acme-staging-v02.api.letsencrypt.org/directory"
  EXPECT_STAGING="yes"
  msg "🧪 STAGING сертификаты (лимитов нет)"
else
  msg "🔐 PROD сертификаты Let's Encrypt"
fi
STORAGE_PATH="/letsencrypt/${ACME_FILE}"

cat > "$TRAEFIK_DIR/traefik.yml" <<EOF
api:
  dashboard: true
entryPoints:
  web: { address: ":80" }
  websecure: { address: ":443" }
providers:
  docker:
    exposedByDefault: false
certificatesResolvers:
  letsencrypt:
    acme:
      email: $LETSENCRYPT_EMAIL
      storage: $STORAGE_PATH
$CASERVER_LINE
      httpChallenge:
        entryPoint: web
EOF

# acme file
[[ -f "$LE_DIR/$ACME_FILE" ]] || { touch "$LE_DIR/$ACME_FILE"; chmod 600 "$LE_DIR/$ACME_FILE"; }

# сеть
(docker network ls --format '{{.Name}}' | grep -q "^traefik-net$") || docker network create traefik-net

# ---------- БАЗОВЫЙ COMPOSE (Traefik + Site + n8n) ----------
cat > "$BASE_COMPOSE" <<EOF
name: $PROJECT_NAME
networks:
  traefik-net:
    external: true
services:
  traefik:
    image: traefik:v3.1
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --log.level=INFO
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --api.dashboard=true
    ports:
      - 80:80
      - 443:443
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./letsencrypt/${ACME_FILE}:${STORAGE_PATH}
    labels:
      - traefik.enable=true
      - traefik.http.routers.traefik-dashboard.rule=Host(\`$TRAEFIK_DOMAIN\`)
      - traefik.http.routers.traefik-dashboard.entrypoints=websecure
      - traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt
      - traefik.http.routers.traefik-dashboard.service=api@internal
      - traefik.docker.network=traefik-net
    networks: [traefik-net]
    restart: unless-stopped

  site:
    build: ./site
    depends_on: [traefik]
    labels:
      - traefik.enable=true
      - traefik.http.routers.site.rule=Host(\`$SITE_DOMAIN\`)
      - traefik.http.routers.site.entrypoints=websecure
      - traefik.http.routers.site.tls.certresolver=letsencrypt
      - traefik.http.services.site.loadbalancer.server.port=80
      - traefik.docker.network=traefik-net
    networks: [traefik-net]
    restart: unless-stopped

  n8n:
    image: n8nio/n8n:latest
    depends_on: [traefik]
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '\n')
      - GENERIC_TIMEZONE=Europe/Amsterdam
      - N8N_HOST=$N8N_DOMAIN
      - N8N_PROTOCOL=https
    volumes:
      - ./n8n/data:/home/node/.n8n
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(\`$N8N_DOMAIN\`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=letsencrypt
      - traefik.http.services.n8n.loadbalancer.server.port=5678
      - traefik.docker.network=traefik-net
    networks: [traefik-net]
    restart: unless-stopped
EOF

# ---------- OVERRIDE для Supabase: сеть + Traefik-лейблы на kong и studio ----------
cat > "$SUPA_TRAEFIK_OVERRIDE" <<EOF
name: $PROJECT_NAME
networks:
  traefik-net:
    external: true
services:
  kong:
    networks: [traefik-net]
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase.rule=Host(\`$SUPABASE_DOMAIN\`)
      - traefik.http.routers.supabase.entrypoints=websecure
      - traefik.http.routers.supabase.tls.certresolver=letsencrypt
      - traefik.http.services.supabase.loadbalancer.server.port=8000
      - traefik.docker.network=traefik-net
  studio:
    networks: [traefik-net]
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-studio.rule=Host(\`$STUDIO_DOMAIN\`)
      - traefik.http.routers.supabase-studio.entrypoints=websecure
      - traefik.http.routers.supabase-studio.tls.certresolver=letsencrypt
      - traefik.http.services.supabase-studio.loadbalancer.server.port=3000
      - traefik.docker.network=traefik-net
EOF

# ---------- Отключаем supabase/site (у них свой service site с локальной сборкой) ----------
cat > "$SUPA_DISABLE_SITE_OVERRIDE" <<'EOF'
name: project
services:
  site:
    profiles: ["disabled"]
    image: busybox
    build: null
EOF

# ---------- Сайт (статичка) ----------
mkdir -p "$PROJECT_DIR/site"
cat > "$PROJECT_DIR/site/Dockerfile" <<'EOF'
FROM nginx:stable-alpine
COPY index.html /usr/share/nginx/html/index.html
EOF
cat > "$PROJECT_DIR/site/index.html" <<EOF
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Automation Bot</title></head>
<body>
  <h1>Automation Bot — сайт работает</h1>
  <ul>
    <li><a href="https://$SUPABASE_DOMAIN">Supabase</a></li>
    <li><a href="https://$N8N_DOMAIN">n8n</a></li>
    <li><a href="https://$TRAEFIK_DOMAIN">Traefik Dashboard</a></li>
  </ul>
</body>
</html>
EOF

# ---------- Supabase .env ----------
SUP_ENV_FILE="$SUPABASE_DOCKER_DIR/.env"
mkdir -p "$SUPABASE_DOCKER_DIR"

if [[ ! -f "$SUP_ENV_FILE" ]]; then
  msg "🔐 Генерирую .env для Supabase…"
  cat > "$SUP_ENV_FILE" <<EOF
# --- Core Postgres ---
POSTGRES_PASSWORD=$(gen_hex)
POSTGRES_USER=postgres
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432

# --- URLs ---
SITE_URL=https://$SUPABASE_DOMAIN
SUPABASE_PUBLIC_URL=https://$SUPABASE_DOMAIN
API_EXTERNAL_URL=https://$SUPABASE_DOMAIN
ADDITIONAL_REDIRECT_URLS=https://$N8N_DOMAIN

# --- Auth / JWT ---
JWT_SECRET=$(gen_secret)
JWT_EXPIRY=3600
ANON_KEY=$(gen_secret)
SERVICE_ROLE_KEY=$(gen_secret)
ENABLE_EMAIL_SIGNUP=true
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
ENABLE_EMAIL_AUTOCONFIRM=false
DISABLE_SIGNUP=false

# --- Mailer paths ---
MAILER_URLPATHS_CONFIRMATION=/auth/confirm
MAILER_URLPATHS_RECOVERY=/auth/recover
MAILER_URLPATHS_INVITE=/auth/invite
MAILER_URLPATHS_EMAIL_CHANGE=/auth/change

# --- Kong ports ---
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

# --- Studio defaults ---
STUDIO_DEFAULT_ORGANIZATION=Default Organization
STUDIO_DEFAULT_PROJECT=Default Project

# --- Misc keys ---
VAULT_ENC_KEY=$(gen_secret)
LOGFLARE_PUBLIC_ACCESS_TOKEN=$(gen_secret)
LOGFLARE_PRIVATE_ACCESS_TOKEN=$(gen_secret)

# --- PostgREST ---
PGRST_DB_SCHEMAS=public
FUNCTIONS_VERIFY_JWT=true

# --- Docker socket ---
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# --- Imgproxy ---
IMGPROXY_ENABLE_WEBP_DETECTION=true

# --- PgBouncer (pooler) ---
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_TENANT_ID=default
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=20

# --- Dashboard (legacy) ---
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=$(gen_secret)
SECRET_KEY_BASE=$(gen_secret)

# --- SMTP ---
SMTP_HOST=smtp.$DOMAIN_BASE
SMTP_PORT=587
SMTP_USER=no-reply@$DOMAIN_BASE
SMTP_PASS=$(gen_secret)
SMTP_ADMIN_EMAIL=admin@$DOMAIN_BASE
SMTP_SENDER_NAME=Supabase
EOF
  chmod 600 "$SUP_ENV_FILE"
else
  msg "ℹ️ .env для Supabase уже существует — дополняю недостающие ключи."
  add_kv() { grep -q "^$1=" "$SUP_ENV_FILE" || echo "$1=$2" >> "$SUP_ENV_FILE"; }
  add_kv DOCKER_SOCKET_LOCATION "/var/run/docker.sock"
  add_kv SITE_URL "https://$SUPABASE_DOMAIN"
  add_kv KONG_HTTP_PORT "8000"
  add_kv KONG_HTTPS_PORT "8443"
  add_kv ENABLE_ANONYMOUS_USERS "false"
  add_kv STUDIO_DEFAULT_ORGANIZATION "Default Organization"
  add_kv STUDIO_DEFAULT_PROJECT "Default Project"
  add_kv LOGFLARE_PUBLIC_ACCESS_TOKEN "$(gen_secret)"
  add_kv LOGFLARE_PRIVATE_ACCESS_TOKEN "$(gen_secret)"
  add_kv POOLER_PROXY_PORT_TRANSACTION "6543"
  add_kv POOLER_TENANT_ID "default"
  add_kv POOLER_DEFAULT_POOL_SIZE "20"
  add_kv POOLER_MAX_CLIENT_CONN "100"
  add_kv POOLER_DB_POOL_SIZE "20"
fi

# ---------- Единый запуск (один проект) ----------
# Проверка на наличие основного файла Supabase
if [ ! -f "$SUPABASE_DOCKER_DIR/docker-compose.yml" ]; then
  msg "❌ $SUPABASE_DOCKER_DIR/docker-compose.yml не найден. Установка Supabase невозможна."
  exit 1
fi

# Останавливаем старые остатки одного и того же проекта (если были)
compose_down
# Тянем образы и стартуем ВСЁ одной командой и одним project-name
compose_pull
compose_up

# ---------- Автопроверка HTTPS/issuer ----------
set +e
overall_ok=0
EXPECT_STAGING="$([[ "$MODE" == "prod" ]] && echo "no" || echo "yes")"

for d in "$SITE_DOMAIN" "$N8N_DOMAIN" "$TRAEFIK_DOMAIN" "$SUPABASE_DOMAIN" "$STUDIO_DOMAIN"; do
  if wait_https_ready "$d" 60 5; then
    if check_cert_issuer "$d" "$EXPECT_STAGING"; then
      msg "✅ ${d}: всё ок."
    else
      msg "⚠️  ${d}: HTTPS есть, но issuer не совпал с режимом."
      overall_ok=1
    fi
  else
    msg "❌ ${d}: не дождались готовности HTTPS."
    overall_ok=1
  fi
done
set -e

echo
if [[ "$MODE" == "staging" ]]; then
  echo "🧪 STAGING завершён. Серты: $LE_DIR/acme-staging.json"
  echo "Переключиться на прод:  bash \"$0\" --prod"
else
  echo "✅ PROD завершён. Серты: $LE_DIR/acme.json"
  echo "Для апдейтов:          bash \"$0\" --update"
fi

exit $overall_ok
