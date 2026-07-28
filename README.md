# mcpme

Ruby MCP server with OAuth 2.1 that can run shell commands on the machine where it is hosted (your PC).

## Features

- **Streamable HTTP** MCP endpoint at `/mcp` (and `/`)
- **OAuth 2.1** (Authorization Code + PKCE S256) with login against `OAUTH_USER` / `OAUTH_PASSWORD` from `.env`
- Dynamic Client Registration, Protected Resource Metadata, Authorization Server Metadata
- Tool **`run_shell`**: executes a command on the host PC via Ruby backticks and returns output + exit status
- Optional **remote IP confirmation** via Pushover before shell commands from unknown public IPs

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

When `CONFIRM_REMOTE_IPS=true` (or `1` / `yes` / `on`; use `false` to disable), shell commands from unknown **public** remote IPs are blocked until you confirm via Pushover. Allowed IPs/CIDRs live in `data/allowed_remote_ips.txt` (one per line). **Anthropic / Claude outbound ranges** (`160.79.104.0/21`, `2607:6bc0::/48`) and **OpenAI / ChatGPT connector ranges** (fetched from [chatgpt-connectors.json](https://openai.com/chatgpt-connectors.json), cached in `data/openai_connectors_cidrs.txt`) are loaded automatically — see [Anthropic](https://platform.claude.com/docs/en/api/ip-addresses) and [OpenAI](https://developers.openai.com/api/docs/guides/ip-addresses) IP docs. Loopback and private ranges are always allowed. Set `PUSHOVER_TOKEN` / `PUSHOVER_USER` from https://pushover.net and keep `SECRET_KEY` private (HMAC for confirm links).
