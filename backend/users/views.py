from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import AllowAny
from rest_framework import status
from keycloak import KeycloakAdmin
from django.conf import settings
from .permissions import HasKeycloakRole


# ---------- Публичный эндпоинт (доступ без токена) ----------
class PublicView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response({"message": "Это публичный эндпоинт. Доступен всем."})


# ---------- Эндпоинт для пользователей с ролью "user" ----------
class UserView(APIView):
    def get_permissions(self):
        return [HasKeycloakRole(["user"])]

    def get(self, request):
        return Response(
            {"message": 'Привет, обычный пользователь! Ты имеешь роль "user".'}
        )


# ---------- Эндпоинт для пользователей с ролью "admin" ----------
class AdminOnlyView(APIView):
    def get_permissions(self):
        return [HasKeycloakRole(["admin"])]

    def get(self, request):
        return Response(
            {"message": 'Добро пожаловать, администратор! Ты имеешь роль "admin".'}
        )


# ---------- Регистрация нового пользователя (через клиентские credentials) ----------
class RegisterUserView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        username = request.data.get("username")
        email = request.data.get("email")
        password = request.data.get("password")

        if not all([username, email, password]):
            return Response(
                {"error": "Все поля (username, email, password) обязательны"},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            # Используем клиентские credentials для административных операций
            # (клиент должен иметь права manage-users и view-users в realm-management)
            keycloak_admin = KeycloakAdmin(
                server_url=settings.KEYCLOAK_CONFIG["SERVER_URL"],
                client_id=settings.KEYCLOAK_CONFIG["CLIENT_ID"],
                client_secret_key=settings.KEYCLOAK_CONFIG["CLIENT_SECRET"],
                realm_name=settings.KEYCLOAK_CONFIG["REALM"],
                verify=False,
            )

            # Создаём пользователя в реалме
            user_id = keycloak_admin.create_user(
                payload={
                    "username": username,
                    "email": email,
                    "enabled": True,
                    "credentials": [
                        {"type": "password", "value": password, "temporary": False}
                    ],
                }
            )

            # Проверяем наличие роли 'user', при необходимости создаём
            roles = keycloak_admin.get_realm_roles()
            user_role = next((r for r in roles if r.get("name") == "user"), None)
            if not user_role:
                keycloak_admin.create_realm_role(payload={"name": "user"})
                roles = keycloak_admin.get_realm_roles()
                user_role = next((r for r in roles if r.get("name") == "user"), None)

            if user_role:
                keycloak_admin.assign_realm_roles(user_id=user_id, roles=[user_role])

            return Response(
                {"message": "Пользователь создан", "id": user_id},
                status=status.HTTP_201_CREATED,
            )

        except Exception as e:
            import traceback

            return Response(
                {"error": str(e), "trace": traceback.format_exc()},
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )
