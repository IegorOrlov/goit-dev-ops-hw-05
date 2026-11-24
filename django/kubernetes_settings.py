"""Доповнення налаштувань застосунку з попереднього ДЗ для Kubernetes."""

import importlib
import os

source_settings = importlib.import_module("my-app.settings")
globals().update(
    {name: value for name, value in vars(source_settings).items() if name.isupper()}
)
ALLOWED_HOSTS = [host.strip() for host in os.environ.get("ALLOWED_HOSTS", "").split(",") if host.strip()]
