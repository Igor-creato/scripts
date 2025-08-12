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

    echo "📦 Обновляю все сервисы..."
    cd "$PROJECT_DIR"
    docker compose pull
    docker compose up -d --build

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

# ---------- ПОИСК И КОПИРОВАНИЕ КОНФИГОВ SUPABASE ----------
echo "Ищу конфигурационные файлы Supabase..."

# Ищем docker-compose.yml в различных местах
SUPABASE_COMPOSE_SOURCE=""
for possible_path in \
  "$SUPABASE_DIR/docker/docker-compose.yml" \
  "$SUPABASE_DIR/docker-compose.yml" \
  "$SUPABASE_DIR/supabase/docker/docker-compose.yml" \
  "$SUPABASE_DIR/apps/docker/docker-compose.yml"; do
  if [ -f "$possible_path" ]; then
    SUPABASE_COMPOSE_SOURCE="$possible_path"
    echo "✅ Найден docker-compose.yml в: $possible_path"
    break
  fi
done

if [ -z "$SUPABASE_COMPOSE_SOURCE" ]; then
  echo "⚠️  docker-compose.yml от Supabase не найден, используем встроенную конфигурацию"
else
  echo "📋 Копирую docker-compose.yml из Supabase..."
  cp "$SUPABASE_COMPOSE_SOURCE" "$SUPABASE_DOCKER_DIR/docker-compose.yml"
fi

# ---------- ЕДИНЫЙ DOCKER-COMPOSE ДЛЯ ВСЕХ СЕРВИСОВ ----------
echo "Создаю единый docker-compose.yml..."
cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
version: "3.9"

networks:
  traefik-net:
    external: true
  default:
    name: supabase_network_project

services:
  # ========== TRAEFIK ==========
  traefik:
    image: traefik:v3.1
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=traefik-net"
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
    networks:
      - traefik-net
    restart: unless-stopped

  # ========== САЙТ ==========
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
    networks:
      - traefik-net
    restart: unless-stopped

  # ========== N8N ==========
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
    networks:
      - traefik-net
    restart: unless-stopped

  # ========== SUPABASE СЕРВИСЫ ==========
  # Postgres
  db:
    container_name: supabase-db
    image: supabase/postgres:15.1.0.117
    healthcheck:
      test: pg_isready -U postgres -h localhost
      interval: 5s
      timeout: 5s
      retries: 10
    depends_on:
      - traefik
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
      - -c
      - log_min_messages=fatal
    restart: unless-stopped
    ports:
      - 5432:5432
    environment:
      POSTGRES_HOST: /var/run/postgresql
      PGPORT: 5432
      POSTGRES_PORT: 5432
      PGPASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      PGDATABASE: \${POSTGRES_DB}
      POSTGRES_DB: \${POSTGRES_DB}
      PGUSER: \${POSTGRES_USER}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_INITDB_ARGS: "--auth-host=md5"
    volumes:
      - ./volumes/db/realtime.sql:/docker-entrypoint-initdb.d/migrations/99-realtime.sql:Z
      - ./volumes/db/webhooks.sql:/docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql:Z
      - ./volumes/db/roles.sql:/docker-entrypoint-initdb.d/init-scripts/99-roles.sql:Z
      - ./volumes/db/jwt.sql:/docker-entrypoint-initdb.d/init-scripts/99-jwt.sql:Z
      - ./volumes/db/data:/var/lib/postgresql/data:Z
      - ./volumes/db/logs.sql:/docker-entrypoint-initdb.d/migrations/99-logs.sql:Z
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # Studio
  studio:
    container_name: supabase-studio
    image: supabase/studio:20240326-5e5586d
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:3000/api/profile', (r) => {if (r.statusCode !== 200) throw new Error(r.statusCode)})"]
      timeout: 5s
      interval: 5s
      retries: 3
    depends_on:
      db:
        condition: service_healthy
    environment:
      STUDIO_PG_META_URL: http://meta:8080
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      DEFAULT_ORGANIZATION_NAME: \${STUDIO_DEFAULT_ORGANIZATION}
      DEFAULT_PROJECT_NAME: \${STUDIO_DEFAULT_PROJECT}
      SUPABASE_URL: http://kong:8000
      SUPABASE_PUBLIC_URL: \${SUPABASE_PUBLIC_URL}
      SUPABASE_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_KEY: \${SERVICE_ROLE_KEY}
      LOGFLARE_API_KEY: \${LOGFLARE_API_KEY}
      LOGFLARE_URL: http://analytics:4000
      NEXT_PUBLIC_ENABLE_LOGS: true
      NEXT_ANALYTICS_BACKEND_PROVIDER: postgres
    env_file:
      - ./supabase/docker/.env
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase-studio.rule=Host(\`$STUDIO_DOMAIN\`)"
      - "traefik.http.routers.supabase-studio.entrypoints=websecure"
      - "traefik.http.routers.supabase-studio.tls.certresolver=letsencrypt"
      - "traefik.http.services.supabase-studio.loadbalancer.server.port=3000"
    networks:
      - traefik-net
      - default

  # Kong
  kong:
    container_name: supabase-kong
    image: kong:2.8.1
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /var/lib/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
      KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
    volumes:
      - ./volumes/api/kong.yml:/var/lib/kong/kong.yml:ro
    env_file:
      - ./supabase/docker/.env
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase.rule=Host(\`$SUPABASE_DOMAIN\`)"
      - "traefik.http.routers.supabase.entrypoints=websecure"
      - "traefik.http.routers.supabase.tls.certresolver=letsencrypt"
      - "traefik.http.services.supabase.loadbalancer.server.port=8000"
    networks:
      - traefik-net
      - default

  # Auth
  auth:
    container_name: supabase-auth
    image: supabase/gotrue:v2.143.0
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9999/health"]
      timeout: 5s
      interval: 5s
      retries: 3
    restart: unless-stopped
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: \${API_EXTERNAL_URL}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST}:\${POSTGRES_PORT}/\${POSTGRES_DB}
      GOTRUE_SITE_URL: \${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: \${ADDITIONAL_REDIRECT_URLS}
      GOTRUE_DISABLE_SIGNUP: \${DISABLE_SIGNUP}
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: \${JWT_EXPIRY}
      GOTRUE_JWT_SECRET: \${JWT_SECRET}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: \${ENABLE_EMAIL_SIGNUP}
      GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED: \${ENABLE_ANONYMOUS_USERS}
      GOTRUE_MAILER_AUTOCONFIRM: \${ENABLE_EMAIL_AUTOCONFIRM}
      GOTRUE_SMTP_HOST: \${SMTP_HOST}
      GOTRUE_SMTP_PORT: \${SMTP_PORT}
      GOTRUE_SMTP_USER: \${SMTP_USER}
      GOTRUE_SMTP_PASS: \${SMTP_PASS}
      GOTRUE_SMTP_SENDER_NAME: \${SMTP_SENDER_NAME}
      GOTRUE_MAILER_URLPATHS_INVITE: \${MAILER_URLPATHS_INVITE}
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: \${MAILER_URLPATHS_CONFIRMATION}
      GOTRUE_MAILER_URLPATHS_RECOVERY: \${MAILER_URLPATHS_RECOVERY}
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: \${MAILER_URLPATHS_EMAIL_CHANGE}
      GOTRUE_EXTERNAL_PHONE_ENABLED: \${ENABLE_PHONE_SIGNUP}
      GOTRUE_SMS_AUTOCONFIRM: \${ENABLE_PHONE_AUTOCONFIRM}
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # REST
  rest:
    container_name: supabase-rest
    image: postgrest/postgrest:v12.0.1
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://authenticator:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST}:\${POSTGRES_PORT}/\${POSTGRES_DB}
      PGRST_DB_SCHEMAS: \${PGRST_DB_SCHEMAS}
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: \${JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: \${JWT_SECRET}
      PGRST_APP_SETTINGS_JWT_EXP: \${JWT_EXPIRY}
    command: "postgrest"
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # Realtime
  realtime:
    container_name: supabase-realtime
    image: supabase/realtime:v2.25.50
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "bash", "-c", "printf \\0 > /dev/tcp/localhost/4000"]
      timeout: 5s
      interval: 5s
      retries: 3
    restart: unless-stopped
    environment:
      PORT: 4000
      DB_HOST: \${POSTGRES_HOST}
      DB_PORT: \${POSTGRES_PORT}
      DB_USER: supabase_realtime_admin
      DB_PASSWORD: \${POSTGRES_PASSWORD}
      DB_NAME: \${POSTGRES_DB}
      DB_AFTER_CONNECT_QUERY: 'SET search_path TO _realtime'
      DB_ENC_KEY: supabaserealtimedev
      API_JWT_SECRET: \${JWT_SECRET}
      FLY_ALLOC_ID: fly123
      FLY_APP_NAME: realtime
      SECRET_KEY_BASE: UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq
      ERL_AFLAGS: -proto_dist inet_tcp
      ENABLE_TAILSCALE: "false"
      DNS_NODES: "''"
    env_file:
      - ./supabase/docker/.env
    command: >
      sh -c "/app/bin/migrate && /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)' && /app/bin/server"
    networks:
      - default

  # Storage
  storage:
    container_name: supabase-storage
    image: supabase/storage-api:v0.43.11
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started
      imgproxy:
        condition: service_started
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:5000/status"]
      timeout: 5s
      interval: 5s
      retries: 3
    restart: unless-stopped
    environment:
      ANON_KEY: \${ANON_KEY}
      SERVICE_KEY: \${SERVICE_ROLE_KEY}
      POSTGREST_URL: http://rest:3000
      PGRST_JWT_SECRET: \${JWT_SECRET}
      DATABASE_URL: postgres://supabase_storage_admin:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST}:\${POSTGRES_PORT}/\${POSTGRES_DB}
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: stub
      REGION: stub
      GLOBAL_S3_BUCKET: stub
      ENABLE_IMAGE_TRANSFORMATION: "true"
      IMGPROXY_URL: http://imgproxy:5001
    volumes:
      - ./volumes/storage:/var/lib/storage:z
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # Image proxy
  imgproxy:
    container_name: supabase-imgproxy
    image: darthsim/imgproxy:v3.8.0
    healthcheck:
      test: ["CMD", "imgproxy", "health"]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      IMGPROXY_BIND: ":5001"
      IMGPROXY_LOCAL_FILESYSTEM_ROOT: /
      IMGPROXY_USE_ETAG: "true"
      IMGPROXY_ENABLE_WEBP_DETECTION: \${IMGPROXY_ENABLE_WEBP_DETECTION}
    volumes:
      - ./volumes/storage:/var/lib/storage:z
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # Meta
  meta:
    container_name: supabase-meta
    image: supabase/postgres-meta:v0.68.0
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    restart: unless-stopped
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: \${POSTGRES_HOST}
      PG_META_DB_PORT: \${POSTGRES_PORT}
      PG_META_DB_NAME: \${POSTGRES_DB}
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: \${POSTGRES_PASSWORD}
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # Functions
  functions:
    container_name: supabase-edge-functions
    image: supabase/edge-runtime:v1.45.2
    restart: unless-stopped
    depends_on:
      analytics:
        condition: service_healthy
    environment:
      JWT_SECRET: \${JWT_SECRET}
      SUPABASE_URL: http://kong:8000
      SUPABASE_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: \${SERVICE_ROLE_KEY}
      SUPABASE_DB_URL: postgresql://postgres:\${POSTGRES_PASSWORD}@\${POSTGRES_HOST}:\${POSTGRES_PORT}/\${POSTGRES_DB}
      VERIFY_JWT: \${FUNCTIONS_VERIFY_JWT}
    volumes:
      - ./volumes/functions:/home/deno/functions:Z
    command:
      - start
      - --main-service
      - /home/deno/functions/main
    env_file:
      - ./supabase/docker/.env
    networks:
      - default

  # Analytics
  analytics:
    container_name: supabase-analytics
    image: supabase/logflare:1.4.0
    healthcheck:
      test: ["CMD", "curl", "http://localhost:4000/health"]
      timeout: 5s
      interval: 5s
      retries: 10
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      LOGFLARE_NODE_HOST: 127.0.0.1
      DB_USERNAME: supabase_admin
      DB_DATABASE: \${POSTGRES_DB}
      DB_HOSTNAME: \${POSTGRES_HOST}
      DB_PORT: \${POSTGRES_PORT}
      DB_PASSWORD: \${POSTGRES_PASSWORD}
      DB_SCHEMA: _analytics
      LOGFLARE_API_KEY: \${LOGFLARE_API_KEY}
      LOGFLARE_SINGLE_TENANT: true
      LOGFLARE_SUPABASE_MODE: true
      LOGFLARE_MIN_CLUSTER_SIZE: 1
      RELEASE_COOKIE: cookie
    env_file:
      - ./supabase/docker/.env
    entrypoint: |
      sh -c `cat <<'EOF'
      /app/bin/migrate
      /app/bin/logflare eval 'Logflare.Release.seeds(Logflare.Repo)'
      /app/bin/logflare start --smp=1
      EOF
      `
    networks:
      - default

  # Vector
  vector:
    container_name: supabase-vector
    image: timberio/vector:0.28.1-alpine
    healthcheck:
      test: ["CMD", "vector", "--version"]
      interval: 10s
      timeout: 3s
      retries: 3
    volumes:
      - ./volumes/logs/vector.yml:/etc/vector/vector.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      LOGFLARE_API_KEY: \${LOGFLARE_API_KEY}
    env_file:
      - ./supabase/docker/.env
    networks:
      - default
EOF

# ---------- КОПИРОВАНИЕ НЕОБХОДИМЫХ ФАЙЛОВ SUPABASE ----------
echo "Копирую необходимые файлы Supabase..."
mkdir -p "$PROJECT_DIR/volumes/db"
mkdir -p "$PROJECT_DIR/volumes/api"
mkdir -p "$PROJECT_DIR/volumes/storage"
mkdir -p "$PROJECT_DIR/volumes/functions"
mkdir -p "$PROJECT_DIR/volumes/logs"

# Ищем и копируем SQL файлы инициализации
echo "Ищу SQL файлы инициализации..."
for sql_dir in \
  "$SUPABASE_DIR/docker/volumes/db" \
  "$SUPABASE_DIR/volumes/db" \
  "$SUPABASE_DIR/supabase/docker/volumes/db"; do
  if [ -d "$sql_dir" ]; then
    echo "✅ Копирую SQL файлы из: $sql_dir"
    cp -r "$sql_dir"/*.sql "$PROJECT_DIR/volumes/db/" 2>/dev/null || true
    break
  fi
done

# Ищем и копируем конфигурацию Kong
echo "Ищу конфигурацию Kong..."
for kong_config in \
  "$SUPABASE_DIR/docker/volumes/api/kong.yml" \
  "$SUPABASE_DIR/volumes/api/kong.yml" \
  "$SUPABASE_DIR/supabase/docker/volumes/api/kong.yml"; do
  if [ -f "$kong_config" ]; then
    echo "✅ Копирую Kong конфигурацию из: $kong_config"
    cp "$kong_config" "$PROJECT_DIR/volumes/api/"
    break
  fi
done

# Если конфигурации не найдены, создаем базовые
if [ ! -f "$PROJECT_DIR/volumes/api/kong.yml" ]; then
  echo "⚠️  Kong конфигурация не найдена, создаю базовую..."
  cat > "$PROJECT_DIR/volumes/api/kong.yml" <<'KONG_EOF'
_format_version: "1.1"

consumers:
  - username: anon
    keyauth_credentials:
      - key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBsYWNlaG9sZGVyIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NDUxOTI0MjUsImV4cCI6MTk2MDc2ODQyNX0.A9JRSHURnBRtrnZ4sI-9eU_igOpS-WPHm7dXyn7mwAE
  - username: service_role
    keyauth_credentials:
      - key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBsYWNlaG9sZGVyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTY0NTE5MjQyNSwiZXhwIjoxOTYwNzY4NDI1fQ.M2d2z4SFn5C7HlJlaSLfrzuYim9nbY_XI40uWFN3hEE

acls:
  - consumer: anon
    group: anon
  - consumer: service_role
    group: service_role

services:
  - name: auth-v1-open
    url: http://auth:9999/verify
    routes:
      - name: auth-v1-open
        strip_path: true
        paths:
          - "/auth/v1/verify"
    plugins:
      - name: cors

  - name: auth-v1-open-callback
    url: http://auth:9999/callback
    routes:
      - name: auth-v1-open-callback
        strip_path: true
        paths:
          - "/auth/v1/callback"
    plugins:
      - name: cors

  - name: auth-v1-open-authorize
    url: http://auth:9999/authorize
    routes:
      - name: auth-v1-open-authorize
        strip_path: true
        paths:
          - "/auth/v1/authorize"
    plugins:
      - name: cors

  - name: auth-v1
    _comment: "GoTrue: /auth/v1/* -> http://auth:9999/*"
    url: http://auth:9999/
    routes:
      - name: auth-v1-all
        strip_path: true
        paths:
          - "/auth/v1/"
    plugins:
      - name: cors

  - name: rest-v1
    _comment: "PostgREST: /rest/v1/* -> http://rest:3000/*"
    url: http://rest:3000/
    routes:
      - name: rest-v1-all
        strip_path: true
        paths:
          - "/rest/v1/"
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false

  - name: realtime-v1
    _comment: "Realtime: /realtime/v1/* -> ws://realtime:4000/socket/*"
    url: http://realtime:4000/socket/
    routes:
      - name: realtime-v1-all
        strip_path: true
        paths:
          - "/realtime/v1/"
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: false

  - name: storage-v1
    _comment: "Storage: /storage/v1/* -> http://storage:5000/*"
    url: http://storage:5000/
    routes:
      - name: storage-v1-all
        strip_path: true
        paths:
          - "/storage/v1/"
    plugins:
      - name: cors

  - name: functions-v1
    _comment: "Edge Functions: /functions/v1/* -> http://functions:9000/*"
    url: http://functions:9000/
    routes:
      - name: functions-v1-all
        strip_path: true
        paths:
          - "/functions/v1/"
    plugins:
      - name: cors

plugins:
  - name: cors
    config:
      origins:
        - "*"
      methods:
        - GET
        - HEAD
        - PUT
        - PATCH
        - POST
        - DELETE
      headers:
        - Accept
        - Accept-Version
        - Content-Length
        - Content-MD5
        - Content-Type
        - Date
        - X-Auth-Token
        - Authorization
        - X-Forwarded-For
        - X-Forwarded-Proto
        - X-Forwarded-Port
      exposed_headers:
        - X-Resource-Count
      credentials: true
      max_age: 300
KONG_EOF
fi

# Создаем базовые SQL файлы если их нет
if [ ! -f "$PROJECT_DIR/volumes/db/roles.sql" ]; then
  echo "⚠️  SQL файлы не найдены, создаю базовые..."
  
  cat > "$PROJECT_DIR/volumes/db/roles.sql" <<'SQL_EOF'
-- Set up Realtime
create schema if not exists realtime;
-- create a publication for all tables
create publication supabase_realtime for all tables;

-- Supabase super admin
create user supabase_admin;
alter user supabase_admin with superuser createdb createrole replication bypassrls;

-- Extension namespacing
create schema if not exists extensions;
create extension if not exists "uuid-ossp"      with schema extensions;
create extension if not exists pgcrypto         with schema extensions;
create extension if not exists pgjwt            with schema extensions;

-- Set up auth roles for the developer
create role anon                nologin noinherit;
create role authenticated       nologin noinherit; -- "logged in" user: web_user, app_user, etc
create role service_role        nologin noinherit bypassrls; -- allow developers to create JWT's that bypass their policies

create user authenticator noinherit;
grant anon              to authenticator;
grant authenticated     to authenticator;
grant service_role      to authenticator;
grant supabase_admin    to authenticator;

grant usage                     on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- Allow Extensions to be used in the API
grant usage                     on schema extensions to anon, authenticated, service_role;

-- Set up namespacing
alter user supabase_admin SET search_path TO public, extensions; -- don't include the "auth" schema

-- These are required so that the users receive the permissions
grant supabase_admin to postgres;
grant all privileges on all tables in schema public to supabase_admin;
grant all privileges on all functions in schema public to supabase_admin;
grant all privileges on all sequences in schema public to supabase_admin;
SQL_EOF

  cat > "$PROJECT_DIR/volumes/db/realtime.sql" <<'SQL_EOF'
\echo "Loading Realtime"

-- create schema
create schema if not exists realtime;

-- create publication
drop publication if exists supabase_realtime;
create publication supabase_realtime;
SQL_EOF

  cat > "$PROJECT_DIR/volumes/db/webhooks.sql" <<'SQL_EOF'
\echo "Loading Webhooks"

-- create webhooks schema
create schema if not exists webhooks;
SQL_EOF

  cat > "$PROJECT_DIR/volumes/db/jwt.sql" <<'SQL_EOF'
\echo "Loading JWT"

-- Create auth schema
create schema if not exists auth;
SQL_EOF

  cat > "$PROJECT_DIR/volumes/db/logs.sql" <<'SQL_EOF'
\echo "Loading Logs"

-- create _analytics schema
create schema if not exists _analytics;
SQL_EOF
fi

# Создаем файл конфигурации Vector
cat > "$PROJECT_DIR/volumes/logs/vector.yml" <<EOF
data_dir: /tmp/vector/
api:
  enabled: true
  address: 0.0.0.0:8686
sources:
  docker_host:
    type: docker_logs
    include_labels:
      - "com.docker.compose.project=supabase"
sinks:
  logflare_logs:
    type: http
    inputs: ["docker_host"]
    uri: http://analytics:4000/logs/logflare?source_token=\${LOGFLARE_API_KEY}&source=\${VECTOR_SOURCE}
    method: post
    healthcheck_uri: http://analytics:4000/health
    buffer:
      type: disk
      max_size: 104857600
      when_full: block
    request:
      strategy: adaptive
      retry_max_duration_secs: 10
      retry_initial_backoff_secs: 2
      timeout_secs: 60
    batch:
      max_bytes: 1048576
      timeout_secs: 5
    compression: gzip
    encoding:
      codec: json
    auth:
      strategy: bearer
      token: \${LOGFLARE_API_KEY}
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
      <li><a href="https://$STUDIO_DOMAIN">Supabase Studio</a></li>
      <li><a href="https://$N8N_DOMAIN">n8n</a></li>
      <li><a href="https://$TRAEFIK_DOMAIN">Traefik Dashboard</a></li>
    </ul>
  </body>
</html>
EOF

# ---------- ЗАПУСК ВСЕХ СЕРВИСОВ ----------
echo "🚀 Запускаю все сервисы..."
cd "$PROJECT_DIR"

# Создаем директории для данных
mkdir -p ./n8n/data
mkdir -p ./volumes/db/data

# Устанавливаем права доступа
sudo chown -R 1001:1001 ./n8n/data 2>/dev/null || true
sudo chown -R 999:999 ./volumes/db/data 2>/dev/null || true

# Запускаем сервисы
docker compose pull
docker compose up -d --build

# Ждем пока сервисы запустятся
echo "⏳ Ожидаем запуска сервисов..."
sleep 30

# Показываем статус
docker compose ps

echo "✅ Установка завершена!"
echo ""
echo "🌐 Доступные сервисы:"
echo "   - Основной сайт: https://$SITE_DOMAIN"
echo "   - Supabase API: https://$SUPABASE_DOMAIN"
echo "   - Supabase Studio: https://$STUDIO_DOMAIN"
echo "   - n8n: https://$N8N_DOMAIN"
echo "   - Traefik Dashboard: https://$TRAEFIK_DOMAIN"
echo ""
echo "📋 Полезные команды:"
echo "   - Посмотреть логи: docker compose logs -f [service_name]"
echo "   - Перезапустить: docker compose restart [service_name]"
echo "   - Остановить все: docker compose down"
echo "   - Обновить: $0 --update"
echo ""
echo "🔑 Для n8n используйте логин: admin"
echo "    Пароль будет показан в логах: docker compose logs n8n | grep PASSWORD"