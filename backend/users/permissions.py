from rest_framework.permissions import BasePermission


class HasKeycloakRole(BasePermission):
    """
    Проверяет, есть ли у пользователя хотя бы одна из указанных ролей.
    """

    def __init__(self, allowed_roles):
        self.allowed_roles = allowed_roles

    def has_permission(self, request, view):
        user = request.user
        if not user or not isinstance(user, dict):
            return False
        user_roles = user.get("roles", [])
        return any(role in user_roles for role in self.allowed_roles)
