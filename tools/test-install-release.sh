#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo 'test must run as root' >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_dir/tools/install-release.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fake_install="$tmp/install"
cat >"$fake_install" <<'FAKE_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-g|-m) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
/usr/bin/install "${args[@]}"
FAKE_INSTALL
chmod +x "$fake_install"

make_systemctl() {
  local path="$1"
  cat >"$path" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
if [[ "${1:-}" == is-active ]]; then
  printf 'active\n'
fi
FAKE_SYSTEMCTL
  chmod +x "$path"
}

make_package() {
  local component="$1"
  local package_path="$2"
  local root="$tmp/package-$component"
  local release="$root/release-$component"
  rm -rf -- "$root"
  mkdir -p "$release"
  printf 'release_id=release-%s\n' "$component" >"$release/manifest.txt"
  printf 'component=%s\n' "$component" >>"$release/manifest.txt"
  printf 'production_deploy=not-authorized\n' >>"$release/manifest.txt"
  if [[ "$component" == cpa || "$component" == full ]]; then
    printf 'cpa_ref=test-cpa\ncpa_panel_ref=test-panel\ncompatibility_id=test-compat\n' >>"$release/manifest.txt"
  fi
  if [[ "$component" == new-api || "$component" == full ]]; then
    printf 'new-api-%s\n' "$component" >"$release/new-api-linux-amd64"
  fi
  if [[ "$component" == cpa || "$component" == full ]]; then
    printf 'cpa-%s\n' "$component" >"$release/CLIProxyAPI-linux-amd64"
    printf '<html>%s</html>\n' "$component" >"$release/management.html"
    printf 'v-test\n' >"$release/cpa-version.txt"
  fi
  files=(manifest.txt)
  [[ "$component" == new-api || "$component" == full ]] && files+=(new-api-linux-amd64)
  [[ "$component" == cpa || "$component" == full ]] && files+=(CLIProxyAPI-linux-amd64 management.html)
  (cd "$release" && sha256sum "${files[@]}" >SHA256SUMS.txt)
  tar -czf "$package_path" -C "$root" "$(basename "$release")"
}

assert_file() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(cat "$path")"
  [[ "$actual" == "$expected" ]] || { echo "expected $path to be '$expected', got '$actual'" >&2; exit 1; }
}

run_case() {
  local name="$1"
  local mode="$2"
  local base="$tmp/base-$name"
  local log="$tmp/systemctl-$name.log"
  local output
  mkdir -p "$base/bin/static"
  printf 'old-new-api\n' >"$base/bin/new-api"
  printf 'old-cpa\n' >"$base/bin/CLIProxyAPI"
  printf 'old-panel\n' >"$base/bin/static/management.html"
  : >"$log"
  make_systemctl "$tmp/systemctl-$name"
  output="$(RELAY_NATIVE_BASE="$base" INSTALL_BIN="$fake_install" SYSTEMCTL_BIN="$tmp/systemctl-$name" SYSTEMCTL_LOG="$log" bash "$installer" --package "$tmp/full.tar.gz" "$mode")"
  printf '%s\n' "$output"
  printf '%s\n' "$output" | grep -Fq 'manifest_component=full'
  (cd "$base/releases/release-full" && sha256sum -c SHA256SUMS.txt >/dev/null)
  case "$mode" in
    --new-api-only)
      printf '%s\n' "$output" | grep -Fq 'will_update=new-api'
      printf '%s\n' "$output" | grep -Fq 'will_not_update=cpa'
      assert_file 'new-api-full' "$base/bin/new-api"
      assert_file 'old-cpa' "$base/bin/CLIProxyAPI"
      assert_file 'old-panel' "$base/bin/static/management.html"
      grep -Fxq 'restart relay-native-new-api.service' "$log"
      ! grep -Fq 'relay-native-cpa.service' "$log"
      ;;
    --cpa-only)
      printf '%s\n' "$output" | grep -Fq 'will_update=cpa'
      printf '%s\n' "$output" | grep -Fq 'will_not_update=new-api'
      assert_file 'old-new-api' "$base/bin/new-api"
      assert_file 'cpa-full' "$base/bin/CLIProxyAPI"
      assert_file '<html>full</html>' "$base/bin/static/management.html"
      grep -Fxq 'restart relay-native-cpa.service' "$log"
      ! grep -Fq 'relay-native-new-api.service' "$log"
      ;;
    --all)
      printf '%s\n' "$output" | grep -Fq 'will_update=new-api,cpa'
      printf '%s\n' "$output" | grep -Fq 'will_not_update=none'
      assert_file 'new-api-full' "$base/bin/new-api"
      assert_file 'cpa-full' "$base/bin/CLIProxyAPI"
      assert_file '<html>full</html>' "$base/bin/static/management.html"
      grep -Fxq 'restart relay-native-new-api.service' "$log"
      grep -Fxq 'restart relay-native-cpa.service' "$log"
      ;;
  esac
}

make_package full "$tmp/full.tar.gz"
run_case new-api-only --new-api-only
run_case cpa-only --cpa-only
run_case all --all

plan_base="$tmp/base-plan"
mkdir -p "$plan_base/bin/static"
printf 'old-new-api\n' >"$plan_base/bin/new-api"
printf 'old-cpa\n' >"$plan_base/bin/CLIProxyAPI"
printf 'old-panel\n' >"$plan_base/bin/static/management.html"
plan_output="$(RELAY_NATIVE_BASE="$plan_base" INSTALL_BIN="$fake_install" SYSTEMCTL_BIN="$tmp/unused-systemctl" TMPDIR="$tmp" bash "$installer" --package "$tmp/full.tar.gz" --new-api-only --plan)"
printf '%s\n' "$plan_output" | grep -Fq 'plan_only=true'
printf '%s\n' "$plan_output" | grep -Fq 'will_update=new-api'
assert_file 'old-new-api' "$plan_base/bin/new-api"
assert_file 'old-cpa' "$plan_base/bin/CLIProxyAPI"
assert_file 'old-panel' "$plan_base/bin/static/management.html"
[[ ! -e "$plan_base/releases" ]]

make_package new-api "$tmp/new-api.tar.gz"
new_api_base="$tmp/base-new-api"
make_systemctl "$tmp/systemctl-new-api"
mkdir -p "$new_api_base/bin/static"
printf 'old-cpa\n' >"$new_api_base/bin/CLIProxyAPI"
RELAY_NATIVE_BASE="$new_api_base" INSTALL_BIN="$fake_install" SYSTEMCTL_BIN="$tmp/systemctl-new-api" SYSTEMCTL_LOG="$tmp/systemctl-new-api.log" bash "$installer" --package "$tmp/new-api.tar.gz" --new-api-only >/dev/null
assert_file 'new-api-new-api' "$new_api_base/bin/new-api"

make_package cpa "$tmp/cpa.tar.gz"
cpa_base="$tmp/base-cpa"
make_systemctl "$tmp/systemctl-cpa"
mkdir -p "$cpa_base/bin/static"
printf 'old-new-api\n' >"$cpa_base/bin/new-api"
RELAY_NATIVE_BASE="$cpa_base" INSTALL_BIN="$fake_install" SYSTEMCTL_BIN="$tmp/systemctl-cpa" SYSTEMCTL_LOG="$tmp/systemctl-cpa.log" bash "$installer" --package "$tmp/cpa.tar.gz" --cpa-only >/dev/null
assert_file 'cpa-cpa' "$cpa_base/bin/CLIProxyAPI"
assert_file '<html>cpa</html>' "$cpa_base/bin/static/management.html"

make_systemctl "$tmp/systemctl-invalid"
if RELAY_NATIVE_BASE="$tmp/base-invalid" INSTALL_BIN="$fake_install" SYSTEMCTL_BIN="$tmp/systemctl-invalid" SYSTEMCTL_LOG="$tmp/systemctl-invalid.log" bash "$installer" --package "$tmp/new-api.tar.gz" --all >/dev/null 2>&1; then
  echo 'incompatible all/new-api package unexpectedly succeeded' >&2
  exit 1
fi

printf 'install-release tests: PASS\n'