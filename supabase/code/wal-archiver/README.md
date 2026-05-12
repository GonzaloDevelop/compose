# WAL Archiver — Point-in-Time Recovery

Sidecar que sube WAL files de Postgres a Backblaze B2 para permitir
restauración a **cualquier punto en el tiempo** con resolución de ~5 minutos.

## Cómo funciona

```
Postgres → archive_command → /wal-archive (volume compartido) → wal-archiver → B2
```

1. Postgres escribe el WAL log normalmente
2. Cuando un WAL file de 16 MB se completa (o pasan 5 min sin actividad), Postgres ejecuta:
   ```
   archive_command = 'test ! -f /wal-archive/%f && cp %p /wal-archive/%f'
   ```
3. El sidecar `wal-archiver` escucha el directorio `/wal-archive` con inotify
4. Cuando aparece un archivo nuevo, lo sube a `s3://growthbrick-backups/wal/<filename>`
5. Si el upload es exitoso, lo borra del disco local
6. Si falla, lo deja y reintenta en el próximo loop (cada 30s)
7. Retention: borra WAL files de B2 con más de `WAL_RETENTION_DAYS` días (default 14)

## Estructura en B2

```
growthbrick-backups/
├── growthbrick-db-20260512-220048.sql.gz       ← base backup (Capa 1, horario)
├── growthbrick-db-20260513-220048.sql.gz
├── ...
└── wal/
    ├── 000000010000000000000001                ← WAL files (16 MB each)
    ├── 000000010000000000000002
    ├── ...
    └── 00000001.history                         ← timeline history
```

## Recovery Procedure (Point-in-Time)

### Caso: "Restaurar la BD al estado de las 15:32 del martes 12 de mayo"

#### 1. Identificar qué base backup usar

Bajar el último `pg_dump` ANTERIOR al target time. Si querés restaurar al 12/05 15:32, usá:
```bash
aws s3 ls s3://growthbrick-backups/ --endpoint-url https://s3.us-west-002.backblazeb2.com \
  | grep growthbrick-db-20260512
```

Buscá el archivo cuyo timestamp es ≤ a tu target. Ej: `growthbrick-db-20260512-150000.sql.gz` (de las 15:00).

#### 2. Bajar el base backup + todos los WAL posteriores

```bash
# Crear directorios
mkdir -p /tmp/restore/wal_archive
cd /tmp/restore

# Bajar el base backup
aws s3 cp s3://growthbrick-backups/growthbrick-db-20260512-150000.sql.gz . \
  --endpoint-url https://s3.us-west-002.backblazeb2.com

# Bajar TODOS los WAL files (filter por timeline)
aws s3 sync s3://growthbrick-backups/wal/ ./wal_archive/ \
  --endpoint-url https://s3.us-west-002.backblazeb2.com
```

#### 3. Restaurar el base backup en una BD nueva

⚠️ **NO sobreescribir prod sin testear.** Crear una BD nueva en otra instancia o servidor.

```bash
# Crear DB nueva
createdb -h <host> -U postgres growthbrick_restore

# Restaurar
gunzip -c growthbrick-db-20260512-150000.sql.gz \
  | psql -h <host> -U postgres -d growthbrick_restore
```

#### 4. Configurar Point-in-Time Recovery

En Postgres ≥ 12, esto se hace creando un archivo `recovery.signal` y configurando:

```ini
# postgresql.auto.conf o postgresql.conf
restore_command = 'cp /tmp/restore/wal_archive/%f %p'
recovery_target_time = '2026-05-12 15:32:00'
recovery_target_timeline = 'latest'
recovery_target_action = 'promote'  # auto-promote a primary cuando termine
```

Tocá el signal file:
```bash
touch /var/lib/postgresql/data/recovery.signal
```

Reiniciar Postgres. Va a:
1. Detectar `recovery.signal`
2. Entrar en recovery mode
3. Aplicar WAL files desde `wal_archive/` hasta el `recovery_target_time`
4. Promoverse a primary cuando llegue al target
5. Levantar normalmente

#### 5. Validar que está OK

```sql
SELECT max(created_at) FROM leads;        -- debería ser ≤ 15:32 del 12/05
SELECT count(*) FROM clients;
SELECT pg_is_in_recovery();               -- debería devolver `f` (false) tras promote
```

#### 6. Switchover a prod

Si la BD restaurada se ve OK, hacer el cambio en el CRM:
1. Frenar tráfico (poner CRM en modo mantenimiento)
2. Cambiar el `DATABASE_URL` apuntando a la BD restaurada
3. Verificar con queries manuales
4. Reactivar tráfico

## Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `B2_BUCKET` | — | Bucket de B2 |
| `B2_KEY_ID` | — | Application Key ID |
| `B2_APP_KEY` | — | Application Key |
| `B2_ENDPOINT` | — | Endpoint S3-compat |
| `B2_REGION` | — | Region |
| `WAL_RETENTION_DAYS` | 14 | Días a retener WAL files en B2 |
| `WAL_DIR` | `/wal-archive` | Volume compartido con Postgres |

## Setup en compose

Ver `supabase/code/docker-compose.yml`:

```yaml
services:
  db:
    volumes:
      - wal-archive:/wal-archive          # ← NUEVO
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
      - -c
      - log_min_messages=fatal
      - -c
      - archive_mode=on                   # ← NUEVO
      - -c
      - archive_timeout=300               # ← NUEVO (5 min)
      - -c
      - "archive_command=test ! -f /wal-archive/%f && cp %p /wal-archive/%f"

  wal-archiver:
    build:
      context: ./wal-archiver
    environment:
      B2_BUCKET: ${B2_BUCKET}
      B2_KEY_ID: ${B2_KEY_ID}
      B2_APP_KEY: ${B2_APP_KEY}
      B2_ENDPOINT: ${B2_ENDPOINT}
      B2_REGION: ${B2_REGION}
      WAL_RETENTION_DAYS: ${WAL_RETENTION_DAYS:-14}
    volumes:
      - wal-archive:/wal-archive
    restart: unless-stopped
    depends_on:
      - db

volumes:
  wal-archive:
```

⚠️ **Activar `archive_mode=on` requiere reinicio de Postgres.** Después de modificar el compose y deployar, el container `db` se va a reiniciar (1-2 min de downtime).

## Monitoreo

### Cómo saber si WAL archiving está corriendo

```bash
# Listar WAL files recientes en B2
aws s3 ls s3://growthbrick-backups/wal/ \
  --endpoint-url https://s3.us-west-002.backblazeb2.com \
  | tail -10
```

Debería haber archivos nuevos cada 5 minutos máximo (por el `archive_timeout=300`).

### Health-check del sidecar

El Dockerfile incluye `HEALTHCHECK`. Si pasan > 600 segundos sin tocar `/tmp/last-archive`, Docker marca el container como unhealthy.

### Verificar desde Postgres

```sql
-- ¿WAL archiving está activo?
SHOW archive_mode;

-- ¿Cuántos WAL files han sido archivados?
SELECT * FROM pg_stat_archiver;
```

`pg_stat_archiver.archived_count` debería incrementar con el tiempo.
`pg_stat_archiver.failed_count` debería quedarse en 0.
