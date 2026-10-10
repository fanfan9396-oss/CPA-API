#!/usr/bin/env bash
set -euo pipefail

component="${COMPONENT:?COMPONENT must be new-api or cpa}"
upstream_ref="${UPSTREAM_REF:?UPSTREAM_REF is required}"
target_branch="${TARGET_BRANCH:?TARGET_BRANCH is required}"

case "$component" in
  new-api)
    directory='new-api-main'
    upstream_url="${UPSTREAM_URL:-https://github.com/QuantumNous/new-api.git}"
    ;;
  cpa)
    directory='CLIProxyAPI-main'
    upstream_url="${UPSTREAM_URL:-https://github.com/router-for-me/CLIProxyAPI.git}"
    ;;
  *) echo 'COMPONENT must be new-api or cpa' >&2; exit 2 ;;
esac

git -C "$directory" diff --quiet --ignore-submodules -- . || { echo "$directory has tracked changes" >&2; exit 1; }
git -C "$directory" show-ref --verify --quiet "refs/heads/$target_branch" || {
  echo "target branch not found: $target_branch" >&2
  exit 1
}
git -C "$directory" checkout "$target_branch"
git -C "$directory" fetch --no-tags "$upstream_url" "$upstream_ref"

if [[ "$component" == "new-api" ]]; then
  protected_paths=(
    model/request_policy.go
    model/request_policy_test.go
    service/content_audit.go
    service/content_audit_test.go
    controller/request_policy.go
    web/src/features/system-settings/request-policies/defaults.ts
    web/src/features/system-settings/request-policies/request-checks-section.tsx
    web/src/features/system-settings/request-policies/section-registry.tsx
  )
  protected_changes="$(git -C "$directory" diff --name-only HEAD FETCH_HEAD -- "${protected_paths[@]}")"
  if [[ -n "$protected_changes" && "${ALLOW_PROTECTED_OVERLAY_UPDATE:-false}" != "true" ]]; then
    echo 'upstream touches protected New API audit settings; set ALLOW_PROTECTED_OVERLAY_UPDATE=true only after manual review' >&2
    printf '%s\n' "$protected_changes" >&2
    exit 1
  fi
fi

git -C "$directory" merge --no-ff --no-edit FETCH_HEAD
echo "merged component=$component upstream_ref=$upstream_ref into branch=$target_branch"
