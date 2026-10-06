#!/usr/bin/env bash
set -euo pipefail

# Keep only small, recent local caches. R2 remains the disaster-recovery copy.
# Dry-run is the default; pass --apply only from the intended server.
apply=false
if [[ "${1:-}" == "--apply" ]]; then
  apply=true
  shift
fi
backup_dir="${1:-/var/lib/relay-native/backups/r2}"
log_dir="${2:-/var/lib/relay-native/logs/new-api}"

remove_path() {
  if $apply; then
    rm -f -- "$1"
  else
    printf 'would-remove %s\n' "$1"
  fi
}

if [[ -d "$backup_dir" ]]; then
  mapfile -t backups < <(find "$backup_dir" -maxdepth 1 -type f -name '*.tar.gz.enc' -printf '%T@ %p\n' | sort -nr | awk 'NR > 2 {sub(/^[^ ]+ /, ""); print}')
  if ((${#backups[@]} > 0)); then
    for path in "${backups[@]}"; do
      remove_path "$path"
    done
  fi
fi

if [[ -d "$log_dir" ]]; then
  find "$log_dir" -maxdepth 1 -type f -name 'oneapi-*.log' -mtime +14 -delete
  mapfile -t logs < <(find "$log_dir" -maxdepth 1 -type f -name 'oneapi-*.log' -printf '%T@ %p\n' | sort -nr | awk 'NR > 20 {sub(/^[^ ]+ /, ""); print}')
  if ((${#logs[@]} > 0)); then
    for path in "${logs[@]}"; do
      remove_path "$path"
    done
  fi
fi
