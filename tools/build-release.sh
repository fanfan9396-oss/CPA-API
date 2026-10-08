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
cpa_ref="${CPA_REF:-$(git -C CLIProxyAPI-main rev-parse HEAD)}"
new_api_ref="${NEW_API_REF:-$(git -C new-api-main rev-parse HEAD)}"
cpa_sha="$(git -C CLIProxyAPI-main rev-parse HEAD)"
new_api_sha="$(git -C new-api-main rev-parse HEAD)"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cpa_version=""
cpa_panel_repository="${CPA_PANEL_REPOSITORY:-https://github.com/fanfan9396-oss/Cli-Proxy-API-Management-Centert-Center}"
cpa_panel_ref="${CPA_PANEL_REF:-}"
cpa_repository="${CPA_REPOSITORY:-https://github.com/router-for-me/CLIProxyAPI.git}"
new_api_repository="${NEW_API_REPOSITORY:-https://github.com/fanfan9396-oss/new-api.git}"

if [[ -n "${CPA_REF:-}" ]]; then
  expected_cpa_sha="$(git -C CLIProxyAPI-main rev-parse "${CPA_REF}^{commit}")" || {
    echo "CPA_REF does not resolve: $cpa_ref" >&2
    exit 2
  }
  [[ "$expected_cpa_sha" == "$cpa_sha" ]] || {
    echo "CPA_REF $cpa_ref does not match checked-out CPA SHA $cpa_sha" >&2
    exit 2
  }
fi
if [[ -n "${NEW_API_REF:-}" ]]; then
  expected_new_api_sha="$(git -C new-api-main rev-parse "${NEW_API_REF}^{commit}")" || {
    echo "NEW_API_REF does not resolve: $new_api_ref" >&2
    exit 2
  }
  [[ "$expected_new_api_sha" == "$new_api_sha" ]] || {
    echo "NEW_API_REF $new_api_ref does not match checked-out New API SHA $new_api_sha" >&2
    exit 2
  }
fi

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
  [[ -n "$cpa_panel_ref" ]] || { echo 'CPA_PANEL_REF is required for cpa/full releases' >&2; exit 2; }
  local repo_path="${cpa_panel_repository#https://github.com/}"
  repo_path="${repo_path#ssh://git@github.com/}"
  repo_path="${repo_path%.git}"
  local panel_tmp panel_archive panel_root downloaded_digest
  panel_tmp="$(mktemp -d)"
  panel_archive="$panel_tmp/panel.tar.gz"
  trap 'rm -rf "$panel_tmp"' RETURN
  curl --fail --location --silent --show-error --retry 3 \
    "https://codeload.github.com/${repo_path}/tar.gz/${cpa_panel_ref}" -o "$panel_archive"
  tar -xzf "$panel_archive" -C "$panel_tmp"
  panel_root="$(find "$panel_tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$panel_root" ]] || { echo 'management panel source archive is empty' >&2; exit 1; }
  (cd "$panel_root" && bun install --frozen-lockfile && bun run build)
  install -m 0644 "$panel_root/dist/index.html" "$output_dir/management.html"
  [[ -s "$output_dir/management.html" ]] || { echo 'management panel build is empty' >&2; exit 1; }
  downloaded_digest="$(sha256sum "$output_dir/management.html" | awk '{print $1}')"
  printf '%s  %s\n' "$downloaded_digest" management.html > "$output_dir/management.html.sha256"
  (cd "$output_dir" && sha256sum -c management.html.sha256)
}

if [[ "$component" == "cpa" || "$component" == "full" ]]; then
  build_cpa
fi
if [[ "$component" == "new-api" || "$component" == "full" ]]; then
  build_new_api
fi
if [[ "$component" == "cpa" || "$component" == "full" ]]; then
  include_management_panel
  [[ -s "$output_dir/management.html" ]] || { echo 'CPA and full releases require the selected CPA management panel' >&2; exit 1; }
fi

compatibility_id=""
if [[ "$component" == "cpa" || "$component" == "full" ]]; then
  compatibility_id="${CPA_COMPATIBILITY_ID:-cpa-${cpa_ref}-panel-${cpa_panel_ref}}"
fi

cat > "$output_dir/manifest.txt" <<EOF
release_id=$release_id
component=$component
root_sha=$root_sha
cpa_sha=$cpa_sha
new_api_sha=$new_api_sha
build_date=$build_date
cpa_version=$cpa_version
cpa_ref=$cpa_ref
cpa_repository=$cpa_repository
cpa_resolved_sha=$cpa_sha
cpa_panel_repository=$cpa_panel_repository
cpa_panel_ref=$cpa_panel_ref
compatibility_id=$compatibility_id
new_api_ref=$new_api_ref
new_api_repository=$new_api_repository
new_api_resolved_sha=$new_api_sha
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
