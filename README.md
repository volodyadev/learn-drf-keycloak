# Учебный проект интеграции кастомной авторизации и keycloak в проект drf

## Swagger
http://127.0.0.1:5000/api/docs/swagger/

## Запуск тестов
```bash
./tests.sh
```

## Копируем переменные окружения
```bash
cp .env.example .env
```

## Поднимем инфраструктуру keycloak
```bash
docker compose -f docker-compose-keycloak.yml up -d
```

## Поднимаем приложение
```bash
uv sync
uv run python ./backend/manage.py runserver 0.0.0.0:5000

```

# Keycloak

## Получите мастер-токен (если ещё не получили)
```bash
MASTER_TOKEN=$(curl -s -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=admin-cli" \
     -d "client_secret=ВАШ_СЕКРЕТ_admin-cli" \
     -d "grant_type=password" \
     -d "username=admin" \
     -d "password=admin" | jq -r '.access_token')
echo $MASTER_TOKEN
```

## Получите ID сервис-аккаунта клиента myclient
```bash
SERVICE_ACCOUNT_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/myrealm/users?username=service-account-myclient" \
     -H "Authorization: Bearer $MASTER_TOKEN" | jq -r '.[0].id')
echo $SERVICE_ACCOUNT_ID
```

## Получите ID клиента realm-management и ID ролей
```bash
REALM_MGMT_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/myrealm/clients?clientId=realm-management" \
     -H "Authorization: Bearer $MASTER_TOKEN" | jq -r '.[0].id')
```

## Получаем все роли этого клиента
```bash
ROLES=$(curl -s -X GET "http://localhost:8080/admin/realms/myrealm/clients/$REALM_MGMT_ID/roles" \
     -H "Authorization: Bearer $MASTER_TOKEN")

MANAGE_USERS_ID=$(echo $ROLES | jq -r '.[] | select(.name=="manage-users") | .id')
VIEW_USERS_ID=$(echo $ROLES | jq -r '.[] | select(.name=="view-users") | .id')
```

## Назначьте роли сервис-аккаунту
```bash
curl -X POST "http://localhost:8080/admin/realms/myrealm/users/$SERVICE_ACCOUNT_ID/role-mappings/clients/$REALM_MGMT_ID" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $MASTER_TOKEN" \
     -d '[{"id":"'$MANAGE_USERS_ID'","name":"manage-users"},{"id":"'$VIEW_USERS_ID'","name":"view-users"}]'
```

## Получение токена admin'a
```bash
ADMIN_TOKEN=$(curl -s -X POST http://localhost:8080/realms/myrealm/protocol/openid-connect/token \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=myclient" \
     -d "client_secret=your-client-secret" \
     -d "grant_type=client_credentials" | jq -r '.access_token')
echo $ADMIN_TOKEN
```

## Регистрация нового обычного пользователя через API
```bash
curl -X POST http://127.0.0.1:5000/api/register/ \
     -H "Content-Type: application/json" \
     -d '{"username":"regularuser3","email":"regularuser3@example.com","password":"userpass3"}'
Ответ: {"message":"Пользователь создан","id":"..."}
```

## Получение токена для обычного пользователя (без секрета) Используем публичного клиента myapp-public:

```bash
TOKEN_USER=$(curl -s -X POST http://localhost:8080/realms/myrealm/protocol/openid-connect/token \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=myapp-public" \
     -d "grant_type=password" \
     -d "username=regularuser3" \
     -d "password=userpass3" | jq -r '.access_token')
echo $TOKEN_USER
```

## Проверка публичного эндпоинта (без токена)
```bash
curl -X GET http://127.0.0.1:5000/api/public/
Ожидаемый ответ: {"message":"Это публичный эндпоинт. Доступен всем."}
```

## Проверка эндпоинта для роли user
```bash
curl -X GET http://127.0.0.1:5000/api/user-only/ -H "Authorization: Bearer $TOKEN_USER"
Ожидаемый ответ: {"message":"Привет, обычный пользователь! Ты имеешь роль \"user\"."}
```

## Проверка эндпоинта для роли admin (должен вернуть 403)
```bash
curl -X GET http://127.0.0.1:5000/api/admin-only/ -H "Authorization: Bearer $TOKEN_USER"
Ожидаемый ответ: {"detail":"You do not have permission to perform this action."}
```

## Создать пользователя adminuser3 через Admin API (используя ADMIN_TOKEN)
```bash
curl -X POST http://localhost:8080/admin/realms/myrealm/users \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '{
           "username": "adminuser3",
           "email": "adminuser3@example.com",
           "enabled": true,
           "credentials": [{"type": "password", "value": "adminpass", "temporary": false}]
         }'
```

## Получить ID созданного пользователя
```bash
ADMIN_USER_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/myrealm/users?username=adminuser3" \
     -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')
echo $ADMIN_USER_ID
```

## Получить ID роли admin
```bash
ADMIN_ROLE_ID=$(curl -s -X GET "http://localhost:8080/admin/realms/myrealm/roles" \
     -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.name=="admin") | .id')
echo $ADMIN_ROLE_ID
```

## Назначить роль admin пользователю
```bash
curl -X POST "http://localhost:8080/admin/realms/myrealm/users/$ADMIN_USER_ID/role-mappings/realm" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '[{"id":"'$ADMIN_ROLE_ID'","name":"admin"}]'
```

## Получить токен для администратора (без секрета, через публичного клиента)
```bash
TOKEN_ADMIN=$(curl -s -X POST http://localhost:8080/realms/myrealm/protocol/openid-connect/token \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=myapp-public" \
     -d "grant_type=password" \
     -d "username=adminuser3" \
     -d "password=adminpass" | jq -r '.access_token')
echo $TOKEN_ADMIN
```

## Проверить эндпоинт для роли admin
```bash
curl -X GET http://127.0.0.1:5000/api/admin-only/ -H "Authorization: Bearer $TOKEN_ADMIN"
Ожидаемый ответ: {"message":"Добро пожаловать, администратор! Ты имеешь роль \"admin\"."}
```

# Кастомная аутентификация


## Регистрация нового пользователя
```shell
curl -X POST http://127.0.0.1:5000/api/custom/register/ \
     -H "Content-Type: application/json" \
     -d '{"username":"customuser","email":"custom@example.com","password":"StrongPass123!","password2":"StrongPass123!"}'
```

## Логин и получение токена
```shell
TOKEN_CUSTOM=$(curl -s -X POST http://127.0.0.1:5000/api/custom/login/ \
     -H "Content-Type: application/json" \
     -d '{"username":"customuser","password":"StrongPass123!"}' | jq -r '.access_token')
echo "CUSTOM TOKEN: $TOKEN_CUSTOM"
```

## Публичный эндпоинт
```shell
curl -X GET http://127.0.0.1:5000/api/custom/public/
{"message":"Это публичный эндпоинт кастомной системы. Доступен всем."}
```

## Пользовательский эндпоинт
```shell
curl -X GET http://127.0.0.1:5000/api/custom/user-only/ -H "Authorization: Bearer $TOKEN_CUSTOM"
{"message":"Привет, обычный пользователь (кастом)! Ты имеешь роль \"user\"."}
```

## Административный эндпоинт
```shell
curl -X GET http://127.0.0.1:5000/api/custom/admin-only/ -H "Authorization: Bearer $TOKEN_CUSTOM"
{"detail":"You do not have permission to perform this action."}
```

## Повышение прав
```shell
python manage.py shell
from users.models import User, Role

#1. Убедитесь, что роль admin существует (если нет – создаём)
admin_role, created = Role.objects.get_or_create(name='admin', defaults={'description': 'Administrator'})
print(f"Role admin exists: {admin_role}")

#2. Назначьте роль пользователю
u = User.objects.get(username='customuser')
u.role = admin_role
u.save()

#3. Проверьте, что сохранилось
print(u.role.name)  ## должно быть 'admin'
```

## Проверка повышения прав
```shell
curl -X GET http://127.0.0.1:5000/api/custom/admin-only/ -H "Authorization: Bearer $TOKEN_CUSTOM"
{"message":"Добро пожаловать, администратор (кастом)! Ты имеешь роль \"admin\"."}
```