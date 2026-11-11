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
#   5. Comprueba por HTTP que TODOS los archivos (páginas, imágenes, .js, .css…) se ven
#      IGUAL que en local. Si alguno falta, está vacío o cortado, falla y se reintenta.
#
# Uso:
#   scripts/deploy-ugr.sh               despliega si hay cambios
#   scripts/deploy-ugr.sh --force       despliega aunque no haya cambios
#   scripts/deploy-ugr.sh --dry-run     construye y muestra qué subiría, sin subir nada
#   scripts/deploy-ugr.sh --verify-only NO construye ni sube: solo compara lo publicado en la
#                                       web con la última construcción (lista lo que falla)
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
VERIFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force)       FORCE=1 ;;
    --dry-run)     DRY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "El despliegue ha fallado (línea $LINENO). Se reintentará en la próxima ejecución."' ERR

# ── Verificación por HTTP ────────────────────────────────────────────────────
# Codifica una ruta para usarla en una URL (espacios, tildes, etc.).
urlenc() {
  local LC_ALL=C s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_/-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Compara cada archivo de public/ con lo que sirve la web. Deja el resultado en BAD y CHECKED.
# VERIFY_SCOPE=all (por defecto) revisa todo; VERIFY_SCOPE=assets solo .js, .css y .json.
verify_site() {
  local pub="$CLONE_DIR/public" scope="${VERIFY_SCOPE:-all}" max="${VERIFY_MAX:-100000}"
  local rel local_sum web_sum web_bytes tmp types
  tmp="$(mktemp)"; types="$(mktemp)"
  BAD=0; CHECKED=0
  log "Verificando por HTTP los archivos publicados en $SITE_URL (puede tardar un par de minutos)…"
  while IFS= read -r rel; do
    [ "$CHECKED" -lt "$max" ] || break
    CHECKED=$((CHECKED + 1))
    local_sum="$(sha256sum < "$pub/$rel" | cut -d' ' -f1)"
    if curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' -o "$tmp" "${SITE_URL}$(urlenc "$rel")" 2>/dev/null; then
      web_sum="$(sha256sum < "$tmp" | cut -d' ' -f1)"; web_bytes="$(wc -c < "$tmp") bytes"
    else
      web_sum="-"; web_bytes="no responde"
    fi
    if [ "$local_sum" != "$web_sum" ]; then
      log "  NO COINCIDE: $rel (local: $(wc -c < "$pub/$rel") bytes, web: $web_bytes)"
      BAD=$((BAD + 1)); echo "${rel##*.}" >> "$types"
    fi
  done < <(cd "$pub" && if [ "$scope" = "all" ]; then find . -type f; \
           else find . -type f \( -name '*.js' -o -name '*.css' -o -name '*.json' \); fi | sed 's#^\./##' | sort)
  if [ "$BAD" -gt 0 ]; then
    log "Resumen por tipo de archivo: $(sort "$types" | uniq -c | sort -rn | awk '{printf "%s: %s  ", $2, $1}')"
  fi
  rm -f "$tmp" "$types"
}

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

# Modo --verify-only: no construye ni sube nada; solo compara la web publicada con la
# última construcción guardada en el clon de despliegue.
if [ "$VERIFY_ONLY" -eq 1 ]; then
  for c in curl sha256sum; do command -v "$c" >/dev/null 2>&1 || die "Falta el programa '$c'."; done
  [ -d "$CLONE_DIR/public" ] || die "No hay ninguna construcción en $CLONE_DIR/public (ejecuta antes el despliegue o --dry-run)."
  mkdir -p "$STATE_DIR"
  verify_site
  if [ "$BAD" -ne 0 ]; then
    log "$BAD de $CHECKED archivos NO coinciden con lo publicado."
    log "Para volver a subir solo esos archivos:  scripts/upload-files.sh --from-log <archivo con estas líneas>"
    exit 1
  fi
  log "Todo coincide ($CHECKED archivos comprobados)."
  exit 0
fi
# La contraseña puede ir en un archivo aparte (FTPS_PASSWORD_FILE, lo recomendable)
# o, como segunda opción, en FTPS_PASSWORD dentro de la configuración.
if [ -n "${FTPS_PASSWORD_FILE:-}" ]; then
  [ -f "$FTPS_PASSWORD_FILE" ] || die "No existe $FTPS_PASSWORD_FILE"
  check_private "$FTPS_PASSWORD_FILE"
  FTPS_PASSWORD="$(head -n 1 "$FTPS_PASSWORD_FILE")"
fi

# ── Programas necesarios ─────────────────────────────────────────────────────
for c in git node npm hugo python3 flock curl sha256sum; do
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


# ── Subida por FTPS mediante cURL ────────────────────────────────────────────

# Comprobamos que el directorio remoto sea relativo al directorio personal.
REMOTE_BASE="${FTPS_REMOTE_DIR#/}"
REMOTE_BASE="${REMOTE_BASE%/}"

case "$REMOTE_BASE" in
  ""|..|../*|*/../*|*/..)
    die "FTPS_REMOTE_DIR debe ser una ruta relativa válida, por ejemplo public_html/."
    ;;
esac

# Configuración privada de cURL. Evitamos poner la contraseña en los argumentos
# del proceso, donde podría aparecer en ps.
curl_config_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

CURL_CONFIG=""

if [ "$DRY" -eq 0 ]; then
  CURL_CONFIG="$(umask 077; mktemp "$STATE_DIR/curl.XXXXXX")"

  {
    printf 'user = "%s:%s"\n' \
      "$(curl_config_escape "$FTPS_USER")" \
      "$(curl_config_escape "${FTPS_PASSWORD:-}")"
  } > "$CURL_CONFIG"

  trap 'rm -f "$CURL_CONFIG"' EXIT
fi

# Convierte rutas locales en rutas URL válidas, conservando los separadores.
url_encode_path() {
  python3 -c \
    'import sys; from urllib.parse import quote; print(quote(sys.argv[1], safe="/"))' \
    "$1"
}

# URL relativa al directorio personal FTP:
# /./public_html equivale a entrar en public_html desde el home FTP.
remote_url() {
  local relative_path="$1"
  local encoded_path

  encoded_path="$(url_encode_path "$relative_path")"

  printf 'ftp://%s:%s/./%s/%s' \
    "$FTPS_HOST" "$FTPS_PORT" "$REMOTE_BASE" "$encoded_path"
}

# Comprueba el tamaño real del archivo almacenado en el FTP mediante SIZE.
remote_size() {
  local url="$1"
  local headers

  if ! headers="$(
    curl --disable \
      --silent --show-error --fail \
      --ssl-reqd --ftp-pasv \
      --connect-timeout 20 --max-time 60 \
      --config "$CURL_CONFIG" \
      --head "$url" 2>/dev/null
  )"; then
    return 1
  fi

  printf '%s\n' "$headers" |
    awk 'tolower($1) == "content-length:" {
      gsub("\r", "", $2)
      print $2
      exit
    }'
}

upload_one() {
  local relative_path="$1"
  local local_file="$CLONE_DIR/public/$relative_path"
  local url local_size server_size
  local attempt max_attempts

  max_attempts="${FTPS_RETRIES:-3}"
  local_size="$(stat -c '%s' "$local_file")"
  url="$(remote_url "$relative_path")"

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    log "Subiendo ($attempt/$max_attempts): $relative_path ($local_size bytes)"

    if curl --disable \
      --silent --show-error --fail \
      --ssl-reqd --ftp-pasv --ftp-create-dirs \
      --connect-timeout 20 --max-time 300 \
      --config "$CURL_CONFIG" \
      --upload-file "$local_file" \
      "$url"; then

      if server_size="$(remote_size "$url")" &&
         [ -n "$server_size" ] &&
         [ "$server_size" = "$local_size" ]; then

        log "  OK: $relative_path ($server_size bytes)"
        return 0
      fi

      log "  ERROR: tamaño remoto incorrecto o no verificable para $relative_path"
      log "  Local: $local_size bytes | Remoto: ${server_size:-no disponible}"
    else
      log "  ERROR: cURL no pudo subir $relative_path"
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      log "  Reintentando en 3 segundos..."
      sleep 3
    fi
  done

  log "ERROR DEFINITIVO: no se pudo verificar $relative_path"
  return 1
}

# En modo simulación no se conecta ni modifica el servidor.
if [ "$DRY" -eq 1 ]; then
  log "Simulación: archivos que se subirían a $FTPS_HOST/$REMOTE_BASE/"

  while IFS= read -r -d '' file; do
    printf '  %s\n' "${file#./}"
  done < <(cd "$CLONE_DIR/public" && find . -type f -print0)

  log "Simulación terminada: no se ha subido nada."
  exit 0
fi

# Subimos todos los archivos secuencialmente.
UPLOAD_COUNT=0
UPLOAD_FAILED=0

log "Iniciando subida FTPS a $FTPS_HOST:$FTPS_PORT/$REMOTE_BASE/"
log "Verificación individual mediante FTP SIZE activada."

while IFS= read -r -d '' file; do
  relative_path="${file#./}"

  if upload_one "$relative_path"; then
    UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
  else
    UPLOAD_FAILED=$((UPLOAD_FAILED + 1))
    break
  fi
done < <(cd "$CLONE_DIR/public" && find . -type f -print0 | sort -z)

if [ "$UPLOAD_FAILED" -ne 0 ]; then
  die "Subida incompleta. Se han verificado $UPLOAD_COUNT archivos y ha fallado al menos uno. No se marcará el commit como publicado."
fi

log "Subida FTPS completada: $UPLOAD_COUNT archivos verificados."
# ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

if [ "$DRY" -eq 1 ]; then
  log "Simulación terminada: no se ha subido nada."
  exit 0
fi

# ── Verificación: lo que sirve la web debe ser idéntico a lo construido ──────
# Un archivo que falta, vacío o cortado en el servidor hace que el navegador bloquee la web.
if [ "${VERIFY:-yes}" = "yes" ]; then
  verify_site
  if [ "$BAD" -ne 0 ]; then
    log "Pistas: si por FTPS el archivo tiene el tamaño correcto pero por HTTP se sirve mal, la causa"
    log "es una caché del servidor web (pide que la vacíen). Si ya está mal por FTPS, es la subida."
    die "$BAD de $CHECKED archivos no coinciden con los publicados."
  fi
  log "Verificación correcta ($CHECKED archivos comprobados)."
fi

echo "$HEAD_SHA" > "$LAST_FILE"
log "Despliegue completado (${HEAD_SHA:0:7})."