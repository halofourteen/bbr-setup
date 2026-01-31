# bbr-setup

Bash script that enables [TCP BBR](https://github.com/google/bbr) congestion control on Linux servers with a single command.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/user/bbr-setup/main/setup.sh | sudo bash
```

Or clone and run locally:

```bash
git clone https://github.com/user/bbr-setup.git
cd bbr-setup
sudo bash setup.sh
```

## What it does

1. Verifies root permissions, distro, and kernel version (4.9+ required)
2. Checks that the `tcp_bbr` module is available
3. Backs up existing sysctl configuration
4. Writes BBR parameters to `/etc/sysctl.d/99-bbr.conf` (or `/etc/sysctl.conf` as fallback)
5. Applies and verifies the new settings

Parameters applied:

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

## Usage

```
bbr-setup 1.0.0 — enable TCP BBR congestion control

Usage: setup.sh [OPTIONS]

Options:
  --check      Show current BBR status and exit
  --dry-run    Show what would be done without making changes
  -h, --help   Show this help message
  -v, --version  Show version
```

### Examples

Apply BBR:

```bash
sudo bash setup.sh
```

Check current status without changing anything:

```bash
sudo bash setup.sh --check
```

Preview what would be changed:

```bash
sudo bash setup.sh --dry-run
```

## Supported distributions

- Debian / Ubuntu
- CentOS / RHEL / Fedora
- Alpine Linux
- Arch Linux
- Any Linux with kernel 4.9+ and the `tcp_bbr` module

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Success or BBR already enabled |
| `1`  | Error (missing root, old kernel, module unavailable, verification failed) |

## License

[MIT](LICENSE)
