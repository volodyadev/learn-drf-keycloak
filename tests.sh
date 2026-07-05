#!/bin/bash
set -e

# ============================================================
#  НАСТРОЙКИ (читаем из .env, если есть)
# ============================================================
if [ -f backend/.env ]; then
    export $(grep -v '^#' backend/.env | xargs)
fi

KEYCLOAK_COMPOSE="docker-compose-keycloak.yml"
DJANGO_PORT=5000
KEYCLOAK_URL="http://localhost:8080"
REALM="myrealm"
PUBLIC_CLIENT="myapp-public"
CONF_CLIENT="myclient"
CONF_SECRET="${KEYCLOAK_CLIENT_SECRET:-your-client-secret}"
ADMIN_USER="adminuser"
ADMIN_PASS="admin123"
REGULAR_USER="regularuser"
REGULAR_PASS="user123"

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

DJANGO_PID=""

# ============================================================
#  ФУНКЦИИ
# ============================================================
wait_for_keycloak() {
    echo "⏳ Ожидание запуска Keycloak..."
    until curl -s "$KEYCLOAK_URL/realms/$REALM" > /dev/null; do
        sleep 2
    done
    echo "✅ Keycloak запущен"
}

wait_for_django() {
    echo "⏳ Ожидание запуска Django..."
    until curl -s "http://127.0.0.1:$DJANGO_PORT/api/public/" > /dev/null; do
        sleep 2
    done
    echo "✅ Django запущен"
}

check_endpoint() {
    local url="$1"
    local method="${2:-GET}"
    local expected_code="${3:-200}"
    local auth_header="$4"
    local data="$5"
    local cmd="curl -s -o /dev/null -w '%{http_code}' -X $method '$url'"
    [[ -n "$auth_header" ]] && cmd="$cmd -H 'Authorization: $auth_header'"
    [[ -n "$data" ]] && cmd="$cmd -H 'Content-Type: application/json' -d '$data'"
    local code=$(eval $cmd)
    if [[ "$code" == "$expected_code" ]]; then
        echo -e "${GREEN}✓ $url → $code${NC}"
        return 0
    else
        echo -e "${RED}✗ $url → $code (ожидалось $expected_code)${NC}"
        return 1
    fi
}

stop_django() {
    if [[ -n "$DJANGO_PID" ]]; then
        echo "🛑 Останавливаем Django (PID: $DJANGO_PID)..."
        kill $DJANGO_PID 2>/dev/null || true
        wait $DJANGO_PID 2>/dev/null || true
    fi
}

free_port() {
    if lsof -ti:$DJANGO_PORT > /dev/null 2>&1; then
        echo "⚠️ Порт $DJANGO_PORT занят. Освобождаем..."
        lsof -ti:$DJANGO_PORT | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

trap stop_django EXIT

# ============================================================
#  1. ЗАПУСК KEYCLOAK (с очисткой томов)
# ============================================================
echo "🔄 Останавливаем старые контейнеры и удаляем тома для чистой установки..."
docker compose -f "$KEYCLOAK_COMPOSE" down -v || true
echo "🚀 Запуск Keycloak..."
docker compose -f "$KEYCLOAK_COMPOSE" up -d
wait_for_keycloak

# ============================================================
#  2. НАСТРОЙКА СЕРВИС-АККАУНТА
# ============================================================
echo "🔧 Настройка прав сервис-аккаунта клиента $CONF_CLIENT..."

ADMIN_CLI_SECRET="${ADMIN_CLI_SECRET:-}"
if [ -z "$ADMIN_CLI_SECRET" ]; then
    echo "🔑 Введите секрет клиента admin-cli (мастер-реалм, из Credentials):"
    read -s ADMIN_CLI_SECRET
    echo
fi

if [ -z "$ADMIN_CLI_SECRET" ]; then
    echo -e "${RED}✗ Секрет admin-cli не задан.${NC}"
    exit 1
fi

MASTER_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=admin-cli" \
     -d "client_secret=$ADMIN_CLI_SECRET" \
     -d "grant_type=password" \
     -d "username=admin" \
     -d "password=admin" | jq -r '.access_token')
if [[ -z "$MASTER_TOKEN" || "$MASTER_TOKEN" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить мастер-токен.${NC}"
    exit 1
fi
echo "✅ Мастер-токен получен"

# Создаём сервис-аккаунт (если ещё нет)
curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=$CONF_CLIENT" \
     -d "client_secret=$CONF_SECRET" \
     -d "grant_type=client_credentials" > /dev/null

SERVICE_ACCOUNT_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users?username=service-account-$CONF_CLIENT" \
     -H "Authorization: Bearer $MASTER_TOKEN" | jq -r '.[0].id')
if [[ -z "$SERVICE_ACCOUNT_ID" || "$SERVICE_ACCOUNT_ID" == "null" ]]; then
    echo -e "${RED}✗ Сервис-аккаунт не найден.${NC}"
    exit 1
fi
echo "✅ Сервис-аккаунт ID: $SERVICE_ACCOUNT_ID"

REALM_MGMT_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=realm-management" \
     -H "Authorization: Bearer $MASTER_TOKEN" | jq -r '.[0].id')
if [[ -z "$REALM_MGMT_ID" || "$REALM_MGMT_ID" == "null" ]]; then
    echo "⚠️ Клиент realm-management не найден. Создаём..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer $MASTER_TOKEN" \
         -d '{"clientId":"realm-management","protocol":"openid-connect","publicClient":false,"enabled":true}' > /dev/null
    REALM_MGMT_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=realm-management" \
         -H "Authorization: Bearer $MASTER_TOKEN" | jq -r '.[0].id')
    echo "✅ Клиент realm-management создан"
fi
echo "✅ realm-management ID: $REALM_MGMT_ID"

ROLES=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/clients/$REALM_MGMT_ID/roles" \
     -H "Authorization: Bearer $MASTER_TOKEN")
MANAGE_USERS_ID=$(echo $ROLES | jq -r '.[] | select(.name=="manage-users") | .id')
VIEW_USERS_ID=$(echo $ROLES | jq -r '.[] | select(.name=="view-users") | .id')

if [[ -n "$MANAGE_USERS_ID" && -n "$VIEW_USERS_ID" ]]; then
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users/$SERVICE_ACCOUNT_ID/role-mappings/clients/$REALM_MGMT_ID" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer $MASTER_TOKEN" \
         -d '[{"id":"'$MANAGE_USERS_ID'","name":"manage-users"},{"id":"'$VIEW_USERS_ID'","name":"view-users"}]' > /dev/null
    echo "✅ Права сервис-аккаунта назначены"
else
    echo -e "${RED}✗ Не удалось получить ID ролей.${NC}"
    exit 1
fi

# Получаем токен сервис-аккаунта (для Admin API)
echo "🔑 Получение токена сервис-аккаунта (для администрирования)..."
ADMIN_TOKEN_SERVICE=$(curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=$CONF_CLIENT" \
     -d "client_secret=$CONF_SECRET" \
     -d "grant_type=client_credentials" | jq -r '.access_token')
if [[ -z "$ADMIN_TOKEN_SERVICE" || "$ADMIN_TOKEN_SERVICE" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить токен сервис-аккаунта${NC}"
    exit 1
fi
echo "✅ Токен сервис-аккаунта получен"

# ============================================================
#  3. ЗАПУСК DJANGO
# ============================================================
free_port
echo "🚀 Запуск Django..."
cd backend
uv sync
uv run python manage.py makemigrations
uv run python manage.py migrate
uv run python manage.py runserver 0.0.0.0:$DJANGO_PORT &
DJANGO_PID=$!
cd ..
wait_for_django

# ============================================================
#  4. ПОЛУЧЕНИЕ ТОКЕНОВ ДЛЯ ТЕСТОВ
# ============================================================
echo "🔑 Получение токена администратора (adminuser) для проверки эндпоинтов..."
ADMIN_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=$PUBLIC_CLIENT" \
     -d "grant_type=password" \
     -d "username=$ADMIN_USER" \
     -d "password=$ADMIN_PASS" | jq -r '.access_token')
if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить токен adminuser${NC}"
    exit 1
fi
echo "✅ ADMIN_TOKEN получен"

echo "🔑 Получение токена обычного пользователя (regularuser)..."
TOKEN_USER=$(curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=$PUBLIC_CLIENT" \
     -d "grant_type=password" \
     -d "username=$REGULAR_USER" \
     -d "password=$REGULAR_PASS" | jq -r '.access_token')
if [[ -z "$TOKEN_USER" || "$TOKEN_USER" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить токен regularuser${NC}"
    exit 1
fi
echo "✅ TOKEN_USER получен"

# ============================================================
#  5. ТЕСТЫ KEYCLOAK-СИСТЕМЫ
# ============================================================
echo -e "\n${GREEN}=== ТЕСТЫ KEYCLOAK-СИСТЕМЫ ===${NC}"

# Регистрация
echo "🆕 Регистрация пользователя regularuser3..."
REGISTER_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$DJANGO_PORT/api/register/" \
     -H "Content-Type: application/json" \
     -d '{"username":"regularuser3","email":"regularuser3@example.com","password":"userpass3"}')
if echo "$REGISTER_RESPONSE" | grep -q '"message":"Пользователь создан"'; then
    echo "✅ Пользователь regularuser3 создан"
else
    echo -e "${RED}✗ Регистрация не удалась${NC}"
    exit 1
fi

TOKEN_USER3=$(curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=$PUBLIC_CLIENT" \
     -d "grant_type=password" \
     -d "username=regularuser3" \
     -d "password=userpass3" | jq -r '.access_token')
if [[ -z "$TOKEN_USER3" || "$TOKEN_USER3" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить токен regularuser3${NC}"
    exit 1
fi
echo "✅ Токен regularuser3 получен"

check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/public/"
check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/user-only/" GET 200 "Bearer $TOKEN_USER"
check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/admin-only/" GET 403 "Bearer $TOKEN_USER"

# Создание администратора через сервис-аккаунт
echo "👑 Создание администратора adminuser3 через сервис-аккаунт..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $ADMIN_TOKEN_SERVICE" \
     -d '{"username":"adminuser3","email":"adminuser3@example.com","enabled":true,"credentials":[{"type":"password","value":"adminpass","temporary":false}]}')
if [[ "$HTTP_CODE" != "201" ]]; then
    echo -e "${RED}✗ Не удалось создать adminuser3. HTTP $HTTP_CODE${NC}"
    exit 1
fi
echo "✅ adminuser3 создан"

ADMIN_USER_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/users?username=adminuser3" \
     -H "Authorization: Bearer $ADMIN_TOKEN_SERVICE" | jq -r '.[0].id')
if [[ -z "$ADMIN_USER_ID" || "$ADMIN_USER_ID" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить ID adminuser3${NC}"
    exit 1
fi
echo "✅ ID adminuser3 = $ADMIN_USER_ID"

ADMIN_ROLE_ID=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/roles" \
     -H "Authorization: Bearer $ADMIN_TOKEN_SERVICE" | jq -r '.[] | select(.name=="admin") | .id')
if [[ -z "$ADMIN_ROLE_ID" || "$ADMIN_ROLE_ID" == "null" ]]; then
    echo -e "${RED}✗ Не удалось найти роль admin${NC}"
    exit 1
fi
echo "✅ admin role ID = $ADMIN_ROLE_ID"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users/$ADMIN_USER_ID/role-mappings/realm" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $ADMIN_TOKEN_SERVICE" \
     -d '[{"id":"'$ADMIN_ROLE_ID'","name":"admin"}]')
if [[ "$HTTP_CODE" != "204" ]]; then
    echo -e "${RED}✗ Не удалось назначить роль admin. HTTP $HTTP_CODE${NC}"
    exit 1
fi
echo "✅ Роль admin назначена"

TOKEN_ADMIN3=$(curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=$PUBLIC_CLIENT" \
     -d "grant_type=password" \
     -d "username=adminuser3" \
     -d "password=adminpass" | jq -r '.access_token')
if [[ -z "$TOKEN_ADMIN3" || "$TOKEN_ADMIN3" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить токен adminuser3${NC}"
    exit 1
fi
echo "✅ Токен adminuser3 получен"

check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/admin-only/" GET 200 "Bearer $TOKEN_ADMIN3"

# ============================================================
#  6. ТЕСТЫ КАСТОМНОЙ СИСТЕМЫ
# ============================================================
echo -e "\n${GREEN}=== ТЕСТЫ КАСТОМНОЙ СИСТЕМЫ ===${NC}"

# Удаляем существующего customuser для чистоты
echo "🔄 Удаление существующего customuser (если есть)..."
cd backend
uv run python manage.py shell <<EOF
from users.models import User
User.objects.filter(username='customuser').delete()
print("Пользователи с именем customuser удалены")
EOF
cd ..

CUSTOM_REG_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$DJANGO_PORT/api/custom/register/" \
     -H "Content-Type: application/json" \
     -d '{"username":"customuser","email":"custom@example.com","password":"StrongPass123!","password2":"StrongPass123!"}')
if echo "$CUSTOM_REG_RESPONSE" | grep -q '"message":"User created successfully"'; then
    echo "✅ customuser зарегистрирован"
else
    echo -e "${RED}✗ Регистрация customuser не удалась${NC}"
    exit 1
fi

TOKEN_CUSTOM=$(curl -s -X POST "http://127.0.0.1:$DJANGO_PORT/api/custom/login/" \
     -H "Content-Type: application/json" \
     -d '{"username":"customuser","password":"StrongPass123!"}' | jq -r '.access_token')
if [[ -z "$TOKEN_CUSTOM" || "$TOKEN_CUSTOM" == "null" ]]; then
    echo -e "${RED}✗ Не удалось получить токен customuser${NC}"
    exit 1
fi
echo "✅ Токен customuser получен"

check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/custom/public/"
check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/custom/user-only/" GET 200 "Bearer $TOKEN_CUSTOM"
check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/custom/admin-only/" GET 403 "Bearer $TOKEN_CUSTOM"

echo "🔄 Повышение прав customuser до admin..."
cd backend
uv run python manage.py shell <<EOF
from users.models import User, Role
admin_role, _ = Role.objects.get_or_create(name='admin', defaults={'description': 'Administrator'})
u = User.objects.get(username='customuser')
u.role = admin_role
u.save()
print("Роль обновлена на:", u.role.name)
EOF
cd ..
echo "✅ Права повышены"

TOKEN_CUSTOM=$(curl -s -X POST "http://127.0.0.1:$DJANGO_PORT/api/custom/login/" \
     -H "Content-Type: application/json" \
     -d '{"username":"customuser","password":"StrongPass123!"}' | jq -r '.access_token')
if [[ -z "$TOKEN_CUSTOM" || "$TOKEN_CUSTOM" == "null" ]]; then
    echo -e "${RED}✗ Не удалось повторно получить токен${NC}"
    exit 1
fi
echo "✅ Новый токен получен"
check_endpoint "http://127.0.0.1:$DJANGO_PORT/api/custom/admin-only/" GET 200 "Bearer $TOKEN_CUSTOM"


echo "✅ Все тесты завершены"
