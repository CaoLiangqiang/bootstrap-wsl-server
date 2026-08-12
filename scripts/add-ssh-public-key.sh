#!/usr/bin/env bash
set -Eeuo pipefail

key_file="${1:-}"
authorized_keys="${AUTHORIZED_KEYS_FILE:-$HOME/.ssh/authorized_keys}"

if [ -z "$key_file" ] || [ ! -f "$key_file" ]; then
  printf 'Usage: %s PUBLIC_KEY_FILE\n' "$0" >&2
  exit 2
fi

mapfile -t key_lines < <(sed 's/\r$//' "$key_file" | awk '!/^[[:space:]]*#/ && NF')
if [ "${#key_lines[@]}" -ne 1 ]; then
  printf 'Expected exactly one non-comment public-key line.\n' >&2
  exit 1
fi
key_line="${key_lines[0]}"
if [[ ! "$key_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
  printf 'The input is not a supported OpenSSH public key.\n' >&2
  exit 1
fi

fingerprint="$(printf '%s\n' "$key_line" | ssh-keygen -lf - | awk '{print $2}')"
if [ -z "$fingerprint" ]; then
  printf 'Unable to calculate the public-key fingerprint.\n' >&2
  exit 1
fi

authorized_dir="$(dirname "$authorized_keys")"
install -d -m 0700 "$authorized_dir"
if [ -L "$authorized_keys" ] || { [ -e "$authorized_keys" ] && [ ! -f "$authorized_keys" ]; }; then
  printf 'The authorized-keys path must be a regular file.\n' >&2
  exit 1
fi
touch "$authorized_keys"
chmod 0600 "$authorized_keys"
lock_file="${authorized_keys}.lock"
if [ -L "$lock_file" ] || { [ -e "$lock_file" ] && [ ! -f "$lock_file" ]; }; then
  printf 'The authorized-keys lock path must be a regular file.\n' >&2
  exit 1
fi
exec 9>"$lock_file"
chmod 0600 "$lock_file"
flock -x 9

if ssh-keygen -lf "$authorized_keys" 2>/dev/null | awk -v fp="$fingerprint" '$2 == fp { found = 1 } END { exit found ? 0 : 1 }'; then
  printf 'Key already authorized: %s\n' "$fingerprint"
  exit 0
fi
max_bytes="${AUTHORIZED_KEYS_MAX_BYTES:-65536}"
if ! [[ "$max_bytes" =~ ^[0-9]+$ ]]; then
  printf 'Invalid authorized-keys size limit.\n' >&2
  exit 1
fi
separator_bytes=0
if [ -s "$authorized_keys" ] && [ "$(tail -c 1 "$authorized_keys" | wc -l)" -eq 0 ]; then
  separator_bytes=1
fi
key_bytes="$(printf '%s\n' "$key_line" | wc -c)"
current_bytes="$(stat -c '%s' "$authorized_keys")"
if [ $((current_bytes + separator_bytes + key_bytes)) -gt "$max_bytes" ]; then
  printf 'The authorized-keys file is full.\n' >&2
  exit 1
fi
if [ "$separator_bytes" -eq 1 ]; then
  printf '\n' >> "$authorized_keys"
fi
printf '%s\n' "$key_line" >> "$authorized_keys"
if ! ssh-keygen -lf "$authorized_keys" | awk -v fp="$fingerprint" '$2 == fp { found = 1 } END { exit found ? 0 : 1 }'; then
  printf 'Key append verification failed.\n' >&2
  exit 1
fi
printf 'Key added: %s\n' "$fingerprint"
