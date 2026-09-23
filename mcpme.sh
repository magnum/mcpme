#!/usr/bin/env bash
# mcpme.sh — gestisce mcpme come macOS LaunchAgent
set -euo pipefail

LABEL="com.mcpme.server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/share/launchd/com.mcpme.server.plist.template"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_DEST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
SERVICE="${DOMAIN}/${LABEL}"

# shellcheck source=share/mcpme-tunnel.sh
source "${SCRIPT_DIR}/share/mcpme-tunnel.sh"

usage() {
  cat <<'EOF'
mcpme — MCP server Ruby con OAuth e tool shell (run_shell via backticks).

Permette di eseguire comandi shell sul proprio PC (la macchina dove gira
il server). Espone un endpoint Streamable HTTP autenticato OAuth 2.1
(credenziali OAUTH_USER / OAUTH_PASSWORD da .env) e restituisce output
e exit status dei comandi.

Usage:
  mcpme.sh                 Mostra questo aiuto
  mcpme.sh install         Installa e avvia LaunchAgent server (+ tunnel se configurato)
  mcpme.sh uninstall       Ferma e rimuove LaunchAgent server (+ tunnel)
  mcpme.sh status          Mostra stato LaunchAgent server
  mcpme.sh start|stop|restart|logs
  mcpme.sh cert            Certificato locale mkcert (origin HTTPS)
  mcpme.sh test-push       Invia push Pushover di prova (IP 127.0.0.1)
  mcpme.sh tunnel ...      Cloudflare Tunnel (mcpme.m6i.it → :8765)

Opzioni:
  install      Genera ~/Library/LaunchAgents/com.mcpme.server.plist
               e, se esiste cloudflared/config.yml, installa anche
               com.mcpme.tunnel.
  uninstall    Rimuove server e tunnel LaunchAgent.
  cert         Cert origin locale (mkcert) per HTTPS su 127.0.0.1.
  test-push    Invia notifica Pushover con link confirm-ip per 127.0.0.1
               e verifica che add all'allowlist non crei duplicati.
  tunnel setup|install|uninstall|status|start|stop|restart|logs
               Tunnel nominato Cloudflare verso la porta locale.
               Default hostname: mcpme.m6i.it

Flusso tipico per Claude (URL pubblico HTTPS):

  ./mcpme.sh cert
  ./mcpme.sh tunnel setup      # apre browser per login Cloudflare
  ./mcpme.sh install           # server + tunnel
  # URL Claude: https://mcpme.m6i.it/mcp
EOF
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: mcpme.sh richiede macOS (launchctl)." >&2
    exit 1
  fi
}

require_repo_cwd() {
  if [[ ! -f "${PWD}/bin/server" || ! -f "${PWD}/Gemfile" ]]; then
    echo "error: esegui questo comando dalla root del repo mcpme (cartella corrente)." >&2
    echo "  atteso: ${PWD}/bin/server e ${PWD}/Gemfile" >&2
    exit 1
  fi
  if [[ ! -f "${TEMPLATE}" ]]; then
    echo "error: template LaunchAgent non trovato: ${TEMPLATE}" >&2
    exit 1
  fi
}

require_plist() {
  if [[ ! -f "${PLIST_DEST}" ]]; then
    echo "error: LaunchAgent non installato (${PLIST_DEST})." >&2
    echo "  esegui prima: ./mcpme.sh install" >&2
    exit 1
  fi
}

service_loaded() {
  launchctl print "${SERVICE}" >/dev/null 2>&1
}

bootout_if_loaded() {
  if service_loaded; then
    launchctl bootout "${SERVICE}" 2>/dev/null || true
  fi
}

plist_workdir() {
  python3 - "${PLIST_DEST}" <<'PY'
import pathlib, plistlib, sys
data = plistlib.load(pathlib.Path(sys.argv[1]).open("rb"))
print(data.get("WorkingDirectory") or "")
PY
}

write_plist() {
  local workdir="$1"
  local dest="$2"
  local bundle_bin="$3"
  local ruby_bin="$4"
  local path_env="$5"

  python3 - "${TEMPLATE}" "${dest}" "${LABEL}" "${workdir}" \
    "${bundle_bin}" "${ruby_bin}" "${path_env}" <<'PY'
import pathlib
import plistlib
import sys

template_path = pathlib.Path(sys.argv[1])
dest_path = pathlib.Path(sys.argv[2])
label = sys.argv[3]
workdir = sys.argv[4]
bundle_bin = sys.argv[5]
ruby_bin = sys.argv[6]
path_env = sys.argv[7]

with template_path.open("rb") as fh:
    data = plistlib.load(fh)

data["Label"] = label
data["WorkingDirectory"] = workdir
# Absolute mise/ruby paths — launchd PATH is minimal and would pick /usr/bin/bundle (system Ruby 2.6).
data["ProgramArguments"] = [
    bundle_bin,
    "exec",
    ruby_bin,
    "bin/server",
]
data["EnvironmentVariables"] = {
    "PATH": path_env,
    "LANG": "en_US.UTF-8",
}
data["StandardOutPath"] = f"{workdir}/log/mcpme.stdout.log"
data["StandardErrorPath"] = f"{workdir}/log/mcpme.stderr.log"
data["RunAtLoad"] = True
data["KeepAlive"] = True
data["ThrottleInterval"] = 10
data["ProcessType"] = "Background"

with dest_path.open("wb") as fh:
    plistlib.dump(data, fh, fmt=plistlib.FMT_XML)
PY
}

resolve_ruby_tools() {
  local bundle_bin ruby_bin
  bundle_bin="$(command -v bundle || true)"
  ruby_bin="$(command -v ruby || true)"

  if [[ -z "${bundle_bin}" || -z "${ruby_bin}" ]]; then
    echo "error: bundle/ruby non trovati nel PATH della shell corrente." >&2
    echo "  apri un terminale con mise/rbenv attivo e riesegui ./mcpme.sh install" >&2
    exit 1
  fi

  if [[ "${bundle_bin}" == /usr/bin/bundle || "${ruby_bin}" == /usr/bin/ruby ]]; then
    echo "error: stai usando il Ruby di sistema (${ruby_bin})." >&2
    echo "  serve il Ruby del progetto (es. mise). Verifica: ruby -v && command -v bundle" >&2
    exit 1
  fi

  printf '%s\n%s\n' "${bundle_bin}" "${ruby_bin}"
}

cmd_install() {
  require_macos
  require_repo_cwd

  local workdir bundle_bin ruby_bin
  workdir="$(pwd -P)"

  {
    read -r bundle_bin
    read -r ruby_bin
  } < <(resolve_ruby_tools)

  mkdir -p "${LAUNCH_AGENTS_DIR}"
  mkdir -p "${workdir}/log"

  if [[ ! -f "${workdir}/.env" ]]; then
    echo "warning: ${workdir}/.env assente — il server potrebbe non avviarsi senza OAUTH_USER/OAUTH_PASSWORD." >&2
  fi

  local tmp
  tmp="$(mktemp)"
  # Keep current interactive PATH so gems/mise shims resolve under launchd.
  write_plist "${workdir}" "${tmp}" "${bundle_bin}" "${ruby_bin}" "${PATH}"

  bootout_if_loaded
  cp "${tmp}" "${PLIST_DEST}"
  rm -f "${tmp}"
  chmod 644 "${PLIST_DEST}"

  # Truncate crash-loop noise from previous broken installs.
  : >"${workdir}/log/mcpme.stderr.log"
  : >"${workdir}/log/mcpme.stdout.log"

  launchctl_load "${SERVICE}" "${PLIST_DEST}"
  launchctl kickstart -k "${SERVICE}"

  echo "installato: ${PLIST_DEST}"
  echo "working directory: ${workdir}"
  echo "bundle: ${bundle_bin}"
  echo "ruby:   ${ruby_bin}"
  echo "servizio: ${SERVICE}"
  echo "log: ${workdir}/log/mcpme.stdout.log"
  echo "     ${workdir}/log/mcpme.stderr.log"

  if [[ -f "${workdir}/cloudflared/config.yml" ]]; then
    echo
    echo "Trovato cloudflared/config.yml — installo anche il tunnel..."
    cmd_tunnel_install
  else
    echo
    echo "hint: per Claude/public URL → ./mcpme.sh tunnel setup && ./mcpme.sh tunnel install"
  fi
}

cmd_uninstall() {
  require_macos

  if [[ -f "${TUNNEL_PLIST_DEST}" ]] || tunnel_loaded 2>/dev/null; then
    cmd_tunnel_uninstall || true
  fi

  bootout_if_loaded

  if [[ -f "${PLIST_DEST}" ]]; then
    rm -f "${PLIST_DEST}"
    echo "rimosso: ${PLIST_DEST}"
  else
    echo "nessun plist trovato in ${PLIST_DEST}"
  fi

  echo "servizio ${LABEL} disinstallato"
}

cmd_status() {
  require_macos
  require_plist

  if service_loaded; then
    launchctl print "${SERVICE}"
  else
    echo "plist: ${PLIST_DEST}"
    echo "stato: installato ma non caricato (fermato)"
    echo "avvia con: ./mcpme.sh start"
    exit 1
  fi
}

cmd_start() {
  require_macos
  require_plist

  if service_loaded; then
    launchctl kickstart -k "${SERVICE}"
    echo "avviato (kickstart): ${SERVICE}"
  else
    launchctl_load "${SERVICE}" "${PLIST_DEST}"
    launchctl kickstart -k "${SERVICE}"
    echo "caricato e avviato: ${SERVICE}"
  fi
}

cmd_stop() {
  require_macos
  require_plist

  if service_loaded; then
    launchctl bootout "${SERVICE}"
    echo "fermato: ${SERVICE}"
  else
    echo "già fermo: ${SERVICE}"
  fi
}

cmd_restart() {
  require_macos
  require_plist

  if service_loaded; then
    launchctl kickstart -k "${SERVICE}"
    echo "riavviato: ${SERVICE}"
  else
    cmd_start
  fi
}

cmd_logs() {
  require_macos
  require_plist

  local workdir log_file stderr_log
  workdir="$(plist_workdir)"
  if [[ -z "${workdir}" ]]; then
    echo "error: WorkingDirectory assente nel plist ${PLIST_DEST}" >&2
    exit 1
  fi

  log_file="${workdir}/log/mcpme.log"
  stderr_log="${workdir}/log/mcpme.stderr.log"
  mkdir -p "${workdir}/log"
  touch "${log_file}" "${stderr_log}"

  echo "seguo: ${log_file}"
  echo "       ${stderr_log}"
  echo "(Ctrl-C per uscire)"
  tail -n 50 -F "${log_file}" "${stderr_log}"
}

cmd_test_push() {
  require_repo_cwd

  if [[ ! -f "${PWD}/.env" ]]; then
    echo "error: .env assente — copia .env.example e configura PUSHOVER_* / SECRET_KEY" >&2
    exit 1
  fi

  echo "test-push: invio Pushover per IP 127.0.0.1 + check anti-duplicati allowlist..."
  bundle exec ruby <<'RUBY'
# frozen_string_literal: true

require_relative "lib/mcpme"

TEST_IP = "127.0.0.1"

config = Mcpme::Config.load
if config.secret_key.to_s.empty?
  warn "error: SECRET_KEY vuota in .env"
  exit 1
end

pushover = Mcpme::Pushover.new(
  token: config.pushover_token,
  user: config.pushover_user,
  device: config.pushover_device
)
unless pushover.configured?
  warn "error: configura PUSHOVER_TOKEN e PUSHOVER_USER in .env"
  exit 1
end

path = File.expand_path(config.allowed_remote_ips_path, Dir.pwd)
allowlist = Mcpme::IpAllowlist.new(path: path)
confirm = Mcpme::IpConfirm.new(config: config, allowlist: allowlist)
url = confirm.confirm_url(TEST_IP)

puts "IP:        #{TEST_IP}"
puts "allowlist: #{path}"
puts "url:       #{url}"
puts

before = allowlist.exact_count(TEST_IP)
first = allowlist.add!(TEST_IP)
after_first = allowlist.exact_count(TEST_IP)
second = allowlist.add!(TEST_IP)
after_second = allowlist.exact_count(TEST_IP)

puts "allowlist add #1: #{first ? "scritto" : "già coperto / presente"} (count=#{after_first}, before=#{before})"
puts "allowlist add #2: #{second ? "scritto" : "skip duplicato"} (count=#{after_second})"

if second
  warn "error: il secondo add! non doveva scrivere una riga"
  exit 1
end
if after_second > 1
  warn "error: trovate #{after_second} righe duplicate per #{TEST_IP}"
  exit 1
end
if first && after_first != 1
  warn "error: dopo il primo add! atteso count=1, got #{after_first}"
  exit 1
end

puts "anti-duplicato: OK"
puts

begin
  pushover.send_message(
    title: "mcpme — confirm ip",
    message: url,
    url: url,
    url_title: "Confirm IP"
  )
  puts "Pushover: inviata. Apri la notifica (o l'URL sopra) e usa Confirm / Cancel."
rescue StandardError => e
  warn "error: Pushover fallito: #{e.class}: #{e.message}"
  exit 1
end
RUBY
}

cmd_cert() {
  require_repo_cwd

  if ! command -v mkcert >/dev/null 2>&1; then
    echo "error: mkcert non trovato. Su macOS: brew install mkcert" >&2
    exit 1
  fi

  local workdir port host base_url
  workdir="$(pwd -P)"
  mkdir -p "${workdir}/certs"

  echo "Installazione CA locale mkcert (fidata da macOS / browser)..."
  if ! mkcert -install; then
    echo
    echo "warning: mkcert -install richiede privilegi (sudo) in un terminale interattivo." >&2
    echo "  esegui una volta:  mkcert -install" >&2
    echo "  senza CA fidata Claude/macOS potrebbero rifiutare il certificato." >&2
    echo
  fi

  local cert="${workdir}/certs/localhost+2.pem"
  local key="${workdir}/certs/localhost+2-key.pem"

  echo "Generazione certificato per localhost, 127.0.0.1, ::1..."
  mkcert -cert-file "${cert}" -key-file "${key}" localhost 127.0.0.1 ::1

  chmod 600 "${key}"
  chmod 644 "${cert}"
  [[ -f "${workdir}/.env" ]] && chmod 600 "${workdir}/.env"

  if [[ -f "${workdir}/.env" ]]; then
    port="$(grep -E '^PORT=' "${workdir}/.env" | tail -1 | cut -d= -f2- || true)"
    host="$(grep -E '^HOST=' "${workdir}/.env" | tail -1 | cut -d= -f2- || true)"
    port="${port:-8765}"
    host="${host:-127.0.0.1}"
    base_url="https://${host}:${port}"

    if grep -qE '^MCP_BASE_URL=' "${workdir}/.env"; then
      local tmp
      tmp="$(mktemp)"
      awk -v url="${base_url}" '
        BEGIN { done=0 }
        /^MCP_BASE_URL=/ && !done { print "MCP_BASE_URL=" url; done=1; next }
        { print }
        END { if (!done) print "MCP_BASE_URL=" url }
      ' "${workdir}/.env" >"${tmp}"
      mv "${tmp}" "${workdir}/.env"
    else
      printf '\nMCP_BASE_URL=%s\n' "${base_url}" >>"${workdir}/.env"
    fi

    if ! grep -qE '^SSL_CERT_PATH=' "${workdir}/.env"; then
      printf 'SSL_CERT_PATH=certs/localhost+2.pem\n' >>"${workdir}/.env"
    fi
    if ! grep -qE '^SSL_KEY_PATH=' "${workdir}/.env"; then
      printf 'SSL_KEY_PATH=certs/localhost+2-key.pem\n' >>"${workdir}/.env"
    fi

    echo "aggiornato MCP_BASE_URL=${base_url} in .env"
    chmod 600 "${workdir}/.env"
  else
    echo "warning: .env assente — crea .env con MCP_BASE_URL=https://127.0.0.1:PORT"
  fi

  echo "certificato: ${cert}"
  echo "chiave:      ${key}"
  echo "poi: ./mcpme.sh restart   (o ./mcpme.sh install se non ancora installato)"
  echo
  echo "URL per Claude / client MCP:"
  if [[ -n "${base_url:-}" ]]; then
    echo "  ${base_url}/mcp"
  else
    echo "  https://127.0.0.1:<PORT>/mcp"
  fi
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    "")
      usage
      ;;
    install)
      cmd_install
      ;;
    uninstall)
      cmd_uninstall
      ;;
    status)
      cmd_status
      ;;
    start)
      cmd_start
      ;;
    stop)
      cmd_stop
      ;;
    restart)
      cmd_restart
      ;;
    logs)
      cmd_logs
      ;;
    cert)
      cmd_cert
      ;;
    test-push)
      cmd_test_push
      ;;
    tunnel)
      shift
      cmd_tunnel "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "error: opzione sconosciuta: ${cmd}" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
