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

build_cpa
build_new_api

cat > "$output_dir/manifest.txt" <<EOF
release_id=$release_id
root_sha=$root_sha
cpa_sha=$cpa_sha
new_api_sha=$new_api_sha
build_date=$build_date
cpa_version=$(cat "$output_dir/cpa-version.txt")
database_migration=review-required
production_deploy=not-authorized
EOF

(cd "$output_dir" && sha256sum CLIProxyAPI-linux-amd64 new-api-linux-amd64 manifest.txt > SHA256SUMS.txt)
tar -C "$(dirname "$output_dir")" -czf "$output_dir.tar.gz" "$(basename "$output_dir")"
