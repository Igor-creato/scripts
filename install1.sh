#!/usr/bin/env bash
set -euo pipefail

#
# install.sh — установка или обновление стека:
# Traefik (Let's Encrypt) + сайт (nginx) + n8n + Supabase (self-hosted)
#

# ---------- ПАРАМЕТРЫ ----------
DOMAIN_BASE="autmatization-bot.ru"
SITE_DOMAIN="$DOMAIN_BASE"
N8N_DOMAIN="n8n.$DOMAIN_BASE"
SUPABASE_DOMAIN="supabase.$DOMAIN_BASE"
STUDIO_DOMAIN="studio.supabase.$DOMAIN_BASE"
TRAEFIK_DOMAIN="traefik.$DOMAIN_BASE"
SERVER_IP=$(curl -s ifconfig.me)
LETSENCRYPT_EMAIL="ppcdolar@gmail.com"

PROJECT_DIR="$HOME/project"
SUPABASE_DIR="$PROJECT_DIR/supabase"
SUPABASE_DOCKER_DIR="$SUPABASE_DIR/docker"
TRAEFIK_DIR="$PROJECT_DIR/traefik"
LE_DIR="$PROJECT_DIR/letsencrypt"

# ---------- ОПРЕДЕЛЕНИЕ РЕЖИМА ----------
MODE="staging" # по умолчанию тестовые сертификаты

if [[ "${1:-}" == "--update" ]]; then
    MODE="update"
elif [[ "${1:-}" == "--prod" ]]; then
    MODE="prod"
fi

# ---------- РЕЖИМ ОБНОВЛЕНИЯ ----------
if [[ "$MODE" == "update" ]]; then
    echo "🔄 Режим обновления..."

    if ! docker network ls --format '{{.Name}}' | grep -q "^traefik-net$"; then
        echo "❌ Сеть traefik-net не найдена — нужно сначала выполнить полную установку."
        exit 1
    fi

    if [ ! -d "$PROJECT_DIR" ] || [ ! -d "$SUPABASE_DOCKER_DIR" ]; then
        echo "❌ Проект не найден — сначала выполните установку."
        exit 1
    fi

    echo "📦 Обновляю Traefik, сайт и n8n..."
    cd "$PROJECT_DIR"
    docker compose pull
    docker compose up -d --build

    echo "📦 Обновляю Supabase..."
    cd "$SUPABASE_DOCKER_DIR"
    docker compose pull
    docker compose up -d

    echo "✅ Обновление завершено."
    exit 0
fi

# ---------- ПОЛНАЯ УСТАНОВКА ----------
echo "Проект будет установлен в: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR" "$SUPABASE_DOCKER_DIR" "$TRAEFIK_DIR" "$LE_DIR"

# ---------- ОБНОВЛЕНИЕ СИСТЕМЫ ----------
echo "📦 Обновляем систему..."
sudo apt update && sudo apt upgrade -y

# ---------- ПРОВЕРКА DNS ----------
echo "🔍 Проверяем DNS записи..."
for DOMAIN in $DOMAIN_BASE $N8N_DOMAIN $SUPABASE_DOMAIN $STUDIO_DOMAIN $TRAEFIK_DOMAIN; do
  DNS_IP=$(dig +short $DOMAIN | tail -n1)
  if [ "$DNS_IP" != "$SERVER_IP" ]; then
    echo "❌ $DOMAIN указывает на $DNS_IP, а не на $SERVER_IP"
    exit 1
  else
    echo "✅ $DOMAIN указывает на $SERVER_IP"
  fi
done

# ---------- УСТАНОВКА DOCKER ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "Устанавливаю Docker..."
  sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
else
  echo "Docker уже установлен."
fi

# ---------- КЛОНИРОВАНИЕ SUPABASE ----------
if [ ! -d "$SUPABASE_DIR" ]; then
  echo "Клонирую официальный Supabase репозиторий..."
  git clone https://github.com/supabase/supabase.git "$SUPABASE_DIR"
else
  echo "Supabase репозиторий уже присутствует."
fi

# ---------- СОЗДАНИЕ КОНФИГА TRAEFIK ----------
echo "Создаю конфигурацию Traefik..."

CASERVER_LINE=""
if [[ "$MODE" == "staging" ]]; then
  CASERVER_LINE="      caServer: https://acme-staging-v02.api.letsencrypt.org/directory"
  echo "⚠️  Используется тестовый CA сервер Let's Encrypt (staging)"
elif [[ "$MODE" == "prod" ]]; then
  echo "✅ Используется боевой Let's Encrypt (production)"
fi

cat > "$TRAEFIK_DIR/traefik.yml" <<EOF
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
providers:
  docker:
    exposedByDefault: false
certificatesResolvers:
  letsencrypt:
    acme:
      email: $LETSENCRYPT_EMAIL
      storage: /letsencrypt/acme.json
$CASERVER_LINE
      httpChallenge:
        entryPoint: web
EOF

# ---------- СОХРАНЕНИЕ ACME.JSON ----------
if [ ! -f "$LE_DIR/acme.json" ]; then
  echo "Создаю новый acme.json..."
  touch "$LE_DIR/acme.json"
  chmod 600 "$LE_DIR/acme.json"
else
  echo "Использую существующий acme.json (сертификаты не будут пересозданы)"
fi

# ---------- СОЗДАНИЕ СЕТИ TRAEFIK-NET ----------
if ! docker network ls --format '{{.Name}}' | grep -q "^traefik-net$"; then
  echo "Создаю сеть traefik-net..."
  docker network create traefik-net
else
  echo "Сеть traefik-net уже существует."
fi

# ---------- DOCKER-COMPOSE ДЛЯ TRAEFIK + SITE + N8N + DASHBOARD ----------
echo "Создаю docker-compose.yml..."
cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
version: "3.9"

# --- ИСПРАВЛЕНИЕ ---
# Определяем traefik-net как сеть по умолчанию для всех сервисов в этом файле.
# Это гарантирует, что Traefik и другие сервисы находятся в одной сети.
networks:
  default:
    name: traefik-net
    external: true

services:
  traefik:
    image: traefik:v3.1
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--log.level=INFO"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--api.dashboard=true"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/traefik.yml:/etc/traefik/traefik.yml:ro"
      - "./letsencrypt/acme.json:/letsencrypt/acme.json"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`$TRAEFIK_DOMAIN\`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
    # Ключ 'networks' здесь больше не нужен, т.к. используется сеть по умолчанию.
    restart: unless-stopped

  site:
    build: ./site
    depends_on:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.site.rule=Host(\`$SITE_DOMAIN\`)"
      - "traefik.http.routers.site.entrypoints=websecure"
      - "traefik.http.routers.site.tls.certresolver=letsencrypt"
      - "traefik.http.services.site.loadbalancer.server.port=80"
    restart: unless-stopped

  n8n:
    image: n8nio/n8n:latest
    depends_on:
      - traefik
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
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`$N8N_DOMAIN\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    restart: unless-stopped
EOF

# ---------- ПРОСТОЙ САЙТ ----------
mkdir -p "$PROJECT_DIR/site"
cat > "$PROJECT_DIR/site/Dockerfile" <<EOF
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

# ---------- .ENV ДЛЯ SUPABASE ----------
SUP_ENV_FILE="$SUPABASE_DOCKER_DIR/.env"
mkdir -p "$SUPABASE_DOCKER_DIR"

gen_secret() { openssl rand -base64 48 | tr -d '\n'; }
gen_hex() { openssl rand -hex 32; }

if [ ! -f "$SUP_ENV_FILE" ]; then
  echo "Генерирую .env для Supabase..."
  cat > "$SUP_ENV_FILE" <<EOF
POSTGRES_PASSWORD=$(gen_hex)
POSTGRES_USER=postgres
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432
JWT_SECRET=$(gen_secret)
JWT_EXPIRY=3600
ANON_KEY=$(gen_secret)
SERVICE_ROLE_KEY=$(gen_secret)
VAULT_ENC_KEY=$(gen_secret)
LOGFLARE_PUBLIC_ACCESS_TOKEN=$(gen_secret)
LOGFLARE_PRIVATE_ACCESS_TOKEN=$(gen_secret)
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=$(gen_secret)
SECRET_KEY_BASE=$(gen_secret)
SMTP_HOST=smtp.$DOMAIN_BASE
SMTP_PORT=587
SMTP_USER=no-reply@$DOMAIN_BASE
SMTP_PASS=$(gen_secret)
SMTP_ADMIN_EMAIL=admin@$DOMAIN_BASE
SMTP_SENDER_NAME=Supabase
SUPABASE_PUBLIC_URL=https://$SUPABASE_DOMAIN
API_EXTERNAL_URL=https://$SUPABASE_DOMAIN
ADDITIONAL_REDIRECT_URLS=https://$N8N_DOMAIN
MAILER_URLPATHS_CONFIRMATION=/auth/confirm
MAILER_URLPATHS_RECOVERY=/auth/recover
MAILER_URLPATHS_INVITE=/auth/invite
MAILER_URLPATHS_EMAIL_CHANGE=/auth/change
ENABLE_EMAIL_SIGNUP=true
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
ENABLE_EMAIL_AUTOCONFIRM=false
DISABLE_SIGNUP=false
PGRST_DB_SCHEMAS=public
FUNCTIONS_VERIFY_JWT=true
DOCKER_SOCKET_LOCATION=/var/run/docker.sock
IMGPROXY_ENABLE_WEBP_DETECTION=true
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_TENANT_ID=default
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=20
EOF
  chmod 600 "$SUP_ENV_FILE"
else
  echo ".env для Supabase уже существует."
fi

# ---------- OVERRIDE ДЛЯ SUPABASE ----------
cat > "$SUPABASE_DOCKER_DIR/docker-compose.override.yml" <<EOF
version: "3.9"
networks:
  traefik-net:
    external: true
services:
  kong:
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase.rule=Host(\`$SUPABASE_DOMAIN\`)"
      - "traefik.http.routers.supabase.entrypoints=websecure"
      - "traefik.http.routers.supabase.tls.certresolver=letsencrypt"
      - "traefik.http.services.supabase.loadbalancer.server.port=8000"
  studio:
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase-studio.rule=Host(\`$STUDIO_DOMAIN\`)"
      - "traefik.http.routers.supabase-studio.entrypoints=websecure"
      - "traefik.http.routers.supabase-studio.tls.certresolver=letsencrypt"
      - "traefik.http.services.supabase-studio.loadbalancer.server.port=3000"
EOF

# ---------- ЗАПУСК TRAEFIK + SITE + N8N ----------
cd "$PROJECT_DIR"
docker compose pull
docker compose up -d --build

# ---------- ЗАПУСК SUPABASE ----------
cd "$SUPABASE_DOCKER_DIR"
docker compose pull
docker compose up -d

echo "✅ Установка завершена!"
echo "🌐 Traefik Dashboard: https://$TRAEFIK_DOMAIN"