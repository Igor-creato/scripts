#!/usr/bin/env bash
set -euo pipefail

#
# install.sh — установка/обновление стека:
# Traefik (Let's Encrypt) + сайт (nginx) + n8n + Supabase (self-hosted)
#
# Режимы:
#   1) bash install.sh          -> STAGING (тестовые сертификаты, без лимитов)
#   2) bash install.sh --prod   -> PROD (боевые сертификаты)
#   3) bash install.sh --update -> Обновление образов/контейнеров, без изменения конфигов/сертов
#

# ---------- ПАРАМЕТРЫ ----------
DOMAIN_BASE="autmatization-bot.ru"
SITE_DOMAIN="$DOMAIN_BASE"
N8N_DOMAIN="n8n.$DOMAIN_BASE"
SUPABASE_DOMAIN="supabase.$DOMAIN_BASE"
STUDIO_DOMAIN="studio.supabase.$DOMAIN_BASE"
TRAEFIK_DOMAIN="traefik.$DOMAIN_BASE"
SERVER_IP=$(curl -s ifconfig.me || echo "")
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

# ---------- ХЕЛПЕРЫ ----------
msg() { echo -e "$*"; }

wait_https_ready() {
  local domain="$1"
  local tries="${2:-60}"   # до 60 попыток
  local sleep_s="${3:-5}"  # по 5 секунд между попытками

  msg "⏳ Жду доступности https://${domain} ..."
  for ((i=1; i<=tries; i++)); do
    # Не валим на самоподписанном/стейджинг сертификате (-k)
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

  if [[ -z "$issuer" ]]; then
    msg "⚠️  Не удалось прочитать сертификат для ${domain}"
    return 1
  fi

  msg "🔎 Issuer для ${domain}: ${issuer}"

  if [[ "$expect_staging" == "yes" ]]; then
    # У staging Let's Encrypt обычно CN содержит "Fake LE Intermediate"
    if echo "$issuer" | grep -qi "Fake LE"; then
      msg "✅ Найден STAGING сертификат (issuer содержит 'Fake LE')."
      return 0
    else
      msg "❌ Ожидался STAGING сертификат, но issuer не похож на 'Fake LE'."
      return 1
    fi
  else
    # Для прод — ожидаем, что это Let's Encrypt, но не 'Fake LE'
    if echo "$issuer" | grep -qi "Let's Encrypt" && ! echo "$issuer" | grep -qi "Fake LE"; then
      msg "✅ Найден PROD сертификат от Let's Encrypt."
      return 0
    else
      msg "❌ Ожидался PROD сертификат Let's Encrypt (не 'Fake LE')."
      return 1
    fi
  fi
}

# ---------- РЕЖИМ ОБНОВЛЕНИЯ ----------
if [[ "$MODE" == "update" ]]; then
  msg "🔄 Режим обновления..."

  if ! docker network ls --format '{{.Name}}' | grep -q "^traefik-net$"; then
    msg "❌ Сеть traefik-net не найдена — выполните полную установку."
    exit 1
  fi
  if [ ! -d "$PROJECT_DIR" ] || [ ! -d "$SUPABASE_DOCKER_DIR" ]; then
    msg "❌ Проект не найден — выполните полную установку."
    exit 1
  fi

  msg "📦 Обновляю Traefik, сайт и n8n..."
  cd "$PROJECT_DIR"
  docker compose pull
  docker compose up -d --build

  msg "📦 Обновляю Supabase..."
  cd "$SUPABASE_DOCKER_DIR"
  docker compose pull
  docker compose up -d

  msg "✅ Обновление завершено."
  exit 0
fi

# ---------- ПОЛНАЯ УСТАНОВКА ----------
msg "Проект будет установлен в: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR" "$SUPABASE_DOCKER_DIR" "$TRAEFIK_DIR" "$LE_DIR"

# ---------- ОБНОВЛЕНИЕ СИСТЕМЫ ----------
msg "📦 Обновляем систему..."
sudo apt update && sudo apt upgrade -y

# ---------- ПРОВЕРКА DNS ----------
if [[ -n "$SERVER_IP" ]]; then
  msg "🔍 Проверяем DNS записи..."
  for DOMAIN in $DOMAIN_BASE $N8N_DOMAIN $SUPABASE_DOMAIN $STUDIO_DOMAIN $TRAEFIK_DOMAIN; do
    DNS_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [ "$DNS_IP" != "$SERVER_IP" ]; then
      msg "❌ $DOMAIN указывает на $DNS_IP, а не на $SERVER_IP"
      exit 1
    else
      msg "✅ $DOMAIN указывает на $SERVER_IP"
    fi
  done
else
  msg "⚠️ Не удалось получить внешний IP. Пропускаю строгую проверку DNS."
fi

# ---------- УСТАНОВКА DOCKER ----------
if ! command -v docker >/dev/null 2>&1; then
  msg "Устанавливаю Docker..."
  sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
else
  msg "Docker уже установлен."
fi

# ---------- КЛОНИРОВАНИЕ SUPABASE ----------
if [ ! -d "$SUPABASE_DIR" ]; then
  msg "Клонирую официальный Supabase репозиторий..."
  git clone https://github.com/supabase/supabase.git "$SUPABASE_DIR"
else
  msg "Supabase репозиторий уже присутствует."
fi

# ---------- TRAEFIK: режимы сертов ----------
ACME_FILE="acme.json"
CASERVER_LINE=""
EXPECT_STAGING="no"
if [[ "$MODE" == "staging" ]]; then
  ACME_FILE="acme-staging.json"
  CASERVER_LINE="      caServer: https://acme-staging-v02.api.letsencrypt.org/directory"
  EXPECT_STAGING="yes"
  msg "⚠️  Режим STAGING: тестовые сертификаты (без лимитов)."
else
  msg "✅ Режим PROD: боевые сертификаты Let's Encrypt."
fi
STORAGE_PATH="/letsencrypt/${ACME_FILE}"

# ---------- СОЗДАНИЕ КОНФИГА TRAEFIK ----------
msg "Создаю конфигурацию Traefik..."
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
      storage: $STORAGE_PATH
$CASERVER_LINE
      httpChallenge:
        entryPoint: web
EOF

# ---------- СОХРАНЕНИЕ ACME-ФАЙЛА ----------
if [ ! -f "$LE_DIR/$ACME_FILE" ]; then
  msg "Создаю $LE_DIR/$ACME_FILE ..."
  touch "$LE_DIR/$ACME_FILE"
  chmod 600 "$LE_DIR/$ACME_FILE"
else
  msg "Использую существующий $LE_DIR/$ACME_FILE (сертификаты не будут пересозданы)."
fi

# ---------- СОЗДАНИЕ СЕТИ TRAEFIK-NET ----------
if ! docker network ls --format '{{.Name}}' | grep -q "^traefik-net$"; then
  msg "Создаю сеть traefik-net..."
  docker network create traefik-net
else
  msg "Сеть traefik-net уже существует."
fi

# ---------- DOCKER-COMPOSE (Traefik + Site + n8n + Dashboard) ----------
msg "Создаю docker-compose.yml..."
cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
version: "3.9"
networks:
  traefik-net:
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
      - "--api.dashboard=true"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/traefik.yml:/etc/traefik/traefik.yml:ro"
      - "./letsencrypt/${ACME_FILE}:${STORAGE_PATH}"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`$TRAEFIK_DOMAIN\`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
    networks:
      - traefik-net
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
    networks:
      - traefik-net
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
    networks:
      - traefik-net
    restart: unless-stopped
EOF

# ---------- ПРОСТОЙ САЙТ ----------
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

# ---------- .ENV ДЛЯ SUPABASE ----------
SUP_ENV_FILE="$SUPABASE_DOCKER_DIR/.env"
mkdir -p "$SUPABASE_DOCKER_DIR"

gen_secret() { openssl rand -base64 48 | tr -d '\n'; }
gen_hex() { openssl rand -hex 32; }

if [ ! -f "$SUP_ENV_FILE" ]; then
  msg "Генерирую .env для Supabase..."
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
ENABLE_EMAIL_AUTOCONФIRM=false
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
  msg ".env для Supabase уже существует."
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

# ---------- АВТОПРОВЕРКА HTTPS И ИЗДАТЕЛЯ СЕРТА ----------
set +e
overall_ok=0

for d in "$SITE_DOMAIN" "$N8N_DOMAIN" "$TRAEFIK_DOMAIN"; do
  if wait_https_ready "$d" 60 5; then
    if check_cert_issuer "$d" "$EXPECT_STAGING"; then
      msg "✅ Проверка ${d} прошла успешно."
    else
      msg "⚠️  ${d}: HTTPS доступен, но издатель сертификата не совпал с ожидаемым режимом."
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
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧪 УСТАНОВКА ЗАВЕРШЕНА В РЕЖИМЕ STAGING"
  echo "Файлы сертификатов: $LE_DIR/acme-staging.json"
  echo "Когда всё проверишь — переключайся на боевые сертификаты командой:"
  echo
  echo "  bash \"$0\" --prod"
  echo
  echo "Это перегенерирует traefik.yml на продовый CA,"
  echo "смонтирует $LE_DIR/acme.json внутрь контейнера,"
  echo "и перезапустит сервисы без простоя."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ УСТАНОВКА ЗАВЕРШЕНА В РЕЖИМЕ PROD"
  echo "Файлы сертификатов: $LE_DIR/acme.json"
  echo "Для обновления образов в будущем используйте:"
  echo
  echo "  bash \"$0\" --update"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

exit $overall_ok
