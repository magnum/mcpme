# shellcheck shell=bash
# Tunnel helpers sourced by mcpme.sh — Cloudflare Tunnel → local mcpme origin.

TUNNEL_LABEL="com.mcpme.tunnel"
TUNNEL_PLIST_DEST="${HOME}/Library/LaunchAgents/${TUNNEL_LABEL}.plist"
TUNNEL_SERVICE="${DOMAIN}/${TUNNEL_LABEL}"
TUNNEL_TEMPLATE="${SCRIPT_DIR}/share/launchd/com.mcpme.tunnel.plist.template"
TUNNEL_CONFIG_TEMPLATE="${SCRIPT_DIR}/share/cloudflared/config.yml.template"
DEFAULT_TUNNEL_NAME="mcpme"
DEFAULT_TUNNEL_HOSTNAME="mcpme.m6i.it"

env_get() {
  local key="$1" file="${2:-.env}"
  [[ -f "${file}" ]] || return 0
  grep -E "^${key}=" "${file}" | tail -1 | cut -d= -f2- || true
}

env_set() {
  local key="$1" value="$2" file="${3:-.env}"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "${file}" ]] && grep -qE "^${key}=" "${file}"; then
    awk -v k="${key}" -v v="${value}" '
      BEGIN { done=0 }
      $0 ~ "^"k"=" && !done { print k"="v; done=1; next }
      { print }
      END { if (!done) print k"="v }
    ' "${file}" >"${tmp}"
  else
    if [[ -f "${file}" ]]; then
      cat "${file}" >"${tmp}"
      printf '\n' >>"${tmp}"
    fi
    printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
  fi
  mv "${tmp}" "${file}"
}

tunnel_bootout_if_loaded() {
  if launchctl print "${TUNNEL_SERVICE}" >/dev/null 2>&1; then
    launchctl bootout "${TUNNEL_SERVICE}" 2>/dev/null || true
  fi
}

tunnel_loaded() {
  launchctl print "${TUNNEL_SERVICE}" >/dev/null 2>&1
}

require_tunnel_plist() {
  if [[ ! -f "${TUNNEL_PLIST_DEST}" ]]; then
    echo "error: tunnel LaunchAgent non installato (${TUNNEL_PLIST_DEST})." >&2
    echo "  esegui: ./mcpme.sh tunnel install" >&2
    exit 1
  fi
}

resolve_cloudflared() {
  local bin
  bin="$(command -v cloudflared || true)"
  if [[ -z "${bin}" && -x /opt/homebrew/bin/cloudflared ]]; then
    bin="/opt/homebrew/bin/cloudflared"
  fi
  if [[ -z "${bin}" && -x /usr/local/bin/cloudflared ]]; then
    bin="/usr/local/bin/cloudflared"
  fi
  if [[ -z "${bin}" ]]; then
    echo "error: cloudflared non trovato. Installa: brew install cloudflared" >&2
    exit 1
  fi
  printf '%s\n' "${bin}"
}

ensure_cloudflared_installed() {
  if command -v cloudflared >/dev/null 2>&1 || [[ -x /opt/homebrew/bin/cloudflared ]]; then
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: serve Homebrew per installare cloudflared." >&2
    exit 1
  fi
  echo "Installazione cloudflared via Homebrew..."
  brew install cloudflared
}

write_tunnel_config() {
  local workdir="$1" tunnel_id="$2" credentials_file="$3" hostname="$4" origin_port="$5"
  local dest="${workdir}/cloudflared/config.yml"
  mkdir -p "${workdir}/cloudflared"
  sed \
    -e "s|__TUNNEL_ID__|${tunnel_id}|g" \
    -e "s|__CREDENTIALS_FILE__|${credentials_file}|g" \
    -e "s|__TUNNEL_HOSTNAME__|${hostname}|g" \
    -e "s|__ORIGIN_PORT__|${origin_port}|g" \
    "${TUNNEL_CONFIG_TEMPLATE}" >"${dest}"
  echo "${dest}"
}

write_tunnel_plist() {
  local workdir="$1" dest="$2" cloudflared_bin="$3" config_file="$4"
  python3 - "${TUNNEL_TEMPLATE}" "${dest}" "${TUNNEL_LABEL}" "${workdir}" \
    "${cloudflared_bin}" "${config_file}" <<'PY'
import pathlib, plistlib, sys

template_path = pathlib.Path(sys.argv[1])
dest_path = pathlib.Path(sys.argv[2])
label = sys.argv[3]
workdir = sys.argv[4]
cf_bin = sys.argv[5]
config_file = sys.argv[6]

with template_path.open("rb") as fh:
    data = plistlib.load(fh)

data["Label"] = label
data["WorkingDirectory"] = workdir
data["ProgramArguments"] = [
    cf_bin,
    "--config",
    config_file,
    "--no-autoupdate",
    "tunnel",
    "run",
]
data["StandardOutPath"] = f"{workdir}/log/cloudflared.stdout.log"
data["StandardErrorPath"] = f"{workdir}/log/cloudflared.stderr.log"
data["RunAtLoad"] = True
data["KeepAlive"] = True
data["ThrottleInterval"] = 10
data["ProcessType"] = "Background"

with dest_path.open("wb") as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_XML)
PY
}

cmd_tunnel_setup() {
  require_macos
  require_repo_cwd
  ensure_cloudflared_installed

  local workdir cf tunnel_name hostname origin_port origin_host
  workdir="$(pwd -P)"
  cf="$(resolve_cloudflared)"
  tunnel_name="${TUNNEL_NAME:-$(env_get TUNNEL_NAME "${workdir}/.env")}"
  tunnel_name="${tunnel_name:-$DEFAULT_TUNNEL_NAME}"
  hostname="${TUNNEL_HOSTNAME:-$(env_get TUNNEL_HOSTNAME "${workdir}/.env")}"
  hostname="${hostname:-$DEFAULT_TUNNEL_HOSTNAME}"
  origin_port="$(env_get PORT "${workdir}/.env")"
  origin_port="${origin_port:-8765}"
  origin_host="$(env_get HOST "${workdir}/.env")"
  origin_host="${origin_host:-127.0.0.1}"

  mkdir -p "${workdir}/cloudflared" "${workdir}/log"

  if [[ ! -f "${HOME}/.cloudflared/cert.pem" ]]; then
    echo "Autenticazione Cloudflare (si apre il browser)..."
    echo "Se fallisce qui, esegui a mano:  cloudflared tunnel login"
    "${cf}" tunnel login
  else
    echo "cert.pem già presente in ~/.cloudflared"
  fi

  local tunnel_id credentials_src credentials_dst
  if "${cf}" tunnel list 2>/dev/null | awk 'NR>1 {print $1,$2}' | grep -qE "[[:space:]]${tunnel_name}$| ${tunnel_name} "; then
    tunnel_id="$("${cf}" tunnel list | awk -v n="${tunnel_name}" 'NR>1 && $2==n {print $1; exit}')"
    echo "tunnel esistente: ${tunnel_name} (${tunnel_id})"
  else
    echo "Creazione tunnel ${tunnel_name}..."
    # Output includes UUID; also creates ~/.cloudflared/<uuid>.json
    "${cf}" tunnel create "${tunnel_name}"
    tunnel_id="$("${cf}" tunnel list | awk -v n="${tunnel_name}" 'NR>1 && $2==n {print $1; exit}')"
  fi

  if [[ -z "${tunnel_id}" ]]; then
    echo "error: impossibile risolvere tunnel id per ${tunnel_name}" >&2
    "${cf}" tunnel list >&2 || true
    exit 1
  fi

  credentials_src="${HOME}/.cloudflared/${tunnel_id}.json"
  if [[ ! -f "${credentials_src}" ]]; then
    echo "error: credentials file mancante: ${credentials_src}" >&2
    exit 1
  fi
  credentials_dst="${workdir}/cloudflared/${tunnel_id}.json"
  cp "${credentials_src}" "${credentials_dst}"
  chmod 600 "${credentials_dst}"

  write_tunnel_config "${workdir}" "${tunnel_id}" "${credentials_dst}" "${hostname}" "${origin_port}" >/dev/null
  echo "config: ${workdir}/cloudflared/config.yml"

  echo "DNS route: ${hostname} → tunnel ${tunnel_name}"
  if ! "${cf}" tunnel route dns --overwrite-dns "${tunnel_name}" "${hostname}"; then
    echo "warning: route dns fallita — crea un CNAME ${hostname} → ${tunnel_id}.cfargotunnel.com in Cloudflare DNS" >&2
  fi

  if [[ -f "${workdir}/.env" ]]; then
    env_set MCP_BASE_URL "https://${hostname}" "${workdir}/.env"
    env_set TUNNEL_NAME "${tunnel_name}" "${workdir}/.env"
    env_set TUNNEL_HOSTNAME "${hostname}" "${workdir}/.env"
    env_set TUNNEL_ID "${tunnel_id}" "${workdir}/.env"
    # Keep local bind; public URL is MCP_BASE_URL for OAuth/Claude.
    echo "aggiornato MCP_BASE_URL=https://${hostname}"
  fi

  "${cf}" tunnel --config "${workdir}/cloudflared/config.yml" ingress validate || true

  echo
  echo "Setup tunnel completato."
  echo "  pubblico: https://${hostname}/mcp"
  echo "  origin:   https://${origin_host}:${origin_port} (noTLSVerify)"
  echo
  echo "Avvia i servizi:"
  echo "  ./mcpme.sh install          # server"
  echo "  ./mcpme.sh tunnel install   # cloudflared"
  echo "  ./mcpme.sh restart && ./mcpme.sh tunnel restart"
}

cmd_tunnel_install() {
  require_macos
  require_repo_cwd
  ensure_cloudflared_installed

  local workdir cf config_file tmp
  workdir="$(pwd -P)"
  cf="$(resolve_cloudflared)"
  config_file="${workdir}/cloudflared/config.yml"

  if [[ ! -f "${config_file}" ]]; then
    echo "error: manca ${config_file}" >&2
    echo "  esegui prima: ./mcpme.sh tunnel setup" >&2
    exit 1
  fi

  mkdir -p "${LAUNCH_AGENTS_DIR}" "${workdir}/log"
  tmp="$(mktemp)"
  write_tunnel_plist "${workdir}" "${tmp}" "${cf}" "${config_file}"

  tunnel_bootout_if_loaded
  cp "${tmp}" "${TUNNEL_PLIST_DEST}"
  rm -f "${tmp}"
  chmod 644 "${TUNNEL_PLIST_DEST}"
  : >"${workdir}/log/cloudflared.stdout.log"
  : >"${workdir}/log/cloudflared.stderr.log"

  launchctl bootstrap "${DOMAIN}" "${TUNNEL_PLIST_DEST}"
  launchctl enable "${TUNNEL_SERVICE}" 2>/dev/null || true
  launchctl kickstart -k "${TUNNEL_SERVICE}"

  echo "installato: ${TUNNEL_PLIST_DEST}"
  echo "servizio: ${TUNNEL_SERVICE}"
  echo "config: ${config_file}"
  echo "log: ${workdir}/log/cloudflared.stdout.log"
}

cmd_tunnel_uninstall() {
  require_macos
  tunnel_bootout_if_loaded
  if [[ -f "${TUNNEL_PLIST_DEST}" ]]; then
    rm -f "${TUNNEL_PLIST_DEST}"
    echo "rimosso: ${TUNNEL_PLIST_DEST}"
  else
    echo "nessun plist tunnel in ${TUNNEL_PLIST_DEST}"
  fi
  echo "servizio ${TUNNEL_LABEL} disinstallato"
}

cmd_tunnel_status() {
  require_macos
  require_tunnel_plist
  if tunnel_loaded; then
    launchctl print "${TUNNEL_SERVICE}"
  else
    echo "plist: ${TUNNEL_PLIST_DEST}"
    echo "stato: installato ma non caricato (fermato)"
    exit 1
  fi
}

cmd_tunnel_start() {
  require_macos
  require_tunnel_plist
  if tunnel_loaded; then
    launchctl kickstart -k "${TUNNEL_SERVICE}"
    echo "avviato: ${TUNNEL_SERVICE}"
  else
    launchctl bootstrap "${DOMAIN}" "${TUNNEL_PLIST_DEST}"
    launchctl enable "${TUNNEL_SERVICE}" 2>/dev/null || true
    launchctl kickstart -k "${TUNNEL_SERVICE}"
    echo "caricato e avviato: ${TUNNEL_SERVICE}"
  fi
}

cmd_tunnel_stop() {
  require_macos
  require_tunnel_plist
  if tunnel_loaded; then
    launchctl bootout "${TUNNEL_SERVICE}"
    echo "fermato: ${TUNNEL_SERVICE}"
  else
    echo "già fermo: ${TUNNEL_SERVICE}"
  fi
}

cmd_tunnel_restart() {
  require_macos
  require_tunnel_plist
  if tunnel_loaded; then
    launchctl kickstart -k "${TUNNEL_SERVICE}"
    echo "riavviato: ${TUNNEL_SERVICE}"
  else
    cmd_tunnel_start
  fi
}

cmd_tunnel_logs() {
  require_macos
  require_tunnel_plist
  local workdir
  workdir="$(python3 - "${TUNNEL_PLIST_DEST}" <<'PY'
import pathlib, plistlib, sys
data = plistlib.load(pathlib.Path(sys.argv[1]).open("rb"))
print(data.get("WorkingDirectory") or "")
PY
)"
  local out="${workdir}/log/cloudflared.stdout.log"
  local err="${workdir}/log/cloudflared.stderr.log"
  mkdir -p "${workdir}/log"
  touch "${out}" "${err}"
  echo "seguo: ${out}"
  echo "       ${err}"
  echo "(Ctrl-C per uscire)"
  tail -n 50 -F "${out}" "${err}"
}

cmd_tunnel() {
  local sub="${1:-}"
  case "${sub}" in
    ""|help|-h|--help)
      cat <<'EOF'
mcpme tunnel — Cloudflare Tunnel per mcpme.m6i.it

  ./mcpme.sh tunnel setup       Crea tunnel + DNS + config + aggiorna .env
  ./mcpme.sh tunnel install     LaunchAgent com.mcpme.tunnel
  ./mcpme.sh tunnel uninstall   Rimuove LaunchAgent tunnel
  ./mcpme.sh tunnel status|start|stop|restart|logs

Default hostname: mcpme.m6i.it  (override: TUNNEL_HOSTNAME=... o .env)
Default name:     mcpme         (override: TUNNEL_NAME=...)
EOF
      ;;
    setup) cmd_tunnel_setup ;;
    install) cmd_tunnel_install ;;
    uninstall) cmd_tunnel_uninstall ;;
    status) cmd_tunnel_status ;;
    start) cmd_tunnel_start ;;
    stop) cmd_tunnel_stop ;;
    restart) cmd_tunnel_restart ;;
    logs) cmd_tunnel_logs ;;
    *)
      echo "error: tunnel subcomando sconosciuto: ${sub}" >&2
      cmd_tunnel help >&2
      exit 1
      ;;
  esac
}
