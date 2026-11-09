#!/usr/bin/env bash
#
# Despliega la web en el servidor de la UGR por FTPS.
# Pensado para ejecutarse a mano o con cron desde un ordenador DENTRO de la red de la UGR.
#
# Qué hace:
#   1. Se baja la última versión de la rama main a un clon aparte
#      (NO toca tu carpeta de trabajo ni tus cambios sin subir).
#   2. Si no hay cambios desde el último despliegue, termina.
#   3. Construye la web con la dirección final y genera el buscador.
#   4. Sube el resultado por FTPS con lftp.
#
# Uso:
#   scripts/deploy-ugr.sh              despliega si hay cambios
#   scripts/deploy-ugr.sh --force      despliega aunque no haya cambios
#   scripts/deploy-ugr.sh --dry-run    construye y muestra qué subiría, sin subir nada
#
# Configuración: ~/.config/cvr-web-deploy.env  (ver scripts/deploy-ugr.env.example)
set -euo pipefail

CONFIG_FILE="${CVR_DEPLOY_CONFIG:-$HOME/.config/cvr-web-deploy.env}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cvr-web-deploy"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cvr-web-deploy"
CLONE_DIR="$CACHE_DIR/repo"           # copia de trabajo SOLO para desplegar
LAST_FILE="$STATE_DIR/last_deployed"  # commit que está publicado ahora mismo
LOCK_FILE="$STATE_DIR/lock"
EXPECTED_HUGO="${EXPECTED_HUGO:-0.161.1}"   # mantenla igual que en hugoblox.yaml
MIN_FILES="${MIN_FILES:-50}"          # si la web construida tiene menos archivos, se aborta

FORCE=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "El despliegue ha fallado (línea $LINENO). Se reintentará en la próxima ejecución."' ERR

# ── Configuración ────────────────────────────────────────────────────────────
# Los archivos con datos de acceso solo deben poder leerlos tu usuario.
check_private() {
  local mode; mode="$(stat -c '%a' "$1")"
  case "$mode" in 600|400) ;; *) die "$1 tiene permisos $mode; ejecuta: chmod 600 $1" ;; esac
}
[ -f "$CONFIG_FILE" ] || die "No existe $CONFIG_FILE (copia scripts/deploy-ugr.env.example)."
check_private "$CONFIG_FILE"
set -a; . "$CONFIG_FILE"; set +a
for v in REPO_URL SITE_URL FTPS_HOST FTPS_USER FTPS_REMOTE_DIR; do
  [ -n "${!v:-}" ] || die "Falta $v en $CONFIG_FILE"
done
BRANCH="${BRANCH:-main}"
FTPS_PORT="${FTPS_PORT:-21}"
# La contraseña (si no usas clave SSH) puede ir en un archivo aparte (FTPS_PASSWORD_FILE)
# o, como segunda opción, en FTPS_PASSWORD dentro de la configuración.
if [ -n "${FTPS_PASSWORD_FILE:-}" ]; then
  [ -f "$FTPS_PASSWORD_FILE" ] || die "No existe $FTPS_PASSWORD_FILE"
  check_private "$FTPS_PASSWORD_FILE"
  FTPS_PASSWORD="$(head -n 1 "$FTPS_PASSWORD_FILE")"
fi

# ── Programas necesarios ─────────────────────────────────────────────────────
for c in git node npm hugo lftp flock; do
  command -v "$c" >/dev/null 2>&1 || die "Falta el programa '$c' (en cron, revisa la variable PATH)."
done
HUGO_OUT="$(hugo version)"
case "$HUGO_OUT" in *"v$EXPECTED_HUGO"*) ;; *) die "Se necesita Hugo $EXPECTED_HUGO y hay: $HUGO_OUT" ;; esac
case "$HUGO_OUT" in *extended*) ;; *) die "Se necesita la versión 'extended' de Hugo." ;; esac

# ── Un solo despliegue a la vez ──────────────────────────────────────────────
mkdir -p "$STATE_DIR" "$CACHE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "Ya hay un despliegue en curso."; exit 0; }

# ── ¿Se llega al servidor? (si no estás en la red de la UGR, se sale sin error) ──
if ! timeout 10 bash -c ">/dev/tcp/$FTPS_HOST/$FTPS_PORT" 2>/dev/null; then
  log "No se alcanza $FTPS_HOST:$FTPS_PORT (¿fuera de la red de la UGR o sin VPN?). Se reintentará."
  exit 0
fi

# ── Última versión de main, en un clon aparte ────────────────────────────────
if [ ! -d "$CLONE_DIR/.git" ]; then
  log "Clonando $REPO_URL…"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$CLONE_DIR"
fi
cd "$CLONE_DIR"
git fetch --quiet origin "$BRANCH"
git reset --hard --quiet "origin/$BRANCH"
git clean -fdq
HEAD_SHA="$(git rev-parse HEAD)"
LAST_SHA="$(cat "$LAST_FILE" 2>/dev/null || true)"

if [ "$FORCE" -eq 0 ] && [ "$DRY" -eq 0 ] && [ "$HEAD_SHA" = "$LAST_SHA" ]; then
  log "Sin cambios desde el último despliegue (${HEAD_SHA:0:7})."
  exit 0
fi

# ── Construcción ─────────────────────────────────────────────────────────────
log "Construyendo ${HEAD_SHA:0:7} para $SITE_URL…"
npm install --no-audit --no-fund --silent
rm -rf public
HUGO_ENVIRONMENT=production hugo --minify --baseURL "$SITE_URL"
if grep -q "pagefind" package.json; then
  npm run --silent pagefind || npx --yes pagefind --site public
fi

# Comprobaciones de cordura: nunca se sube una web vacía o rota.
[ -f public/index.html ] || die "No se ha generado public/index.html."
N_FILES="$(find public -type f | wc -l)"
[ "$N_FILES" -ge "$MIN_FILES" ] || die "La web construida solo tiene $N_FILES archivos (mínimo $MIN_FILES)."
log "Web construida: $N_FILES archivos."

# ── Subida por FTPS ──────────────────────────────────────────────────────────
# Las órdenes de lftp se escriben en un archivo temporal que solo lee tu usuario
# y se borra al terminar. Así la contraseña no aparece en la lista de procesos.

lftp_quote() {
  local v="${1//\\/\\\\}"
  printf '"%s"' "${v//\"/\\\"}"
}

MIRROR="mirror --reverse --verbose --parallel=4"
[ "${FTPS_DELETE:-no}" = "yes" ] && MIRROR="$MIRROR --delete"
[ "$DRY" -eq 1 ] && MIRROR="$MIRROR --dry-run"

LFTP_CMDS="$(umask 077; mktemp "$STATE_DIR/lftp.XXXXXX")"
trap 'rm -f "$LFTP_CMDS"' EXIT

{
  echo "set cmd:fail-exit yes"
  echo "set net:max-retries 3"
  echo "set net:timeout 30"
  echo "set net:reconnect-interval-base 5"
  echo "set xfer:clobber yes"

  # Configuración FTPS explícito
  echo "set ftp:ssl-allow yes"
  echo "set ftp:ssl-force yes"
  echo "set ftp:ssl-protect-data yes"
  echo "set ftp:passive-mode true"

  # Verificación del certificado TLS
  echo "set ssl:verify-certificate yes"

  echo "open -p ${FTPS_PORT:-21} -u $(lftp_quote "$FTPS_USER,${FTPS_PASSWORD:-}") ftp://$FTPS_HOST"

  echo "$MIRROR public/ $(lftp_quote "$FTPS_REMOTE_DIR")"
  echo "bye"
} > "$LFTP_CMDS"

log "Subiendo por FTPS a $FTPS_USER@$FTPS_HOST:$FTPS_REMOTE_DIR$( [ "$DRY" -eq 1 ] && echo ' (simulación)' )…"

lftp -f "$LFTP_CMDS"

if [ "$DRY" -eq 1 ]; then
  log "Simulación terminada: no se ha subido nada."
  exit 0
fi

echo "$HEAD_SHA" > "$LAST_FILE"
log "Despliegue completado (${HEAD_SHA:0:7})."
