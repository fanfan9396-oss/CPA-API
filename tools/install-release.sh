#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo 'run as root' >&2
  exit 1
fi

mode='new-api-only'
package=''
plan_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) mode='all'; shift ;;
    --cpa-only) mode='cpa-only'; shift ;;
    --new-api-only) mode='new-api-only'; shift ;;
    --plan) plan_only=true; shift ;;
    --package) package="${2:?missing package path}"; shift 2 ;;
    *) echo "usage: $0 --package FILE [--new-api-only|--cpa-only|--all] [--plan]" >&2; exit 2 ;;
  esac
done

[[ -n "$package" && -f "$package" ]] || { echo 'package file is required' >&2; exit 2; }
base="${RELAY_NATIVE_BASE:-/var/lib/relay-native}"
release_root="$base/releases"
install_bin="${INSTALL_BIN:-install}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
if [[ "$plan_only" == true ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/relay-native-install-XXXXXX")"
else
  "$install_bin" -d -o relay -g relay -m 750 "$release_root"
  tmp="$(mktemp -d "$release_root/.install-XXXXXX")"
fi
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
component="$(sed -n 's/^component=//p' "$manifest")"
if [[ -z "$component" ]]; then
  if [[ -s "$package_root/new-api-linux-amd64" && -s "$package_root/CLIProxyAPI-linux-amd64" && -s "$package_root/management.html" ]]; then
    component='full'
  elif [[ -s "$package_root/new-api-linux-amd64" ]]; then
    component='new-api'
  elif [[ -s "$package_root/CLIProxyAPI-linux-amd64" && -s "$package_root/management.html" ]]; then
    component='cpa'
  else
    echo 'invalid component in manifest and unable to infer legacy package component' >&2
    exit 1
  fi
fi
[[ "$component" == 'new-api' || "$component" == 'cpa' || "$component" == 'full' ]] || { echo 'invalid component in manifest' >&2; exit 1; }

if [[ "$component" == 'cpa' || "$component" == 'full' ]]; then
  grep -q '^cpa_ref=.' "$manifest" || { echo 'cpa_ref missing from CPA manifest' >&2; exit 1; }
  grep -q '^cpa_panel_ref=.' "$manifest" || { echo 'cpa_panel_ref missing from CPA manifest' >&2; exit 1; }
  grep -q '^compatibility_id=.' "$manifest" || { echo 'compatibility_id missing from CPA manifest' >&2; exit 1; }
fi

# component describes package contents; mode describes the authorized mutation set.
update_new_api=false
update_cpa=false
case "$mode:$component" in
  new-api-only:new-api|new-api-only:full)
    update_new_api=true
    ;;
  cpa-only:cpa|cpa-only:full)
    update_cpa=true
    ;;
  all:full)
    update_new_api=true
    update_cpa=true
    ;;
  *) echo "install mode $mode is incompatible with manifest component $component" >&2; exit 1 ;;
esac

if [[ "$update_new_api" == true && "$update_cpa" == true ]]; then
  update_set='new-api,cpa'
  skip_set='none'
elif [[ "$update_new_api" == true ]]; then
  update_set='new-api'
  skip_set='cpa'
else
  update_set='cpa'
  skip_set='new-api'
fi
printf 'release=%s\nmanifest_component=%s\nrequested_mode=%s\nwill_update=%s\nwill_not_update=%s\n' \
  "$release_id" "$component" "$mode" "$update_set" "$skip_set"

if [[ "$component" == 'new-api' || "$component" == 'full' ]]; then
  [[ -s "$package_root/new-api-linux-amd64" ]] || { echo 'new-api-linux-amd64 missing' >&2; exit 1; }
fi
if [[ "$component" == 'cpa' || "$component" == 'full' ]]; then
  [[ -s "$package_root/CLIProxyAPI-linux-amd64" ]] || { echo 'CLIProxyAPI-linux-amd64 missing' >&2; exit 1; }
  [[ -s "$package_root/management.html" ]] || { echo 'management.html missing for CPA component' >&2; exit 1; }
fi

if [[ "$plan_only" == true ]]; then
  echo 'plan_only=true'
  exit 0
fi

release_dir="$release_root/$release_id"
"$install_bin" -d -o relay -g relay -m 750 "$release_dir"
cp -a "$package_root"/. "$release_dir/"

if [[ "$update_new_api" == true ]]; then
  "$install_bin" -o relay -g relay -m 755 "$package_root/new-api-linux-amd64" "$release_dir/new-api-linux-amd64"
  "$install_bin" -o relay -g relay -m 755 "$release_dir/new-api-linux-amd64" "$base/bin/new-api"
fi

if [[ "$update_cpa" == true ]]; then
  "$install_bin" -o relay -g relay -m 755 "$package_root/CLIProxyAPI-linux-amd64" "$release_dir/CLIProxyAPI-linux-amd64"
  "$install_bin" -o relay -g relay -m 644 "$package_root/management.html" "$release_dir/management.html"
  for metadata in cpa-version.txt management.html.sha256; do
    if [[ -f "$package_root/$metadata" ]]; then
      "$install_bin" -o relay -g relay -m 644 "$package_root/$metadata" "$release_dir/$metadata"
    fi
  done
  "$install_bin" -o relay -g relay -m 755 "$release_dir/CLIProxyAPI-linux-amd64" "$base/bin/CLIProxyAPI"
  "$install_bin" -o relay -g relay -m 644 "$release_dir/management.html" "$base/bin/static/management.html"
  "$systemctl_bin" restart relay-native-cpa.service
fi
if [[ "$update_new_api" == true ]]; then
  "$systemctl_bin" restart relay-native-new-api.service
  "$systemctl_bin" is-active relay-native-new-api.service
fi
if [[ "$update_cpa" == true ]]; then "$systemctl_bin" is-active relay-native-cpa.service; fi
echo "installed release=$release_id mode=$mode update_new_api=$update_new_api update_cpa=$update_cpa"
