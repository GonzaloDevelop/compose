#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Growth Brick — Backup automático de Postgres → Backblaze B2
# ─────────────────────────────────────────────────────────────────────────────
# Ejecutado por el Scheduled Service de Easypanel cada día.
# Reporta el resultado a /api/backups/report del CRM.
#
# Variables requeridas (ENV):
#   POSTGRES_HOST       — host de Postgres (ej "growthbrick-postgres")
#   POSTGRES_PORT       — default 5432
#   POSTGRES_DB         — nombre de la BD
#   POSTGRES_USER       — usuario (típicamente "postgres")
#   POSTGRES_PASSWORD   — password
#   B2_BUCKET           — bucket de Backblaze B2 (ej "growthbrick-backups")
#   B2_KEY_ID           — Application Key ID de B2
#   B2_APP_KEY          — Application Key de B2
#   B2_ENDPOINT         — endpoint S3-compat (ej "https://s3.us-west-002.backblazeb2.com")
#   B2_REGION           — region (ej "us-west-002")
#   BACKUP_RETENTION_DAYS — días a retener (default 7)
#   CRM_BACKUP_REPORT_URL — URL del endpoint (ej "https://clientes.growthbrick.tech/api/backups/report")
#   CRON_SECRET         — mismo valor que el del CRM
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─── Validación de variables ─────────────────────────────────────────────────
: "${POSTGRES_HOST:?POSTGRES_HOST requerido}"
: "${POSTGRES_DB:?POSTGRES_DB requerido}"
: "${POSTGRES_USER:?POSTGRES_USER requerido}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD requerido}"
: "${B2_BUCKET:?B2_BUCKET requerido}"
: "${B2_KEY_ID:?B2_KEY_ID requerido}"
: "${B2_APP_KEY:?B2_APP_KEY requerido}"
: "${B2_ENDPOINT:?B2_ENDPOINT requerido}"
: "${B2_REGION:?B2_REGION requerido}"
: "${CRM_BACKUP_REPORT_URL:?CRM_BACKUP_REPORT_URL requerido}"
: "${CRON_SECRET:?CRON_SECRET requerido}"

POSTGRES_PORT="${POSTGRES_PORT:-5432}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
FILENAME="growthbrick-db-${TIMESTAMP}.sql.gz"
TMP_FILE="/tmp/${FILENAME}"

START_TS=$(date +%s)

# ─── Helper para reportar al CRM (en éxito o falla) ──────────────────────────
report() {
  local status="$1"
  local size="${2:-null}"
  local duration="${3:-null}"
  local key="${4:-}"
  local error="${5:-}"

  # Construir JSON manualmente para no depender de jq
  local payload="{\"status\":\"${status}\""
  if [[ "$size" != "null" ]]; then
    payload+=",\"size_bytes\":${size}"
  fi
  if [[ "$duration" != "null" ]]; then
    payload+=",\"duration_seconds\":${duration}"
  fi
  if [[ -n "$key" ]]; then
    payload+=",\"storage_key\":\"${key}\""
    payload+=",\"storage_bucket\":\"${B2_BUCKET}\""
  fi
  if [[ -n "$error" ]]; then
    # Escapar comillas y saltos de línea
    local escaped
    escaped=$(echo "$error" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    payload+=",\"error_message\":\"${escaped}\""
  fi
  payload+="}"

  echo "[report] $payload"
  curl -sS -X POST "$CRM_BACKUP_REPORT_URL" \
    -H "Authorization: Bearer ${CRON_SECRET}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    --max-time 30 || echo "[report] WARN: report failed (no bloquea)"
}

# Capturar errores y reportar
trap 'duration=$(($(date +%s) - START_TS)); report "failed" null "$duration" "" "Script abortado en línea $LINENO"' ERR

# ─── 1. pg_dump → gzip → archivo local ───────────────────────────────────────
echo "[1/4] pg_dump → ${TMP_FILE}"
export PGPASSWORD="$POSTGRES_PASSWORD"
pg_dump \
  -h "$POSTGRES_HOST" \
  -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --no-owner \
  --no-acl \
  --clean \
  --if-exists \
  --quote-all-identifiers \
  | gzip > "$TMP_FILE"

SIZE=$(stat -c %s "$TMP_FILE" 2>/dev/null || stat -f %z "$TMP_FILE")
echo "      ✓ Tamaño: ${SIZE} bytes ($(( SIZE / 1024 / 1024 )) MB)"

if [[ "$SIZE" -lt 1024 ]]; then
  ERR="Dump sospechosamente pequeño (${SIZE} bytes) — probablemente la BD está vacía o hubo error silencioso"
  duration=$(($(date +%s) - START_TS))
  report "failed" "$SIZE" "$duration" "" "$ERR"
  exit 1
fi

# ─── 2. Upload a B2 (S3-compatible) ──────────────────────────────────────────
echo "[2/4] Upload a B2: s3://${B2_BUCKET}/${FILENAME}"
export AWS_ACCESS_KEY_ID="$B2_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_APP_KEY"
export AWS_DEFAULT_REGION="$B2_REGION"

aws s3 cp "$TMP_FILE" "s3://${B2_BUCKET}/${FILENAME}" \
  --endpoint-url "$B2_ENDPOINT" \
  --no-progress
echo "      ✓ Uploaded"

# ─── 3. Limpiar archivos locales ─────────────────────────────────────────────
echo "[3/4] Cleanup local"
rm -f "$TMP_FILE"

# ─── 4. Borrar backups remotos más viejos que RETENTION_DAYS ────────────────
echo "[4/4] Retención: borrar backups con > ${RETENTION_DAYS} días"
# BusyBox-compatible (Alpine): calcular epoch del cutoff y formatear
CUTOFF_EPOCH=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))
CUTOFF_DATE=$(date -u -d "@${CUTOFF_EPOCH}" +%Y%m%d 2>/dev/null || \
              date -u -r "${CUTOFF_EPOCH}" +%Y%m%d)

# Listar todos los backups en el bucket y filtrar por fecha en el filename
aws s3 ls "s3://${B2_BUCKET}/" --endpoint-url "$B2_ENDPOINT" \
  | awk '{print $4}' \
  | grep -E '^growthbrick-db-[0-9]{8}-[0-9]{6}\.sql\.gz$' \
  | while read -r OBJ; do
      # extraer fecha YYYYMMDD del nombre del archivo
      OBJ_DATE=$(echo "$OBJ" | sed -E 's/^growthbrick-db-([0-9]{8})-.*$/\1/')
      if [[ "$OBJ_DATE" < "$CUTOFF_DATE" ]]; then
        echo "      - borrando: $OBJ (fecha $OBJ_DATE < $CUTOFF_DATE)"
        aws s3 rm "s3://${B2_BUCKET}/${OBJ}" --endpoint-url "$B2_ENDPOINT" --quiet
      fi
    done
echo "      ✓ Retención aplicada"

DURATION=$(($(date +%s) - START_TS))
echo "✅ Backup completo: ${FILENAME} (${SIZE} bytes en ${DURATION}s)"

report "success" "$SIZE" "$DURATION" "$FILENAME" ""
