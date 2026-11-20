# Scripts de automatización

Esta carpeta contiene lo que mantiene la web al día sin trabajo manual: la importación de
publicaciones, la subida de la web al servidor de la UGR y una herramienta de migración que
se usó una sola vez.

```
scripts/
├── README.md                    este archivo
├── deploy_ftp.sh                construye la web y la sube al servidor de la UGR (FTPS)
├── cvr-web-deploy.env.example       plantilla de la configuración del script anterior
├── migrate_from_wowchemy.py     Script auxiliar para la migración de wowchemy. No es necesario ejecutarlo más.
└── publications/
    ├── fetch_publications.py    busca publicaciones nuevas en OpenAlex
    ├── sources.yaml             investigadores seguidos y filtro de relevancia
    ├── seen.json                memoria de lo que ya se propuso (no se edita a mano)
    └── migrate_format_publications.py  migración auxiliar del formato de las publicaciones. Es utilizado por otros scripts.
```

## Cómo encajan las piezas

```
OpenAlex ─► fetch_publications.py ─► Pull Request ─► revisión y fusión en main
            (GitHub Actions, lunes)                          │
                                                             ▼
                          deploy_ftp.sh (cron, ordenador del laboratorio, red UGR)
                                                             │
                                                             ▼
                                            servidor de la UGR (FTPS) ─► web publicada
```

- Cada **lunes** GitHub busca publicaciones nuevas y abre una PR para revisarlas.
- Cuando alguien **fusiona** una PR en `main` (una publicación, un proyecto, una noticia, una
  persona...), la web no cambia sola: el siguiente despliegue desde el ordenador del
  laboratorio la construye y la sube.
- El servidor de la UGR solo acepta conexiones **desde la red de la UGR**, por eso el despliegue
  se ejecuta en un ordenador del laboratorio y no en GitHub.

---

## 1. `deploy_ftp.sh`: despliegue en el servidor de la UGR

### Qué hace

1. Se baja la última versión de `main` a un **clon aparte** (no toca tu carpeta de trabajo ni
   tus cambios sin subir).
2. Si no ha cambiado nada desde el último despliegue, termina.
3. Construye la web con la dirección final (`SITE_URL`) y genera el índice del buscador.
4. Sube **todos** los archivos por FTPS, uno a uno. Después de cada subida comprueba con el
   comando FTP `SIZE` que el tamaño en el servidor coincide con el local, y reintenta si no.
5. Comprueba por HTTP que **todo lo publicado es idéntico** a lo construido (páginas, imágenes,
   `.js`, `.css`...). Si algo falta, está vacío o cortado, falla y no da el despliegue por bueno.
6. Solo entonces anota el commit como publicado (`last_deployed`).

Si el servidor no se alcanza (por ejemplo, fuera de la red de la UGR o sin VPN), termina sin
error y lo intentará la próxima vez.

### Requisitos

Un ordenador Linux **dentro de la red de la UGR** con: `git`, `node` y `npm`, **Hugo extended
0.161.1** (la versión de `hugoblox.yaml`; el script se niega si es otra), `python3`, `curl`,
`flock` y `sha256sum`.

### Dónde se guarda cada cosa

Nada de esto está en el repositorio. Todo vive en el directorio personal de quien ejecuta el
script:

| Ruta | Qué contiene | Se puede borrar |
| --- | --- | --- |
| `~/.config/cvr-web-deploy.env` | **Configuración**: dirección de la web, servidor, usuario y carpeta de destino | No |
| `~/.config/cvr-web-deploy.pass` | **La contraseña** del FTPS (primera línea, nada más). Su ruta se indica en `FTPS_PASSWORD_FILE` | No |
| `~/.local/state/cvr-web-deploy/` | Estado: `last_deployed` (commit publicado), `lock` (evita dos ejecuciones a la vez) y, si usas cron, `deploy.log` | Sí, vuelve a subirlo todo |
| `~/.cache/cvr-web-deploy/repo/` | El clon donde se construye la web | Sí, se vuelve a clonar |

Las contraseñas y los datos de acceso están en `~/.config/`, **no** en `~/.local/`. Los dos
archivos de `~/.config/` deben tener permisos `600`: el script se niega a funcionar si otro
usuario del ordenador puede leerlos. Si cambias `XDG_CONFIG_HOME`, `XDG_STATE_HOME` o
`XDG_CACHE_HOME`, las rutas cambian en consecuencia.


### Primera puesta en marcha

```sh
# 1. Configuración (la plantilla está en esta carpeta)
mkdir -p ~/.config ~/.local/state/cvr-web-deploy
cp scripts/cvr-web-deploy.env.example ~/.config/cvr-web-deploy.env
chmod 600 ~/.config/cvr-web-deploy.env
# edita el archivo con los datos del servidor

# 2. Contraseña, en un archivo aparte
printf '%s\n' 'la-contraseña' > ~/.config/cvr-web-deploy.pass
chmod 600 ~/.config/cvr-web-deploy.pass

# 3. Prueba sin subir nada: construye y lista lo que subiría
scripts/deploy_ftp.sh --dry-run

# 4. Despliegue real
scripts/deploy_ftp.sh --force
```

### Opciones

| Comando | Qué hace |
| --- | --- |
| `scripts/deploy_ftp.sh` | Despliega solo si hay cambios en `main` |
| `scripts/deploy_ftp.sh --force` | Despliega aunque no haya cambios |
| `scripts/deploy_ftp.sh --dry-run` | Construye y lista los archivos que subiría. No se conecta al servidor |
| `scripts/deploy_ftp.sh --verify-only` | No construye ni sube nada: compara lo publicado con la última construcción y lista lo que no coincide |

### Variables de `cvr-web-deploy.env`

| Variable | Obligatoria | Significado |
| --- | --- | --- |
| `REPO_URL` | Sí | Repositorio del que se construye (se descarga por HTTPS) |
| `BRANCH` | No (`main`) | Rama que se despliega |
| `SITE_URL` | Sí | Dirección final de la web, con la `/` del final. Se escribe en el HTML y la usa la verificación |
| `FTPS_HOST`, `FTPS_USER` | Sí | Servidor y usuario |
| `FTPS_PORT` | No (`21`) | Puerto del servidor |
| `FTPS_PASSWORD_FILE` | Sí* | Archivo con la contraseña (*o `FTPS_PASSWORD`, menos seguro) |
| `FTPS_REMOTE_DIR` | Sí | Carpeta de destino, **relativa** a la carpeta personal del usuario FTP, sin `/` inicial y sin `..` (por ejemplo `public_html/`) |
| `FTPS_RETRIES` | No (`3`) | Reintentos por archivo |
| `VERIFY`, `VERIFY_SCOPE`, `VERIFY_MAX` | No | Verificación por HTTP: activar (`yes`/`no`), alcance (`all` o `assets`) y máximo de archivos |
| `MIN_FILES` | No (`50`) | Si la web construida tiene menos archivos, se aborta |
| `EXPECTED_HUGO` | No (`0.161.1`) | Versión de Hugo exigida |

### Seguridad

- Ni la contraseña ni la configuración están en el repositorio.
- La contraseña no aparece en la lista de procesos (`ps`): se pasa a `curl` mediante un archivo
  de configuración temporal, con permisos `600`, que se borra al terminar.
- La conexión es FTPS (cifrada) y `curl` verifica el certificado del servidor.
- Se recomienda usar una cuenta de despliegue propia, con permisos solo sobre la carpeta de la
  web, y no la cuenta personal de la UGR.

### Automatizarlo con cron

Con `crontab -e` (el script ya evita ejecuciones solapadas y sale rápido si no hay cambios):

```cron
MAILTO=""
PATH=/usr/local/bin:/usr/bin:/bin
0 9-18 * * 1-5 $HOME/cvr-lab-website/scripts/deploy_ftp.sh >> $HOME/.local/state/cvr-web-deploy/deploy.log 2>&1
```

Esa línea lo ejecuta cada hora, de 9:00 a 18:00, de lunes a viernes (en crontab, `$HOME` se
expande en el comando, pero no en las líneas de `PATH=`, que deben llevar rutas absolutas). Para ejecutarlo una sola vez
al día a las 10:00, usa `0 10 * * 1-5`. Notas:

- **`PATH`**: cron arranca con un `PATH` mínimo. Averigua dónde están tus programas con
  `command -v hugo node npm python3 curl flock git` y añade esas carpetas a la línea de `PATH`
  (si Node viene de `nvm`, su carpeta cuelga de `~/.nvm/versions/node/...`). Si falta alguno, el
  log dice `Falta el programa '...'`.
- La carpeta del log debe existir antes (`mkdir -p ~/.local/state/cvr-web-deploy`).
- El ordenador tiene que estar **encendido y en la red de la UGR** a esa hora. Cron no recupera
  ejecuciones perdidas.
- Para ver qué ha pasado: `tail -n 50 ~/.local/state/cvr-web-deploy/deploy.log`.
- Para ver que cron ha lanzado el trabajo: `grep CRON /var/log/syslog` (o `journalctl -u cron`).

**Alternativa que sí recupera ejecuciones perdidas**: un temporizador de systemd de usuario.
Crea `~/.config/systemd/user/cvr-web-deploy.service`:

```ini
[Unit]
Description=Despliegue de la web del CVR Lab

[Service]
Type=oneshot
ExecStart=%h/cvr-lab-website/scripts/deploy_ftp.sh
```

y `~/.config/systemd/user/cvr-web-deploy.timer`:

```ini
[Unit]
Description=Despliegue de la web del CVR Lab (días laborables)

[Timer]
OnCalendar=Mon..Fri *-*-* 10:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now cvr-web-deploy.timer
journalctl --user -u cvr-web-deploy.service   # registro
```

Con `Persistent=true`, si el ordenador estaba apagado a las 10:00, se ejecuta al encenderlo.
Si Hugo o Node no están en el `PATH` de systemd, añade una línea `Environment=PATH=...` en la
sección `[Service]`.

### Si algo falla

| Mensaje del log | Causa y qué hacer |
| --- | --- |
| `... tiene permisos 644; ejecuta: chmod 600 ...` | La configuración o la contraseña son legibles por otros. Ejecuta el `chmod` que indica |
| `Falta el programa '...'` | No está instalado, o cron no lo encuentra: revisa el `PATH` |
| `Se necesita Hugo 0.161.1 y hay: ...` | Versión de Hugo distinta. Instala la 0.161.1 *extended* |
| `No se alcanza ... (¿fuera de la red de la UGR o sin VPN?)` | No es un error: reintenta en la próxima ejecución |
| `La web construida solo tiene N archivos` | La construcción ha salido mal. Mira el log de Hugo justo encima |
| `tamaño remoto incorrecto o no verificable` | El servidor cortó o no confirmó la subida. Se reintenta solo; si persiste, revisa cuota de disco y límites de conexión con el servicio informático |
| `NO COINCIDE: <archivo> (local: N bytes, web: M bytes)` | Lo publicado no es lo construido. Si `M` es 0 o menor, el archivo está vacío o cortado; si dice `no responde`, falta. Repite con `--force`; si sigue igual puede ser una caché del servidor web |
| `Subida incompleta ...` | Un archivo falló todos los reintentos. No se marca como publicado; se reintentará |

### Limitaciones conocidas

- **No borra** del servidor los archivos que ya no existen en la web (por ejemplo, versiones
  antiguas de archivos con huella en el nombre). Se acumulan y hay que limpiarlos a mano de vez en
  cuando.
- Sube **todos** los archivos en cada despliegue y de uno en uno, así que puede tardar varios
  minutos. Por eso solo se ejecuta cuando hay cambios en `main`.
- Solo despliega lo que está en `main` y en GitHub: lo que tengas en tu carpeta de trabajo sin
  subir no se publica.

---

## 2. `publications/`: importación de publicaciones

`fetch_publications.py` busca las publicaciones de los investigadores en
[OpenAlex](https://openalex.org) (un catálogo abierto con API oficial), se queda con las que
tienen que ver con el laboratorio y las propone en una Pull Request. **No publica nada
directamente**: alguien las revisa y las fusiona.

### Cómo se ejecuta

- **Automáticamente**, cada lunes a las 06:00 UTC, con el workflow
  `.github/workflows/weekly-publications.yml` (también desde *Actions → Run workflow*). El
  workflow instala `pyyaml`, `python-dotenv` y `academic`, ejecuta el script, genera las páginas
  con `academic import` y abre **una sola PR** con todo.
- **A mano**, para probar el filtro sin escribir nada:

  ```sh
  pip install pyyaml python-dotenv
  python scripts/publications/fetch_publications.py --dry-run --report /tmp/informe.md
  ```

  `--dry-run` consulta OpenAlex pero no escribe el `.bib` ni `seen.json`.

### La clave de OpenAlex

OpenAlex exige una clave gratuita (se crea en `openalex.org/settings/api`).

| Dónde | Cómo |
| --- | --- |
| **GitHub Actions** | Secreto del repositorio `OPENALEX_API_KEY` (*Settings → Secrets and variables → Actions*) |
| **En tu ordenador** | Archivo `.env` en la raíz del repositorio con una línea `OPENALEX_API_KEY=tu_clave`. Está en `.gitignore`: no lo subas. Con `--env RUTA` se puede usar otro archivo |

Nunca escribas la clave en `sources.yaml` ni en ningún archivo del repositorio.

### Qué hace, paso a paso

1. Lee `sources.yaml` (investigadores y filtro).
2. Pide a OpenAlex los trabajos de cada persona desde su año `since`.
3. Junta los trabajos sin repetir los que firma más de una persona.
4. Descarta lo que no toca: tipos de documento sin interés, DOIs excluidos, lo que ya está en
   `content/publications/` o en `seen.json`, trabajos en los que ningún miembro del laboratorio
   figura con la institución exigida, y los preprints que ya tienen versión publicada.
5. **Puntúa** cada trabajo según las palabras clave del laboratorio y propone los que llegan al
   umbral.
6. Escribe los aceptados en un `.bib` temporal, que el workflow convierte en páginas.
7. Escribe el informe (será la descripción de la PR) y actualiza `seen.json`.

### `sources.yaml`

Es el único archivo que hay que tocar para cambiar a quién se sigue y cómo se filtra.

| Sección | Para qué sirve |
| --- | --- |
| `people` | Cada investigador: `name` (igual que el `name.display` de su ficha en `data/authors/`), `orcid` (o `openalex`), `since` (año desde el que se importa) y, opcionalmente, `bib_name`, `aliases`, `threshold` y `exclude_keywords` propios |
| `settings` | `threshold` (umbral), pesos de cada señal, `institution_ror` (institución exigida; la UGR es `https://ror.org/04njjy449`; vacío para no exigirla), `require_strong_keyword`, `exclude_types` |
| `keywords` | Palabras **principales** del laboratorio: dan 3 puntos en el título y 1 en el resumen |
| `weak_keywords` | Palabras **genéricas** (`robot`, `ros`...): suman como mucho 1 punto en total, nunca bastan solas |
| `exclude_keywords` | Palabras de **otras áreas**: restan 4 puntos cada una. Un `*` final busca por prefijo (`cerebell*`) |
| `topics` | Fragmentos de los temas que asigna OpenAlex (segunda opinión) |
| `include_dois`, `exclude_dois` | Correcciones manuales: se proponen siempre / no se proponen nunca |

**Para añadir a alguien**, copia un bloque de `people` y pon su ORCID. El `name` debe coincidir con
su ficha en `data/authors/`, para que las publicaciones enlacen con su perfil. Sin ORCID ni
`openalex`, el script lo omite con un aviso.

**Para ajustar el filtro**: lanza `--dry-run`, mira la columna *Motivos* del informe y ajusta. Si se
cuela algo, pasa su palabra a `weak_keywords` o añade una palabra característica a
`exclude_keywords`. Si falta algo bueno, baja el umbral o añade su DOI a `include_dois`. El informe
también lista, plegados, los trabajos que se quedaron cerca del umbral y los de puntuación muy baja.

### `seen.json`

Es la **memoria** del script: guarda los trabajos que ya se propusieron (identificador, DOI,
título y fecha) para no volver a proponerlos. Se actualiza solo, dentro de la PR. Cuando alguien
descarta una publicación borrando su carpeta en la PR, queda anotada aquí y no vuelve a salir.
No se edita a mano; para que una publicación vuelva a proponerse, borra su entrada.

---

## 3. `publications/migrate_from_wowchemy.py`: migración puntual

Herramienta de **uso único**, de cuando la web se migró de Wowchemy a HugoBlox. Convierte el
encabezado (*front matter*) antiguo de cada `content/publications/*/index.md` al formato actual:

- `publication: "Nombre de la revista"` pasa a `publication: {name: "Nombre de la revista"}`;
- `volume`, `issue`, `pages` y `publisher` pasan a estar dentro de `publication`;
- `doi` pasa a `hugoblox.ids.doi`.

```sh
pip install ruamel.yaml
python scripts/publications/migrate_from_wowchemy.py                  # content/publications
python scripts/publications/migrate_from_wowchemy.py otra/carpeta     # otra carpeta
git diff                                                             # revisa antes de confirmar
```

Es seguro repetirlo: solo modifica los archivos que aún tienen el formato antiguo. Si un archivo
tiene dos DOI distintos, se detiene con un error. Hoy no hace falta ejecutarlo, porque las
publicaciones nuevas ya se generan en el formato correcto; se conserva por si hay que migrar
contenido antiguo.