from django.contrib import admin
from django.urls import path
from users.views import (
    RegisterUserView,
    AdminOnlyView,
    PublicView,
    UserView,
    CustomRegisterView,
    CustomLoginView,
    CustomPublicView,
    CustomUserOnlyView,
    CustomAdminOnlyView,
)

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/register/", RegisterUserView.as_view(), name="register"),
    path("api/public/", PublicView.as_view(), name="public"),
    path("api/user-only/", UserView.as_view(), name="user-only"),
    path("api/admin-only/", AdminOnlyView.as_view(), name="admin-only"),
    path("api/custom/register/", CustomRegisterView.as_view(), name="custom-register"),
    path("api/custom/login/", CustomLoginView.as_view(), name="custom-login"),
    path("api/custom/public/", CustomPublicView.as_view(), name="custom-public"),
    path(
        "api/custom/user-only/", CustomUserOnlyView.as_view(), name="custom-user-only"
    ),
    path(
        "api/custom/admin-only/",
        CustomAdminOnlyView.as_view(),
        name="custom-admin-only",
    ),
]
