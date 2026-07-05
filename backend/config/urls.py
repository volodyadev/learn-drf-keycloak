from django.contrib import admin
from django.urls import path
from users.views import RegisterUserView, AdminOnlyView, PublicView, UserView

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/register/", RegisterUserView.as_view(), name="register"),
    path("api/public/", PublicView.as_view(), name="public"),
    path("api/user-only/", UserView.as_view(), name="user-only"),
    path("api/admin-only/", AdminOnlyView.as_view(), name="admin-only"),
]
