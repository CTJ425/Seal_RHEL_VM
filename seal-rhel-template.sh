#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
ASSUME_YES=0
DO_POWEROFF=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./seal-rhel-template.sh [--dry-run] [--yes] [--poweroff]

Options:
  --dry-run   Show actions without changing the system.
  --yes       Skip the confirmation prompt.
  --poweroff  Power off the VM after cleanup finishes.
  -h, --help  Show this help message.
USAGE
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %q' "$1"
    shift
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi

  "$@"
}

run_required() {
  if ! run "$@"; then
    die "Required command failed: $*"
  fi
}

run_shell() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  bash -c "$*"
}

run_shell_required() {
  if ! run_shell "$*"; then
    die "Required command failed: $*"
  fi
}

optional_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    run "$@"
    return 0
  fi

  "$@" || log "Command failed but cleanup will continue: $*"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Please run as root, for example: sudo ./$SCRIPT_NAME"
  fi
}

detect_os() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-unknown}"
  OS_MAJOR="${VERSION_ID%%.*}"

  case " $OS_ID $OS_ID_LIKE " in
    *" rhel "*|*" rocky "*|*" centos "*|*" fedora "*) ;;
    *) die "Unsupported OS family: $OS_NAME. This script supports RHEL/Rocky compatible systems only." ;;
  esac

  case "$OS_MAJOR" in
    8|9|10) ;;
    *) die "Unsupported OS version: $OS_NAME. This script supports RHEL/Rocky compatible 8.x, 9.x, and 10.x only." ;;
  esac

  log "Detected OS: $OS_NAME"
}

confirm_run() {
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  printf 'This will seal this VM as a template and remove machine-specific data. Continue? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "Cancelled by user." ;;
  esac
}

clean_subscription() {
  if [ "$OS_ID" != "rhel" ]; then
    log "Skip subscription-manager cleanup for non-RHEL OS ID: $OS_ID"
    return 0
  fi

  if ! command -v subscription-manager >/dev/null 2>&1; then
    log "subscription-manager not found; skip registration cleanup."
    return 0
  fi

  log "Cleaning Red Hat subscription registration."
  optional_run subscription-manager unregister
  optional_run subscription-manager remove --all
  optional_run subscription-manager clean
}

clean_network_identity() {
  log "Removing NIC MAC, UUID, and persistent interface mappings."

  if compgen -G "/etc/sysconfig/network-scripts/ifcfg-*" >/dev/null; then
    run_shell_required "sed -i '/^[[:space:]]*HWADDR=/d;/^[[:space:]]*MACADDR=/d;/^[[:space:]]*UUID=/d' /etc/sysconfig/network-scripts/ifcfg-*"
  fi

  if compgen -G "/etc/NetworkManager/system-connections/*.nmconnection" >/dev/null; then
    run_shell_required "sed -i '/^[[:space:]]*uuid=/d;/^[[:space:]]*stable-id=/d;/^[[:space:]]*interface-name=/d;/^[[:space:]]*mac-address=/d;/^[[:space:]]*cloned-mac-address=/d' /etc/NetworkManager/system-connections/*.nmconnection"
    run_required chmod 600 /etc/NetworkManager/system-connections/*.nmconnection
  fi

  run_required rm -f /etc/udev/rules.d/70-persistent-*
}

clean_hosts_resolver() {
  log "Clearing /etc/hosts and /etc/resolv.conf content."
  run_shell_required ": > /etc/hosts"
  run_shell_required ": > /etc/resolv.conf"
}

clean_hostname() {
  log "Resetting hostname."
  run_required hostnamectl set-hostname localhost.localdomain
}

clean_ssh_host_keys() {
  log "Removing SSH host keys."
  run_required rm -f /etc/ssh/ssh_host_*
}

clean_machine_id() {
  log "Resetting machine-id for RHEL compatible $OS_MAJOR."

  if [ "$OS_MAJOR" = "8" ]; then
    run_required rm -f /var/lib/dbus/machine-id
    run_shell_required "printf 'uninitialized\n' > /etc/machine-id"
  else
    run_required rm -f /etc/machine-id
    run_shell_required "printf 'uninitialized\n' > /etc/machine-id"
    run_required chmod 644 /etc/machine-id
  fi
}

clean_optional_components() {
  log "Cleaning optional components when installed."

  if rpm -qa 'katello-ca-consumer*' | grep -q .; then
    optional_run dnf remove -y 'katello-ca-consumer*'
  fi
  optional_run rm -f /etc/rhsm/facts/katello.facts

  if [ -f /etc/iscsi/initiatorname.iscsi ]; then
    optional_run rm -f /etc/iscsi/initiatorname.iscsi
  fi

  if command -v cloud-init >/dev/null 2>&1; then
    optional_run cloud-init clean --logs --seed
  fi

  if command -v insights-client >/dev/null 2>&1; then
    optional_run insights-client --unregister
  fi
}

clean_shell_history() {
  log "Clearing shell history files."
  optional_run rm -f /root/.bash_history
  optional_run find /home -maxdepth 2 -name .bash_history -type f -delete
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --poweroff) DO_POWEROFF=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  require_root
  detect_os
  confirm_run

  clean_subscription
  clean_network_identity
  clean_hosts_resolver
  clean_hostname
  clean_ssh_host_keys
  clean_machine_id
  clean_optional_components
  clean_shell_history

  log "Seal cleanup completed. Shut down this VM before converting it to a template."

  if [ "$DO_POWEROFF" -eq 1 ]; then
    log "Powering off VM."
    run_required systemctl poweroff
  fi
}

main "$@"
