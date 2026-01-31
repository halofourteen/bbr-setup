#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
#  TCP BBR Setup Script
#  Automatically enables BBR congestion control on Linux servers.
# ---------------------------------------------------------------------------

readonly SCRIPT_VERSION="1.0.0"
readonly SYSCTL_DROP="/etc/sysctl.d/99-bbr.conf"
readonly SYSCTL_MAIN="/etc/sysctl.conf"
readonly MIN_KERNEL_MAJOR=4
readonly MIN_KERNEL_MINOR=9

# ── Modes ──────────────────────────────────────────────────────────────────
DRY_RUN=false
CHECK_ONLY=false

# ── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ── Logging ────────────────────────────────────────────────────────────────
_ts() { date '+%H:%M:%S'; }

log_info()  { printf "${GREEN}[%s] [INFO]${RESET}  %s\n"  "$(_ts)" "$*"; }
log_warn()  { printf "${YELLOW}[%s] [WARN]${RESET}  %s\n" "$(_ts)" "$*"; }
log_error() { printf "${RED}[%s] [ERROR]${RESET} %s\n"    "$(_ts)" "$*" >&2; }

die() { log_error "$*"; exit 1; }

# ── Usage ──────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}bbr-setup ${SCRIPT_VERSION}${RESET} — enable TCP BBR congestion control

Usage: $(basename "$0") [OPTIONS]

Options:
  --check      Show current BBR status and exit
  --dry-run    Show what would be done without making changes
  -h, --help   Show this help message
  -v, --version  Show version

Examples:
  sudo bash setup.sh              # apply BBR
  sudo bash setup.sh --check      # status only
  sudo bash setup.sh --dry-run    # preview changes
EOF
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)     CHECK_ONLY=true ;;
            --dry-run)   DRY_RUN=true ;;
            -h|--help)   usage ;;
            -v|--version) echo "bbr-setup ${SCRIPT_VERSION}"; exit 0 ;;
            *) die "Unknown option: $1. Use --help for usage." ;;
        esac
        shift
    done
}

# ── Detect distro ─────────────────────────────────────────────────────────
detect_distro() {
    local distro="unknown"
    if [[ -f /etc/os-release ]]; then
        # Read in a subshell to avoid variable conflicts (e.g. VERSION)
        distro=$(. /etc/os-release && echo "${ID}")
    elif [[ -f /etc/redhat-release ]]; then
        distro="rhel"
    elif [[ -f /etc/alpine-release ]]; then
        distro="alpine"
    fi
    echo "${distro}"
}

# ── Kernel version check ─────────────────────────────────────────────────
check_kernel() {
    local kver
    kver=$(uname -r)
    local major minor
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)

    log_info "Kernel version: ${kver}"

    if (( major > MIN_KERNEL_MAJOR )) || { (( major == MIN_KERNEL_MAJOR )) && (( minor >= MIN_KERNEL_MINOR )); }; then
        log_info "Kernel ${kver} meets minimum requirement (${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}+)"
    else
        die "Kernel ${kver} is too old. BBR requires ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}+"
    fi
}

# ── Check BBR module availability ─────────────────────────────────────────
check_bbr_module() {
    if lsmod | grep -q tcp_bbr; then
        log_info "Module tcp_bbr is loaded"
        return 0
    fi

    if modprobe -n tcp_bbr 2>/dev/null; then
        log_info "Module tcp_bbr is available (not yet loaded)"
        return 0
    fi

    # On newer kernels BBR can be built-in (not a module)
    if [[ -f /proc/config.gz ]]; then
        if zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_TCP_CONG_BBR=y'; then
            log_info "BBR is built into the kernel"
            return 0
        fi
    fi

    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        log_info "BBR is listed as available congestion control"
        return 0
    fi

    die "tcp_bbr module is not available on this system"
}

# ── Read current state ────────────────────────────────────────────────────
get_current_cc()    { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"; }
get_current_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null           || echo "unknown"; }

show_status() {
    local cc qdisc
    cc=$(get_current_cc)
    qdisc=$(get_current_qdisc)

    log_info "Current congestion control : ${BOLD}${cc}${RESET}"
    log_info "Current default qdisc      : ${BOLD}${qdisc}${RESET}"

    if [[ "$cc" == "bbr" && ( "$qdisc" == "fq" || "$qdisc" == "fq_codel" ) ]]; then
        return 0  # already configured
    fi
    return 1      # needs configuration
}

# ── Determine sysctl target file ─────────────────────────────────────────
pick_sysctl_file() {
    if [[ -d /etc/sysctl.d ]]; then
        echo "${SYSCTL_DROP}"
    else
        echo "${SYSCTL_MAIN}"
    fi
}

# ── Backup ────────────────────────────────────────────────────────────────
backup_sysctl() {
    local target="$1"
    if [[ -f "$target" ]]; then
        local bak="${target}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp -a "$target" "$bak"
        log_info "Backup created: ${bak}"
        echo "$bak"
    fi
}

# ── Write sysctl parameters ──────────────────────────────────────────────
write_params() {
    local target="$1"
    local needs_cc=true
    local needs_qdisc=true

    if [[ -f "$target" ]]; then
        grep -q '^net.core.default_qdisc\s*=\s*fq'  "$target" && needs_qdisc=false
        grep -q '^net.ipv4.tcp_congestion_control\s*=\s*bbr' "$target" && needs_cc=false
    fi

    # Also check the main sysctl.conf if we're writing to a drop-in
    if [[ "$target" != "$SYSCTL_MAIN" && -f "$SYSCTL_MAIN" ]]; then
        grep -q '^net.core.default_qdisc\s*=\s*fq'  "$SYSCTL_MAIN" && needs_qdisc=false
        grep -q '^net.ipv4.tcp_congestion_control\s*=\s*bbr' "$SYSCTL_MAIN" && needs_cc=false
    fi

    if ! $needs_cc && ! $needs_qdisc; then
        log_info "Parameters already present in ${target}"
        return 0
    fi

    {
        echo ""
        echo "# TCP BBR — added by bbr-setup ${SCRIPT_VERSION} on $(date '+%Y-%m-%d %H:%M:%S')"
        $needs_qdisc && echo "net.core.default_qdisc = fq"
        $needs_cc    && echo "net.ipv4.tcp_congestion_control = bbr"
    } >> "$target"

    log_info "Parameters written to ${target}"
}

# ── Apply & verify ────────────────────────────────────────────────────────
apply_sysctl() {
    local target="$1"

    # Load the bbr module if it isn't loaded yet
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    sysctl -p "$target" >/dev/null 2>&1

    # Also reload main if we used a drop-in
    if [[ "$target" != "$SYSCTL_MAIN" && -f "$SYSCTL_MAIN" ]]; then
        sysctl -p "$SYSCTL_MAIN" >/dev/null 2>&1 || true
    fi

    local new_cc new_qdisc
    new_cc=$(get_current_cc)
    new_qdisc=$(get_current_qdisc)

    if [[ "$new_cc" == "bbr" ]]; then
        log_info "Verification passed: congestion control = ${BOLD}${new_cc}${RESET}"
    else
        die "Verification failed: congestion control is '${new_cc}', expected 'bbr'"
    fi

    if [[ "$new_qdisc" == "fq" || "$new_qdisc" == "fq_codel" ]]; then
        log_info "Verification passed: default qdisc = ${BOLD}${new_qdisc}${RESET}"
    else
        log_warn "Qdisc is '${new_qdisc}' (expected 'fq'). This may still work but fq is recommended."
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────
print_summary() {
    local old_cc="$1" old_qdisc="$2" new_cc="$3" new_qdisc="$4" backup_path="${5:-}"

    echo ""
    printf "${BOLD}%-30s  %-14s  %-14s${RESET}\n" "" "Before" "After"
    printf "%-30s  %-14s  %-14s\n" "Congestion control" "$old_cc" "$new_cc"
    printf "%-30s  %-14s  %-14s\n" "Default qdisc" "$old_qdisc" "$new_qdisc"
    echo ""

    if [[ -n "$backup_path" ]]; then
        log_info "Backup saved to: ${backup_path}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════════
main() {
    parse_args "$@"

    echo ""
    printf "${CYAN}${BOLD}  TCP BBR Setup ${SCRIPT_VERSION}${RESET}\n"
    echo ""

    # ── Root check ─────────────────────────────────────────────────────
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi

    # ── Distro detection ───────────────────────────────────────────────
    local distro
    distro=$(detect_distro)
    log_info "Detected distro: ${BOLD}${distro}${RESET}"

    # ── Kernel check ───────────────────────────────────────────────────
    check_kernel

    # ── BBR module check ───────────────────────────────────────────────
    check_bbr_module

    # ── Current state ──────────────────────────────────────────────────
    local old_cc old_qdisc
    old_cc=$(get_current_cc)
    old_qdisc=$(get_current_qdisc)

    if show_status; then
        log_info "${GREEN}BBR is already enabled. Nothing to do.${RESET}"
        print_summary "$old_cc" "$old_qdisc" "$old_cc" "$old_qdisc"
        exit 0
    fi

    # ── Check-only mode ────────────────────────────────────────────────
    if $CHECK_ONLY; then
        log_warn "BBR is NOT currently enabled"
        exit 1
    fi

    # ── Dry-run mode ───────────────────────────────────────────────────
    local target
    target=$(pick_sysctl_file)

    if $DRY_RUN; then
        log_warn "Dry-run mode — no changes will be made"
        echo ""
        log_info "Would write to: ${target}"
        log_info "Parameters:"
        echo "  net.core.default_qdisc = fq"
        echo "  net.ipv4.tcp_congestion_control = bbr"
        echo ""
        exit 0
    fi

    # ── Apply changes ──────────────────────────────────────────────────
    log_info "Configuring BBR..."

    local backup_path=""
    backup_path=$(backup_sysctl "$target")

    write_params "$target"
    apply_sysctl "$target"

    local new_cc new_qdisc
    new_cc=$(get_current_cc)
    new_qdisc=$(get_current_qdisc)

    print_summary "$old_cc" "$old_qdisc" "$new_cc" "$new_qdisc" "$backup_path"
    log_info "${GREEN}${BOLD}Done.${RESET}"
}

main "$@"
