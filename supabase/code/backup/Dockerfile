# Imagen mínima con pg_dump + aws-cli + curl para el script de backup.
# Build: docker build -t growthbrick-backup ./infra/backup
# Run:  el Scheduled Service de Easypanel inyecta las env vars y corre /usr/local/bin/backup.sh

FROM postgres:16-alpine

# aws-cli + curl + bash (alpine no trae bash por default)
RUN apk add --no-cache \
      bash \
      curl \
      ca-certificates \
      python3 \
      py3-pip \
      gzip \
    && pip3 install --break-system-packages --no-cache-dir awscli \
    && rm -rf /root/.cache /tmp/* /var/tmp/* \
    && aws --version

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

# Entrypoint: el script. Sale con exit code != 0 si hubo error.
# Easypanel Scheduled Service va a reportar el exit code en su UI.
ENTRYPOINT ["/usr/local/bin/backup.sh"]
