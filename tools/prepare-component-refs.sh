#!/usr/bin/env bash
set -euo pipefail

component="${COMPONENT:-full}"
cpa_ref="${CPA_REF:-}"
new_api_ref="${NEW_API_REF:-}"
cpa_repo="${CPA_REPOSITORY:-https://github.com/router-for-me/CLIProxyAPI.git}"
new_api_repo="${NEW_API_REPOSITORY:-https://github.com/fanfan9396-oss/new-api.git}"

case "$component" in
  cpa|full) [[ -n "$cpa_ref" ]] || { echo 'CPA_REF is required for cpa/full builds' >&2; exit 2; } ;;
esac
case "$component" in
  new-api|full) [[ -n "$new_api_ref" ]] || { echo 'NEW_API_REF is required for new-api/full builds' >&2; exit 2; } ;;
esac

prepare_ref() {
  local directory="$1" repository="$2" ref="$3"
  git -C "$directory" diff --quiet --ignore-submodules -- . || { echo "$directory has tracked changes" >&2; exit 1; }
  git -C "$directory" fetch --no-tags "$repository" "$ref"
  git -C "$directory" checkout --detach FETCH_HEAD
}

if [[ "$component" == "cpa" || "$component" == "full" ]]; then
  prepare_ref CLIProxyAPI-main "$cpa_repo" "$cpa_ref"
fi
if [[ "$component" == "new-api" || "$component" == "full" ]]; then
  prepare_ref new-api-main "$new_api_repo" "$new_api_ref"
fi

echo "prepared component=$component cpa_ref=${cpa_ref:-unchanged} new_api_ref=${new_api_ref:-unchanged}"
