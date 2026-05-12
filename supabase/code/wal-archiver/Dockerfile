# Sidecar que sube WAL files de Postgres a Backblaze B2.
# Monitorea el directorio compartido /wal-archive (volume con el container de Postgres),
# sube cada WAL nuevo a B2 con prefix wal/, y borra el local tras éxito.
#
# Diseñado para correr como service en el mismo docker-compose que Postgres.

FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      curl \
      ca-certificates \
      python3 \
      py3-pip \
      inotify-tools \
    && pip3 install --break-system-packages --no-cache-dir awscli \
    && rm -rf /root/.cache /tmp/* /var/tmp/* \
    && aws --version

COPY wal-archiver.sh /usr/local/bin/wal-archiver.sh
RUN chmod +x /usr/local/bin/wal-archiver.sh

# Healthcheck: el archivo /tmp/last-archive lo toca el script cada vez que
# procesa un batch. Si pasa > 600 seg sin tocarlo, el sidecar está stuck.
HEALTHCHECK --interval=120s --timeout=10s --start-period=60s --retries=2 \
  CMD test -f /tmp/last-archive && \
      [ $(( $(date +%s) - $(stat -c %Y /tmp/last-archive) )) -lt 600 ] \
      || exit 1

ENTRYPOINT ["/usr/local/bin/wal-archiver.sh"]
