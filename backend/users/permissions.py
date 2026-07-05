from rest_framework.permissions import BasePermission


class HasKeycloakRole(BasePermission):
    def __init__(self, allowed_roles):
        self.allowed_roles = allowed_roles

    def has_permission(self, request, view):
        user = request.user
        if not user or not isinstance(user, dict):
            return False
        user_roles = user.get("roles", [])
        return any(role in user_roles for role in self.allowed_roles)


class HasRolePermission(BasePermission):
    def __init__(self, allowed_roles):
        self.allowed_roles = allowed_roles

    def has_permission(self, request, view):
        user = request.user
        if not user or not user.is_authenticated:
            return False
        # Предполагаем, что user.role хранит объект Role
        return user.role and user.role.name in self.allowed_roles
