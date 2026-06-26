# Dynamic Proxy Manager - IP Rotator

A powerful bash-based proxy management tool with automatic IP rotation, health checking, and system-wide proxy configuration. Supports both interactive and daemon (background) rotation modes.

![Bash](https://img.shields.io/badge/language-bash-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-linux-lightgrey)

## Features

- **System-wide Proxy** — Sets HTTP/HTTPS/FTP proxy across shell environment, APT, systemd services, and GNOME desktop
- **Automatic IP Rotation** — Rotates proxies at configurable intervals (interactive or background daemon)
- **Health Checking** — Verifies proxy availability before applying, automatically removes dead proxies
- **Proxy Fetching** — Fetches fresh public proxy lists from multiple sources with fallback support
- **Configuration Persistence** — Backs up and restores original proxy environment variables
- **Status Dashboard** — Displays current proxy configuration, rotator status, rotation history, and config files
- **Docker Support** — Configures Docker daemon proxy settings automatically

## Prerequisites

- Linux operating system
- `curl` for fetching proxy lists and health checks
- `sudo` access for system-wide proxy configuration (APT, systemd, Docker)
- `gsettings` (optional) — for GNOME desktop proxy settings

## Installation

Clone the repository:

```bash
git clone https://github.com/Ajay120503/proxy-manager.git
cd proxy-manager
```

Make the script executable:

```bash
chmod +x proxy-manager.sh
```

## Usage

### Basic Commands

```bash
./proxy-manager.sh start          # Enable static proxy at 127.0.0.1:8080
./proxy-manager.sh stop           # Disable proxy and restore original settings
./proxy-manager.sh status         # Show current proxy status dashboard
```

### IP Rotation

```bash
./proxy-manager.sh rotate         # Rotate IPs interactively every 30 seconds
./proxy-manager.sh rotate 10      # Rotate IPs every 10 seconds
```

### Background Daemon

```bash
./proxy-manager.sh daemon         # Run rotator in background (30s interval)
./proxy-manager.sh daemon 15      # Run rotator in background (15s interval)
```

### Fetch & List Proxies

```bash
./proxy-manager.sh fetch          # Fetch fresh proxy list from web sources
./proxy-manager.sh fetch US       # Fetch proxies filtered by country code
./proxy-manager.sh list           # List available proxies
./proxy-manager.sh list US        # List proxies filtered by country
```

### Test Proxy

```bash
./proxy-manager.sh test 1.2.3.4 8080    # Test if a specific proxy is alive
```

## Commands Reference

| Command | Description |
|---|---|
| `start` | Set static proxy (127.0.0.1:8080) system-wide |
| `stop` | Disable proxy and restore environment |
| `status` | Show current proxy status dashboard |
| `rotate [interval]` | Rotate IPs interactively (default 30s) |
| `daemon [interval]` | Run rotator in background |
| `fetch [country_code]` | Fetch fresh proxies from web |
| `list [filter]` | List available proxies |
| `test [host] [port]` | Test if a proxy is alive |

> **Note:** Running with `sudo` may require providing your root password. You can pipe it for unattended execution:
> ```bash
> echo 'your_password' | sudo -S ./proxy-manager.sh rotate 15
> ```

## How It Works

1. **Fetch Proxies** — The script fetches public HTTP proxy lists from multiple GitHub repositories and falls back to default proxies if network is unavailable.
2. **Health Check** — Each proxy is tested by opening a TCP connection and performing an HTTP request through the proxy.
3. **Rotate** — Proxies are cycled through the list at the configured interval. Dead proxies are automatically removed.
4. **Apply System-wide** — The selected proxy is applied to:
   - Shell environment variables (`http_proxy`, `https_proxy`, etc.)
   - APT package manager (`/etc/apt/apt.conf.d/99proxy`)
   - Systemd services (`/etc/systemd/system.conf.d/proxy.conf`, `/etc/systemd/user.conf.d/proxy.conf`)
   - Docker daemon (`/etc/systemd/system/docker.service.d/proxy.conf`)
   - GNOME desktop settings (if available)

## Proxy Sources

The script fetches proxies from the following sources:
- [TheSpeedX/PROXY-List](https://github.com/TheSpeedX/PROXY-List)
- [roosterkid/openproxylist](https://github.com/roosterkid/openproxylist)

## Files Created

| File | Purpose |
|---|---|
| `/tmp/proxy_list.txt` | Cached list of available proxies |
| `/tmp/.proxy_current_index` | Current proxy rotation index |
| `/tmp/.proxy_rotator.pid` | Daemon process PID |
| `/tmp/.proxy_backup` | Backup of original proxy environment variables |
| `/tmp/.proxy_env` | Persisted proxy environment variables for shell |
| `/tmp/.proxy_rotation.log` | Rotation history log |

## License

This project is open source and available under the [MIT License](LICENSE).

---

**Made with ❤️ by [Ajay120503](https://github.com/Ajay120503)**