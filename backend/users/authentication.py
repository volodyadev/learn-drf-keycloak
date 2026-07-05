import time

import jwt
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed


class KeycloakAuthentication(BaseAuthentication):
    """
    Аутентификация через JWT токен, полученный от Keycloak.
    Проверяет только срок действия токена (не проверяет подпись и не обращается к Keycloak).
    """

    def authenticate(self, request):
        auth_header = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return None

        token = auth_header.split(" ")[1]

        try:
            # Декодируем токен без проверки подписи (читаем только данные)
            decoded = jwt.decode(token, options={"verify_signature": False})

            # Проверяем срок действия
            exp = decoded.get("exp")
            if exp and exp < time.time():
                raise AuthenticationFailed("Token истёк")

            # Извлекаем данные пользователя
            user_data = {
                "id": decoded.get("sub"),
                "username": decoded.get("preferred_username"),
                "email": decoded.get("email"),
                "roles": decoded.get("realm_access", {}).get("roles", []),
            }

            # Возвращаем кортеж (user, auth_data)
            return (user_data, token)

        except jwt.ExpiredSignatureError:
            raise AuthenticationFailed("Token истёк")
        except jwt.InvalidTokenError:
            raise AuthenticationFailed("Неверный формат токена")
        except Exception as e:
            raise AuthenticationFailed(f"Ошибка аутентификации: {str(e)}")
