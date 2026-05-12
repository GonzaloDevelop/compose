#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Growth Brick — WAL Archiver
# ─────────────────────────────────────────────────────────────────────────────
# Sube WAL files de Postgres a Backblaze B2 para Point-in-Time Recovery.
#
# Postgres escribe los WAL al directorio compartido /wal-archive vía
# `archive_command = 'test ! -f /wal-archive/%f && cp %p /wal-archive/%f'`.
# Este script:
#  1. Monitorea /wal-archive con inotify (eventos en tiempo real)
#  2. Sube cada archivo nuevo a B2 con prefix wal/
#  3. Si éxito, borra el archivo local
#  4. Si falla, lo deja y reintenta en el próximo loop
#  5. Borra WAL files de B2 más viejos que WAL_RETENTION_DAYS
#
# Variables requeridas (ENV):
#   B2_BUCKET           — bucket de B2 (ej "growthbrick-backups")
#   B2_KEY_ID           — Application Key ID de B2
#   B2_APP_KEY          — Application Key de B2
#   B2_ENDPOINT         — endpoint S3-compat
#   B2_REGION           — region
#   WAL_RETENTION_DAYS  — días a retener WAL files (default 14)
#   WAL_DIR             — directorio compartido (default /wal-archive)
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

: "${B2_BUCKET:?B2_BUCKET requerido}"
: "${B2_KEY_ID:?B2_KEY_ID requerido}"
: "${B2_APP_KEY:?B2_APP_KEY requerido}"
: "${B2_ENDPOINT:?B2_ENDPOINT requerido}"
: "${B2_REGION:?B2_REGION requerido}"

WAL_RETENTION_DAYS="${WAL_RETENTION_DAYS:-14}"
WAL_DIR="${WAL_DIR:-/wal-archive}"

export AWS_ACCESS_KEY_ID="$B2_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_APP_KEY"
export AWS_DEFAULT_REGION="$B2_REGION"

mkdir -p "$WAL_DIR"
mkdir -p /tmp
# Permitir que el container de Postgres (user postgres) escriba al volume compartido.
# sticky bit + rwx para todos. Postgres deja archivos read-only, el sidecar los borra.
chmod 1777 "$WAL_DIR"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# Sube un archivo a B2. Si éxito, lo elimina local. Retorna 0/1.
upload_one() {
  local file="$1"
  local basename
  basename=$(basename "$file")

  # Validar que sea un WAL file (no temp, no parcial)
  if [[ "$basename" == *.tmp || "$basename" == *.partial ]]; then
    log "SKIP archivo temporal: $basename"
    return 0
  fi

  if ! [[ "$basename" =~ ^[0-9A-F]{24}$ ]] && \
     ! [[ "$basename" =~ ^[0-9A-F]{8}\.history$ ]] && \
     ! [[ "$basename" =~ ^[0-9A-F]{24}\.[0-9A-F]{8}\.backup$ ]]; then
    log "SKIP no-WAL: $basename"
    return 0
  fi

  log "UPLOAD $basename..."
  if aws s3 cp "$file" "s3://${B2_BUCKET}/wal/${basename}" \
       --endpoint-url "$B2_ENDPOINT" --no-progress --only-show-errors; then
    rm -f "$file"
    log "  ✓ uploaded + deleted local"
    return 0
  else
    log "  ✗ upload FAILED for $basename — will retry"
    return 1
  fi
}

# Procesa todos los WAL files pendientes en WAL_DIR.
process_pending() {
  local count=0
  local failed=0
  for file in "$WAL_DIR"/*; do
    [[ -f "$file" ]] || continue
    if upload_one "$file"; then
      count=$((count + 1))
    else
      failed=$((failed + 1))
    fi
  done
  if [[ $count -gt 0 || $failed -gt 0 ]]; then
    log "BATCH: $count uploaded, $failed failed"
  fi
  # Toque healthcheck file
  touch /tmp/last-archive
}

# Borrar WAL files antiguos de B2 (retention).
cleanup_old() {
  local cutoff_epoch
  cutoff_epoch=$(( $(date -u +%s) - WAL_RETENTION_DAYS * 86400 ))
  local cutoff_iso
  cutoff_iso=$(date -u -d "@${cutoff_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
               date -u -r "${cutoff_epoch}" +%Y-%m-%dT%H:%M:%SZ)

  log "RETENTION: borrando WAL files anteriores a ${cutoff_iso}"
  # aws s3 ls + filter por fecha
  local removed=0
  aws s3 ls "s3://${B2_BUCKET}/wal/" --endpoint-url "$B2_ENDPOINT" 2>/dev/null \
    | while read -r line; do
        local timestamp=$(echo "$line" | awk '{print $1"T"$2"Z"}')
        local key=$(echo "$line" | awk '{print $4}')
        if [[ -z "$key" ]]; then continue; fi
        if [[ "$timestamp" < "$cutoff_iso" ]]; then
          aws s3 rm "s3://${B2_BUCKET}/wal/${key}" \
            --endpoint-url "$B2_ENDPOINT" --quiet
          removed=$((removed + 1))
        fi
      done
  log "  ✓ retention applied"
}

# ─── Main loop ───────────────────────────────────────────────────────────────
log "WAL Archiver iniciado. WAL_DIR=$WAL_DIR BUCKET=$B2_BUCKET RETENTION=${WAL_RETENTION_DAYS}d"

# Procesar archivos preexistentes al arrancar (catch up)
log "Catch-up: procesando archivos pre-existentes..."
process_pending

# Track del último cleanup (correr 1 vez/día)
LAST_CLEANUP=$(date +%s)

# Loop con inotify: reacciona en tiempo real cuando Postgres deposita un WAL.
# Fallback: poll cada 30s por si inotify falla o se pierde un evento.
while true; do
  # inotifywait con timeout 30s
  inotifywait -t 30 -e close_write -e moved_to --format '%f' "$WAL_DIR" 2>/dev/null \
    | while read -r event_file; do
        log "EVENT detected: $event_file"
      done

  # Procesar archivos pendientes (tanto por evento como por timeout)
  process_pending

  # Cleanup retention 1 vez por día
  NOW=$(date +%s)
  if (( NOW - LAST_CLEANUP > 86400 )); then
    cleanup_old
    LAST_CLEANUP=$NOW
  fi
done
