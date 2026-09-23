# mcpme

Ruby MCP server with OAuth 2.1 that can run shell commands on the machine where it is hosted (your PC).

## Features

- **Streamable HTTP** MCP endpoint at `/mcp` (and `/`)
- **OAuth 2.1** (Authorization Code + PKCE S256) with login against `OAUTH_USER` / `OAUTH_PASSWORD` from `.env`
- Dynamic Client Registration, Protected Resource Metadata, Authorization Server Metadata
- Tool **`run_shell`**: executes a command on the host PC via Ruby backticks and returns output + exit status
- Optional **remote IP confirmation** via Pushover before shell commands from unknown public IPs
- **ChatGPT web** compatibility: CORS preflight, tool annotations + `outputSchema`, MCP `2026-07-28` `server/discover`, OpenID discovery metadata

## Setup

```bash
cp .env.example .env
bundle install
```

Edit `.env`:

```env
OAUTH_USER=admin
OAUTH_PASSWORD=changeme
MCP_BASE_URL=http://127.0.0.1:9292
HOST=127.0.0.1
PORT=9292
```

## Run

```bash
bundle exec ruby bin/server
# or
bundle exec rackup -o 127.0.0.1 -p 9292
```

### LaunchAgent (macOS)

```bash
./mcpme.sh              # help + descrizione
./mcpme.sh cert         # HTTPS locale con mkcert (consigliato per Claude)
./mcpme.sh install      # LaunchAgent persistente dalla cwd
./mcpme.sh uninstall    # stop + rimozione plist
./mcpme.sh status       # stato launchctl
./mcpme.sh start|stop|restart
./mcpme.sh logs         # tail -f stdout/stderr
```

### Cloudflare Tunnel (Claude / pubblico)

Espone `https://mcpme.m6i.it` → origin locale `https://127.0.0.1:8765`:

```bash
brew install cloudflared   # se manca
./mcpme.sh cert
./mcpme.sh tunnel setup    # login browser Cloudflare + DNS mcpme.m6i.it
./mcpme.sh install         # server + tunnel LaunchAgents
```

URL per Claude custom connector: `https://mcpme.m6i.it/mcp`

```bash
./mcpme.sh tunnel status|logs|restart
```

## Cursor / MCP client

Point a remote MCP client at:

```text
http://127.0.0.1:9292/mcp
```

On first connect the client receives `401` with `WWW-Authenticate` pointing at:

```text
/.well-known/oauth-protected-resource
```

It then discovers the authorization server, registers (if needed), opens `/authorize`, and you sign in with `OAUTH_USER` / `OAUTH_PASSWORD`.

Example Cursor `mcp.json` entry (URL may vary by client version):

```json
{
  "mcpServers": {
    "mcpme": {
      "url": "http://127.0.0.1:9292/mcp"
    }
  }
}
```

## Tool

### `run_shell`

| Argument  | Type   | Description        |
|-----------|--------|--------------------|
| `command` | string | Shell command line |

Output includes `exit_status` and combined stdout/stderr.

## Security

This server can run arbitrary shell commands on the host. Use only on trusted local machines, keep credentials strong, and prefer Cloudflare Tunnel + OAuth.

When `CONFIRM_REMOTE_IPS=true` (or `1` / `yes` / `on`; use `false` to disable), shell commands from unknown **public** remote IPs are blocked until you confirm via Pushover. Confirming the link writes that IP to `data/allowed_remote_ips.txt` (one address or CIDR per line). A fresh install has no provider ranges: Anthropic and OpenAI addresses need the same confirmation as any other public IP. Loopback and private ranges are always allowed. Set `PUSHOVER_TOKEN` / `PUSHOVER_USER` from https://pushover.net and keep `SECRET_KEY` private. Confirm links expire after `CONFIRM_LINK_TTL_SECONDS` (default 600) and the signed URL is not written to the log.

`run_shell` stops after `COMMAND_TIMEOUT_SECONDS` (default 60) or `COMMAND_MAX_OUTPUT_BYTES` (default 1 MiB). OAuth login locks an IP after `LOGIN_MAX_FAILURES` (default 8) for `LOGIN_LOCKOUT_SECONDS` (default 900). A refresh token cannot outlive the original login: the session ends `OAUTH_TOKEN_TTL_DAYS` after authorization, and refreshing does not extend that deadline. `.env`, the TLS key, `data/oauth_store.json`, and the log files are mode `600`.
