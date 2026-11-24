# syntax=docker/dockerfile:1
FROM python:3.10-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
COPY --from=deployment kubernetes_settings.py .
ENV DJANGO_SETTINGS_MODULE=kubernetes_settings
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000", "--noreload"]
