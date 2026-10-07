#!/usr/bin/env bash
set -euo pipefail

release_id="${RELEASE_ID:?RELEASE_ID is required}"
output_dir="${OUTPUT_DIR:-output/$release_id}"
component="${COMPONENT:-full}"

case "$component" in
  new-api|cpa|full) ;;
  *) echo "COMPONENT must be new-api, cpa, or full" >&2; exit 2 ;;
esac

mkdir -p "$output_dir"
rm -f "$output_dir/CLIProxyAPI-linux-amd64" "$output_dir/new-api-linux-amd64" \
  "$output_dir/cpa-version.txt" "$output_dir/management.html" \
  "$output_dir/management.html.sha256" "$output_dir/manifest.txt" \
  "$output_dir/SHA256SUMS.txt" "$output_dir.tar.gz"

root_sha="$(git rev-parse HEAD)"
cpa_sha="$(git -C CLIProxyAPI-main rev-parse HEAD)"
new_api_sha="$(git -C new-api-main rev-parse HEAD)"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cpa_version=""

build_cpa() {
  local version="${CPA_VERSION:-$(git -C CLIProxyAPI-main describe --tags --always --dirty)}"
  (cd CLIProxyAPI-main && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.Version=$version -X main.Commit=$cpa_sha -X main.BuildDate=$build_date" \
      -o "../$output_dir/CLIProxyAPI-linux-amd64" ./cmd/server)
  printf '%s\n' "$version" > "$output_dir/cpa-version.txt"
  cpa_version="$version"
}

build_new_api() {
  (cd new-api-main/web && bun install --frozen-lockfile && \
    DISABLE_ESLINT_PLUGIN=true VITE_REACT_APP_VERSION="$release_id" bun run build)
  (cd new-api-main && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X github.com/QuantumNous/new-api/common.Version=$release_id" \
      -o "../$output_dir/new-api-linux-amd64" ./)
}

include_management_panel() {
  local panel_path="${CPA_PANEL_PATH:-}"
  local panel_url="${CPA_PANEL_URL:-}"
  local panel_sha="${CPA_PANEL_SHA256:-}"
  if [[ -n "$panel_path" ]]; then
    install -m 0644 "$panel_path" "$output_dir/management.html"
  elif [[ -n "$panel_url" ]]; then
    [[ -n "$panel_sha" ]] || { echo 'CPA_PANEL_SHA256 is required with CPA_PANEL_URL' >&2; exit 1; }
    curl --fail --location --silent --show-error --retry 3 "$panel_url" -o "$output_dir/management.html"
  else
    return 0
  fi
  [[ -s "$output_dir/management.html" ]] || { echo 'management panel is empty' >&2; exit 1; }
  if [[ -n "$panel_sha" ]]; then
    printf '%s  %s\n' "$panel_sha" management.html > "$output_dir/management.html.sha256"
    (cd "$output_dir" && sha256sum -c management.html.sha256)
  else
    echo 'CPA_PANEL_SHA256 is required when a management panel is supplied' >&2
    exit 1
  fi
}

if [[ "$component" == "cpa" || "$component" == "full" ]]; then
  build_cpa
fi
if [[ "$component" == "new-api" || "$component" == "full" ]]; then
  build_new_api
fi
if [[ "$component" == "cpa" || "$component" == "full" ]]; then
  include_management_panel
  [[ -s "$output_dir/management.html" ]] || { echo 'CPA and full releases require a pinned management panel' >&2; exit 1; }
fi

cat > "$output_dir/manifest.txt" <<EOF
release_id=$release_id
component=$component
root_sha=$root_sha
cpa_sha=$cpa_sha
new_api_sha=$new_api_sha
build_date=$build_date
cpa_version=$cpa_version
management_panel_sha256=$(sha256sum "$output_dir/management.html" 2>/dev/null | awk '{print $1}' || true)
database_migration=review-required
production_deploy=not-authorized
EOF

files=(manifest.txt)
[[ "$component" == "cpa" || "$component" == "full" ]] && files+=(CLIProxyAPI-linux-amd64)
[[ "$component" == "new-api" || "$component" == "full" ]] && files+=(new-api-linux-amd64)
[[ -f "$output_dir/management.html" ]] && files+=(management.html)
(cd "$output_dir" && sha256sum "${files[@]}" > SHA256SUMS.txt)
tar -C "$(dirname "$output_dir")" -czf "$output_dir.tar.gz" "$(basename "$output_dir")"
