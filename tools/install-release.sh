#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo 'run as root' >&2
  exit 1
fi

mode='new-api-only'
package=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) mode='all'; shift ;;
    --new-api-only) mode='new-api-only'; shift ;;
    --package) package="${2:?missing package path}"; shift 2 ;;
    *) echo "usage: $0 --package FILE [--new-api-only|--all]" >&2; exit 2 ;;
  esac
done

[[ -n "$package" && -f "$package" ]] || { echo 'package file is required' >&2; exit 2; }
base='/var/lib/relay-native'
release_root="$base/releases"
install -d -o relay -g relay -m 750 "$release_root"
tmp="$(mktemp -d "$release_root/.install-XXXXXX")"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

tar -xzf "$package" -C "$tmp"
manifest="$(find "$tmp" -mindepth 2 -maxdepth 2 -name manifest.txt -print -quit)"
[[ -n "$manifest" ]] || { echo 'manifest.txt missing from package' >&2; exit 1; }
package_root="$(dirname "$manifest")"
(cd "$package_root" && sha256sum -c SHA256SUMS.txt)
grep -q '^production_deploy=not-authorized$' "$manifest" || { echo 'unexpected release manifest' >&2; exit 1; }
release_id="$(sed -n 's/^release_id=//p' "$manifest")"
[[ -n "$release_id" ]] || { echo 'release_id missing' >&2; exit 1; }

install -d -o relay -g relay -m 750 "$release_root/$release_id"
cp -a "$package_root"/. "$release_root/$release_id/"
install -o relay -g relay -m 755 "$release_root/$release_id/new-api-linux-amd64" "$base/bin/new-api"

if [[ "$mode" == 'all' ]]; then
  install -o relay -g relay -m 755 "$release_root/$release_id/CLIProxyAPI-linux-amd64" "$base/bin/CLIProxyAPI"
  if [[ -f "$release_root/$release_id/management.html" ]]; then
    install -o relay -g relay -m 644 "$release_root/$release_id/management.html" "$base/bin/static/management.html"
  fi
  systemctl restart relay-native-cpa.service
fi
systemctl restart relay-native-new-api.service
systemctl is-active relay-native-new-api.service
if [[ "$mode" == 'all' ]]; then systemctl is-active relay-native-cpa.service; fi
echo "installed release=$release_id mode=$mode"
