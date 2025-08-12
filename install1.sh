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
TRAEFIK_DIR="$PROJECT_DIR/traefik"
LE_DIR="$PROJECT_DIR/letsencrypt"
N8N_DIR="$PROJECT_DIR/n8n"
SITE_DIR="$PROJECT_DIR/site"

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
    if [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
        echo "❌ Проект не найден — сначала выполните установку."
        exit 1
    fi

    echo "📦 Обновляю весь стек..."
    cd "$PROJECT_DIR"
    docker compose pull
    docker compose up -d --build
    echo "✅ Обновление завершено."
    exit 0
fi

# ---------- ПОЛНАЯ УСТАНОВКА ----------
echo "Проект будет установлен в: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR" "$TRAEFIK_DIR" "$LE_DIR" "$N8N_DIR/data" "$SITE_DIR"

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

# ---------- .ENV ДЛЯ ВСЕГО ПРОЕКТА ----------
ENV_FILE="$PROJECT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Генерирую .env для всего стека..."
  gen_secret() { openssl rand -base64 32 | tr -d '/+=' | head -c 32; }
  gen_hex() { openssl rand -hex 32; }

  cat > "$ENV_FILE" <<EOF
# Supabase
POSTGRES_PASSWORD=$(gen_hex)
POSTGRES_USER=postgres
POSTGRES_DB=postgres
JWT_SECRET=$(gen_secret)
ANON_KEY=$(gen_secret)
SERVICE_ROLE_KEY=$(gen_secret)
SUPABASE_PUBLIC_URL=https://$SUPABASE_DOMAIN
API_EXTERNAL_URL=https://$SUPABASE_DOMAIN
STUDIO_PORT=3000

# n8n
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=$(gen_secret)
GENERIC_TIMEZONE=Europe/Amsterdam
N8N_HOST=$N8N_DOMAIN
N8N_PROTOCOL=https
EOF
  chmod 600 "$ENV_FILE"
else
  echo ".env файл уже существует."
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
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    exposedByDefault: false
    network: traefik-net
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
  echo "Использую существующий acme.json"
fi

# ---------- ПРОСТОЙ САЙТ ----------
cat > "$SITE_DIR/Dockerfile" <<EOF
FROM nginx:stable-alpine
COPY index.html /usr/share/nginx/html/index.html
EOF

cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Automation Bot</title></head>
  <body>
    <h1>Automation Bot — сайт работает</h1>
    <ul>
      <li><a href="https://$STUDIO_DOMAIN">Supabase Studio</a></li>
      <li><a href="https://$N8N_DOMAIN">n8n</a></li>
      <li><a href="https://$TRAEFIK_DOMAIN">Traefik Dashboard</a></li>
    </ul>
  </body>
</html>
EOF

# ---------- ЕДИНЫЙ DOCKER-COMPOSE.YML ----------
echo "Создаю единый docker-compose.yml для всего стека..."
cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
version: "3.9"

networks:
  traefik-net:
    name: traefik-net

volumes:
  db_data:
  storage_data:
  n8n_data:

services:
  # Traefik
  traefik:
    image: traefik:v3.1
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.network=traefik-net"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--log.level=INFO"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/traefik.yml:/etc/traefik/traefik.yml:ro"
      - "./letsencrypt/acme.json:/letsencrypt/acme.json"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
    networks:
      - traefik-net
    restart: unless-stopped

  # Site
  site:
    build: ./site
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.site.rule=Host(\`${SITE_DOMAIN}\`)"
      - "traefik.http.routers.site.entrypoints=websecure"
      - "traefik.http.routers.site.tls.certresolver=letsencrypt"
      - "traefik.http.services.site.loadbalancer.server.port=80"
    networks:
      - traefik-net
    restart: unless-stopped

  # n8n
  n8n:
    image: n8nio/n8n:latest
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - N8N_HOST=\${N8N_HOST}
      - N8N_PROTOCOL=\${N8N_PROTOCOL}
    volumes:
      - "n8n_data:/home/node/.n8n"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - traefik-net
    restart: unless-stopped

  # Supabase DB
  db:
    image: supabase/postgres:15.1.0.117
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - traefik-net
    restart: unless-stopped

  # Supabase API Gateway
  kong:
    image: supabase/kong:2.8.1-20220817
    environment:
      - KONG_DATABASE=off
      - KONG_DECLARATIVE_CONFIG=/var/lib/kong/kong.yml
      - KONG_DNS_ORDER=LAST,A,CNAME
      - KONG_PLUGINS=request-transformer,cors,key-auth,acl
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase-api.rule=Host(\`${SUPABASE_DOMAIN}\`)"
      - "traefik.http.routers.supabase-api.entrypoints=websecure"
      - "traefik.http.routers.supabase-api.tls.certresolver=letsencrypt"
      - "traefik.http.services.supabase-api.loadbalancer.server.port=8000"
    networks:
      - traefik-net
    restart: unless-stopped

  # Supabase Services
  auth:
    image: supabase/gotrue:v2.128.1
    environment:
      - GOTRUE_API_HOST=0.0.0.0
      - GOTRUE_API_PORT=9999
      - GOTRUE_JWT_SECRET=\${JWT_SECRET}
      - GOTRUE_JWT_EXP=3600
      - GOTRUE_SITE_URL=\${SUPABASE_PUBLIC_URL}
      - GOTRUE_URI_SCHEMES=https
      - GOTRUE_DATABASE_URL=postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@db:5432/\${POSTGRES_DB}
    networks:
      - traefik-net
    restart: unless-stopped

  rest:
    image: postgrest/postgrest:v11.2.2
    environment:
      - PGRST_DB_URI=postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@db:5432/\${POSTGRES_DB}
      - PGRST_DB_SCHEMAS=public,storage,graphql_public
      - PGRST_DB_ANON_ROLE=anon
      - PGRST_JWT_SECRET=\${JWT_SECRET}
    networks:
      - traefik-net
    restart: unless-stopped

  realtime:
    image: supabase/realtime:v2.26.1
    environment:
      - REALTIME_POSTGRES_HOST=db
      - REALTIME_POSTGRES_PORT=5432
      - REALTIME_POSTGRES_USER=\${POSTGRES_USER}
      - REALTIME_POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - REALTIME_POSTGRES_DBNAME=\${POSTGRES_DB}
      - REALTIME_PORT=4000
      - REALTIME_JWT_SECRET=\${JWT_SECRET}
    networks:
      - traefik-net
    restart: unless-stopped

  storage-api:
    image: supabase/storage-api:v0.47.0
    environment:
      - STORAGE_DATABASE_URL=postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@db:5432/\${POSTGRES_DB}
      - STORAGE_BACKEND=file
      - FILE_STORAGE_BACKEND_PATH=/var/lib/storage
      - TENANT_ID=stub
      - ANON_KEY=\${ANON_KEY}
      - SERVICE_ROLE_KEY=\${SERVICE_ROLE_KEY}
      - JWT_SECRET=\${JWT_SECRET}
    volumes:
      - storage_data:/var/lib/storage
    networks:
      - traefik-net
    restart: unless-stopped

  # Supabase Studio
  studio:
    image: supabase/studio:20240711-0604
    environment:
      - SUPABASE_PUBLIC_URL=https://\${SUPABASE_DOMAIN}
      - SUPABASE_API_URL=https://\${API_EXTERNAL_URL}
      - SUPABASE_DB_HOST=db
      - SUPABASE_DB_USER=\${POSTGRES_USER}
      - SUPABASE_DB_PASSWORD=\${POSTGRES_PASSWORD}
      - SUPABASE_DB_PORT=5432
      - ANON_KEY=\${ANON_KEY}
      - SERVICE_ROLE_KEY=\${SERVICE_ROLE_KEY}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase-studio.rule=Host(\`${STUDIO_DOMAIN}\`)"
      - "traefik.http.routers.supabase-studio.entrypoints=websecure"
      - "traefik.http.routers.supabase-studio.tls.certresolver=letsencrypt"
      - "traefik.http.services.supabase-studio.loadbalancer.server.port=${STUDIO_PORT}"
    networks:
      - traefik-net
    restart: unless-stopped
EOF

# ---------- ЗАПУСК ВСЕГО СТЕКА ----------
cd "$PROJECT_DIR"
echo "🚀 Запускаю весь стек одним docker-compose..."
docker compose pull
docker compose up -d --build

echo "✅ Установка завершена!"
echo "---"
echo "Доступы:"
echo "🌐 Сайт: https://$SITE_DOMAIN"
echo "🔧 n8n: https://$N8N_DOMAIN (Логин: admin, Пароль в файле .env)"
echo "🚀 Supabase API: https://$SUPABASE_DOMAIN"
echo "🎨 Supabase Studio: https://$STUDIO_DOMAIN"
echo "🚦 Traefik Dashboard: https://$TRAEFIK_DOMAIN"