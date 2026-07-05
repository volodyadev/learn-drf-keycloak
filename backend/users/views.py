import jwt
import datetime
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, BasePermission
from rest_framework import status, serializers
from django.contrib.auth import authenticate
from django.contrib.auth.password_validation import validate_password
from keycloak import KeycloakAdmin
from django.conf import settings
from .permissions import HasKeycloakRole
from .models import User, Role, AccessRule


# ============================================================
#  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ДЛЯ КАСТОМНОЙ СИСТЕМЫ (JWT)
# ============================================================


def generate_jwt(user):
    """Генерирует JWT-токен для пользователя."""
    payload = {
        "user_id": user.id,
        "username": user.username,
        "role": user.role.name if user.role else None,
        "exp": datetime.datetime.utcnow() + datetime.timedelta(days=1),
        "iat": datetime.datetime.utcnow(),
    }
    token = jwt.encode(payload, settings.SECRET_KEY, algorithm="HS256")
    return token


def decode_jwt(token):
    """Декодирует JWT-токен и возвращает payload или None."""
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=["HS256"])
        return payload
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        return None


# ============================================================
#  КАСТОМНАЯ АУТЕНТИФИКАЦИЯ (без Keycloak)
# ============================================================


class CustomJWTAuthentication:
    """
    Проверяет JWT-токен, выданный кастомной системой.
    Возвращает объект User и токен.
    """

    def authenticate(self, request):
        auth_header = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return None

        token = auth_header.split(" ")[1]
        payload = decode_jwt(token)
        if not payload:
            raise serializers.ValidationError("Invalid or expired token")

        try:
            user = User.objects.get(id=payload["user_id"])
        except User.DoesNotExist:
            raise serializers.ValidationError("User not found")

        return (user, token)


# ============================================================
#  СЕРИАЛИЗАТОРЫ ДЛЯ КАСТОМНОЙ СИСТЕМЫ
# ============================================================


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(
        write_only=True, required=True, validators=[validate_password]
    )
    password2 = serializers.CharField(write_only=True, required=True)

    class Meta:
        model = User
        fields = ("username", "email", "password", "password2")

    def validate(self, attrs):
        if attrs["password"] != attrs["password2"]:
            raise serializers.ValidationError({"password": "Passwords don't match."})
        return attrs

    def create(self, validated_data):
        user = User.objects.create(
            username=validated_data["username"],
            email=validated_data["email"],
        )
        user.set_password(validated_data["password"])
        # Назначаем роль 'user' по умолчанию
        default_role, _ = Role.objects.get_or_create(name="user")
        user.role = default_role
        user.save()
        return user


class LoginSerializer(serializers.Serializer):
    username = serializers.CharField()
    password = serializers.CharField()

    def validate(self, data):
        user = authenticate(username=data["username"], password=data["password"])
        if user is None:
            raise serializers.ValidationError("Invalid credentials")
        if not user.is_active:
            raise serializers.ValidationError("User is inactive")
        return {"user": user}


# ============================================================
#  PERMISSION ДЛЯ КАСТОМНОЙ СИСТЕМЫ (по ролям)
# ============================================================


class HasRolePermission(BasePermission):
    """
    Проверяет, что у пользователя есть одна из указанных ролей.
    """

    def __init__(self, allowed_roles):
        self.allowed_roles = allowed_roles

    def has_permission(self, request, view):
        user = request.user
        if not user or not user.is_authenticated:
            return False
        if not user.role:
            return False
        return user.role.name in self.allowed_roles


# ============================================================
#  ЭНДПОИНТЫ С KEYCLOAK (БЕЗ ПРЕФИКСА)
# ============================================================


class PublicView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response({"message": "Это публичный эндпоинт. Доступен всем."})


class UserView(APIView):
    def get_permissions(self):
        return [HasKeycloakRole(["user"])]

    def get(self, request):
        return Response(
            {"message": 'Привет, обычный пользователь! Ты имеешь роль "user".'}
        )


class AdminOnlyView(APIView):
    def get_permissions(self):
        return [HasKeycloakRole(["admin"])]

    def get(self, request):
        return Response(
            {"message": 'Добро пожаловать, администратор! Ты имеешь роль "admin".'}
        )


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
            keycloak_admin = KeycloakAdmin(
                server_url=settings.KEYCLOAK_CONFIG["SERVER_URL"],
                client_id=settings.KEYCLOAK_CONFIG["CLIENT_ID"],
                client_secret_key=settings.KEYCLOAK_CONFIG["CLIENT_SECRET"],
                realm_name=settings.KEYCLOAK_CONFIG["REALM"],
                verify=False,
            )
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


# ============================================================
#  КАСТОМНЫЕ ЭНДПОИНТЫ (ПОЛНОСТЬЮ БЕЗ KEYCLOAK)
#  ПУТИ С ПРЕФИКСОМ /api/custom/
# ============================================================


class CustomRegisterView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = RegisterSerializer(data=request.data)
        if serializer.is_valid():
            user = serializer.save()
            return Response(
                {"message": "User created successfully"}, status=status.HTTP_201_CREATED
            )
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


class CustomLoginView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        serializer = LoginSerializer(data=request.data)
        if serializer.is_valid():
            user = serializer.validated_data["user"]
            token = generate_jwt(user)
            return Response(
                {
                    "access_token": token,
                    "user": {
                        "id": user.id,
                        "username": user.username,
                        "role": user.role.name if user.role else None,
                    },
                }
            )
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


class CustomPublicView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response(
            {"message": "Это публичный эндпоинт кастомной системы. Доступен всем."}
        )


class CustomUserOnlyView(APIView):
    authentication_classes = [CustomJWTAuthentication]

    def get_permissions(self):
        return [HasRolePermission(["user"])]

    def get(self, request):
        return Response(
            {"message": 'Привет, обычный пользователь (кастом)! Ты имеешь роль "user".'}
        )


class CustomAdminOnlyView(APIView):
    authentication_classes = [CustomJWTAuthentication]

    def get_permissions(self):
        return [HasRolePermission(["admin"])]

    def get(self, request):
        return Response(
            {
                "message": 'Добро пожаловать, администратор (кастом)! Ты имеешь роль "admin".'
            }
        )
