services:
  postgres:
    image: __POSTGRES_IMAGE__
    container_name: platforminit-n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/n8n/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  n8n:
    image: __N8N_IMAGE__
    container_name: platforminit-n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      N8N_EDITOR_BASE_URL: https://${N8N_DOMAIN}
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_SECURE_COOKIE: "true"
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_RUNNERS_ENABLED: "true"
      GENERIC_TIMEZONE: ${N8N_TIMEZONE}
      TZ: ${N8N_TIMEZONE}
    volumes:
      - /srv/n8n/data:/home/node/.n8n
    expose:
      - "5678"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10

  caddy:
    image: __CADDY_IMAGE__
    container_name: platforminit-n8n-caddy
    restart: unless-stopped
    depends_on:
      n8n:
        condition: service_started
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /srv/n8n/Caddyfile:/etc/caddy/Caddyfile:ro
      - /srv/n8n/caddy-data:/data
      - /srv/n8n/caddy-config:/config
