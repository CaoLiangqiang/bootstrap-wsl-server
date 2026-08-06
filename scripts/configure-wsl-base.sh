#!/usr/bin/env bash
set -Eeuo pipefail

config_file=/etc/wsl.conf
target_user="${SUDO_USER:-${USER:-}}"
isolate_path=0
check_only=0

usage() {
  cat <<'EOF'
Usage: configure-wsl-base.sh [--user USER] [--isolate-windows-path] [--check] [--file PATH]

Compatibility fallback for the Phase 1 WSL foundation. Ensures systemd and the
default WSL user while preserving unrelated wsl.conf sections. Prefer
bootstrap-wsl-ai-dev/scripts/configure-wsl-systemd.sh for foundation setup and
its configure-wsl-path-isolation.sh for the optional Windows PATH decision.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) target_user="${2:-}"; shift 2 ;;
    --isolate-windows-path) isolate_path=1; shift ;;
    --check) check_only=1; shift ;;
    --file) config_file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! "$target_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  printf 'Invalid or missing Linux user: %s\n' "$target_user" >&2
  exit 2
fi
if [ "$config_file" = /etc/wsl.conf ] && [ "$(id -u)" -ne 0 ]; then
  printf 'Run this script with sudo. Enter the password only in your terminal.\n' >&2
  exit 1
fi
if [ "$config_file" = /etc/wsl.conf ] && ! id "$target_user" >/dev/null 2>&1; then
  printf 'Linux user does not exist: %s\n' "$target_user" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wsl-base.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
working="$tmp_dir/wsl.conf"
if [ -e "$config_file" ]; then cp "$config_file" "$working"; else : > "$working"; fi

set_ini_value() {
  local section="$1" key_name="$2" value="$3" next="$tmp_dir/next"
  awk -v wanted_section="$section" -v wanted_key="$key_name" -v wanted_value="$value" '
    function section_name(line, name) {
      name = line; sub(/^[[:space:]]*\[/, "", name); sub(/\][[:space:]]*$/, "", name)
      return tolower(name)
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_section && !written) print wanted_key "=" wanted_value
      in_section = section_name($0) == tolower(wanted_section)
      if (in_section) { seen = 1; written = 0 }
      print; next
    }
    in_section {
      line = $0; sub(/^[[:space:]]*/, "", line); split(line, parts, "=")
      key = parts[1]; sub(/[[:space:]]*$/, "", key)
      if (tolower(key) == tolower(wanted_key)) {
        if (!written) print wanted_key "=" wanted_value
        written = 1; next
      }
    }
    { print }
    END {
      if (in_section && !written) print wanted_key "=" wanted_value
      if (!seen) {
        if (NR > 0) print ""
        print "[" wanted_section "]"; print wanted_key "=" wanted_value
      }
    }
  ' "$working" > "$next"
  mv "$next" "$working"
}

set_ini_value boot systemd true
set_ini_value user default "$target_user"
if [ "$isolate_path" -eq 1 ]; then set_ini_value interop appendWindowsPath false; fi

if [ -e "$config_file" ] && cmp -s "$config_file" "$working"; then
  printf 'OK: %s already has the requested WSL baseline.\n' "$config_file"
  exit 0
fi
if [ "$check_only" -eq 1 ]; then
  printf 'CHANGE NEEDED: %s differs from the requested baseline.\n' "$config_file"
  diff -u "$config_file" "$working" 2>/dev/null || true
  exit 1
fi

install -d -m 0755 "$(dirname "$config_file")"
if [ -e "$config_file" ]; then
  backup="$config_file.backup.$(date +%Y%m%d%H%M%S)"
  cp --preserve=all "$config_file" "$backup"
  printf 'Backup: %s\n' "$backup"
fi
install -m 0644 "$working" "$config_file"
printf 'Updated: %s\n' "$config_file"
printf 'From Windows PowerShell run: wsl --shutdown\n'
