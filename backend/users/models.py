from django.contrib.auth.models import AbstractUser
# Create your models here.
from django.db import models


class Role(models.Model):
    """
    Роль пользователя в системе (например, admin, manager, user).
    Используется как для Keycloak-синхронизации, так и для кастомной системы.
    """

    name = models.CharField(max_length=50, unique=True)
    description = models.TextField(blank=True)

    def __str__(self):
        return self.name


class BusinessElement(models.Model):
    """
    Бизнес-сущности, к которым применяются права доступа.
    Например: orders, products, users, и т.д.
    """

    name = models.CharField(max_length=50, unique=True)
    description = models.TextField(blank=True)

    def __str__(self):
        return self.name


class AccessRule(models.Model):
    """
    Правила доступа: связывает роль, бизнес-элемент и операции.
    """

    role = models.ForeignKey(Role, on_delete=models.CASCADE, related_name="rules")
    element = models.ForeignKey(
        BusinessElement, on_delete=models.CASCADE, related_name="rules"
    )

    can_read = models.BooleanField(default=False)
    can_create = models.BooleanField(default=False)
    can_update = models.BooleanField(default=False)
    can_delete = models.BooleanField(default=False)

    # Дополнительные права для "всех" объектов (для расширения)
    can_read_all = models.BooleanField(default=False)
    can_update_all = models.BooleanField(default=False)
    can_delete_all = models.BooleanField(default=False)

    class Meta:
        unique_together = ("role", "element")

    def __str__(self):
        return f"{self.role.name} → {self.element.name}"


class User(AbstractUser):
    """
    Пользователь системы.
    - Используется как для Keycloak (синхронизация по keycloak_id), так и для кастомной системы.
    - Поле role ссылается на локальную роль.
    - Поле keycloak_id хранит идентификатор из Keycloak (если пользователь зарегистрирован через Keycloak).
    """

    keycloak_id = models.CharField(max_length=100, unique=True, null=True, blank=True)
    role = models.ForeignKey(Role, on_delete=models.SET_NULL, null=True, blank=True)

    # Переопределяем groups и user_permissions, чтобы избежать конфликтов обратных связей
    groups = models.ManyToManyField(
        "auth.Group",
        related_name="custom_user_groups",
        blank=True,
        verbose_name="groups",
        help_text="The groups this user belongs to.",
    )
    user_permissions = models.ManyToManyField(
        "auth.Permission",
        related_name="custom_user_permissions",
        blank=True,
        verbose_name="user permissions",
        help_text="Specific permissions for this user.",
    )

    def __str__(self):
        return self.username
