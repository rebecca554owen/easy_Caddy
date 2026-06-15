---
name: manage-caddy
description: Manage Caddy on Debian/Ubuntu servers. Use when Codex needs to install or uninstall Caddy, configure or remove Caddy reverse proxies, validate and reload/restart Caddy, inspect Caddy service status, recover failed Caddyfile changes, or troubleshoot Caddy errors such as inactive reloads, hostname resolution warnings, TLS/DNS failures, firewall issues, and unreachable upstream services.
---

# Manage Caddy

## Operating Rules

Assume you are already in a shell on the target Debian/Ubuntu server. Do not use this skill for local macOS configuration or for remote SSH orchestration unless the user explicitly asks for SSH commands.

Before changing anything, inspect the environment:

```bash
whoami
hostname
cat /etc/os-release
command -v sudo
command -v systemctl
command -v apt-get
command -v caddy || true
systemctl is-active caddy || true
```

Use `/etc/caddy/Caddyfile` as the Caddyfile path. Before editing it, create a timestamped backup:

```bash
sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
```

After every Caddyfile edit, validate before applying:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

Apply valid config with reload when Caddy is active, otherwise restart:

```bash
if sudo systemctl is-active --quiet caddy; then
  sudo systemctl reload caddy || sudo systemctl restart caddy
else
  sudo systemctl restart caddy
fi
```

If validation or applying fails, restore the backup and report the failing command and error.

## Install Or Uninstall Caddy

Install Caddy from the official Cloudsmith repository on Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install -y caddy
caddy version
systemctl status caddy --no-pager
```

Before uninstalling, confirm the user intends to remove Caddy and Caddy config. Then run:

```bash
sudo systemctl stop caddy || true
sudo apt-get remove --purge -y caddy
sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo rm -f /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak /etc/caddy/caddy_reverse_proxies.txt
```

## Configure Reverse Proxy

Normalize upstream input before writing config:

- `3000` becomes `http://127.0.0.1:3000`
- `host:port` becomes `http://host:port`
- `http://host[:port][/path]` stays HTTP
- `https://host[:port][/path]` stays HTTPS
- remove trailing `/`; treat `/` as no path

Use this Caddyfile block for a full-site reverse proxy:

```caddyfile
example.com {
    reverse_proxy http://127.0.0.1:3000 {
        lb_try_duration 600s
        flush_interval -1
        transport http {
            dial_timeout 30s
            response_header_timeout 600s
            read_timeout 600s
            write_timeout 600s
        }
    }
}
```

Use this Caddyfile block when the upstream includes a path such as `/api`; only that path and subpaths should proxy:

```caddyfile
example.com {
    @proxy_path path /api /api/*
    reverse_proxy @proxy_path http://127.0.0.1:3000 {
        lb_try_duration 600s
        flush_interval -1
        transport http {
            dial_timeout 30s
            response_header_timeout 600s
            read_timeout 600s
            write_timeout 600s
        }
    }
}
```

When proxying to an HTTPS upstream, keep the `https://` upstream and include `tls` inside `transport http`:

```caddyfile
        transport http {
            tls
            dial_timeout 30s
            response_header_timeout 600s
            read_timeout 600s
            write_timeout 600s
        }
```

After applying, report the domain, normalized upstream, Caddyfile path, validation result, and service status.

## Inspect Or Delete Proxies

Inspect current service and proxy config with:

```bash
systemctl status caddy --no-pager
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo sed -n '1,240p' /etc/caddy/Caddyfile
```

To delete a proxy, remove only the matching site block from `/etc/caddy/Caddyfile`. Keep unrelated global options, snippets, and site blocks. Always back up first, validate after editing, then reload/restart. If the user identifies a domain, delete the block whose site address exactly matches that domain. After deletion, show or inspect the edited Caddyfile section before applying so brace boundaries and unrelated site blocks are preserved.

## Troubleshooting

For `sudo: unable to resolve host NAME: Name or service not known`, fix `/etc/hosts`:

```bash
echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts
```

For `caddy.service is not active, cannot reload`, start Caddy with:

```bash
sudo systemctl restart caddy
```

For TLS or certificate failures, check that DNS points to the server and ports 80/443 are reachable:

```bash
dig +short A example.com
dig +short AAAA example.com
sudo ss -lntp | grep -E ':80|:443' || true
sudo ufw status || true
```

For unreachable upstream services, test the host and port:

```bash
timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/3000' && echo "upstream reachable" || echo "upstream unreachable"
curl -I http://127.0.0.1:3000 || true
```

When finishing any task, include concise next steps if DNS, firewall, TLS, validation, or upstream checks still fail.
