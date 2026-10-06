#!/usr/bin/env bash
set -euo pipefail

release_id="${RELEASE_ID:?RELEASE_ID is required}"
output_dir="${OUTPUT_DIR:-output/$release_id}"

mkdir -p "$output_dir"

root_sha="$(git rev-parse HEAD)"
cpa_sha="$(git -C CLIProxyAPI-main rev-parse HEAD)"
new_api_sha="$(git -C new-api-main rev-parse HEAD)"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

build_cpa() {
  local version="${CPA_VERSION:-$(git -C CLIProxyAPI-main describe --tags --always --dirty)}"
  (cd CLIProxyAPI-main && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.Version=$version -X main.Commit=$cpa_sha -X main.BuildDate=$build_date" \
      -o "../$output_dir/CLIProxyAPI-linux-amd64" ./cmd/server)
  printf '%s\n' "$version" > "$output_dir/cpa-version.txt"
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

build_cpa
build_new_api
include_management_panel

cat > "$output_dir/manifest.txt" <<EOF
release_id=$release_id
root_sha=$root_sha
cpa_sha=$cpa_sha
new_api_sha=$new_api_sha
build_date=$build_date
cpa_version=$(cat "$output_dir/cpa-version.txt")
management_panel_sha256=$(sha256sum "$output_dir/management.html" 2>/dev/null | awk '{print $1}' || true)
database_migration=review-required
production_deploy=not-authorized
EOF

(cd "$output_dir" && sha256sum CLIProxyAPI-linux-amd64 new-api-linux-amd64 manifest.txt management.html 2>/dev/null > SHA256SUMS.txt || sha256sum CLIProxyAPI-linux-amd64 new-api-linux-amd64 manifest.txt > SHA256SUMS.txt)
tar -C "$(dirname "$output_dir")" -czf "$output_dir.tar.gz" "$(basename "$output_dir")"
