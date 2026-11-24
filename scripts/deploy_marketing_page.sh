#!/usr/bin/env bash
set -euo pipefail

: "${MARKETING_BUCKET:?Set MARKETING_BUCKET to the site bucket}"
: "${MARKETING_DISTRIBUTION:?Set MARKETING_DISTRIBUTION to the site distribution}"

state_key=.well-known/deployed-marketing-revision
site_path=marketing-page
origin="s3://$MARKETING_BUCKET/"
tree=$(git rev-parse "HEAD:$site_path")
if [[ ! -f "$site_path/index.html" || -e "$site_path/$state_key" ||
      -n $(find "$site_path" -type l -print -quit) ]]; then
  echo 'The marketing page needs an index and cannot contain symlinks or the deployment state key.' >&2
  exit 1
fi

state_file=$(mktemp)
error_file=$(mktemp)
trap 'rm -- "$state_file" "$error_file"' EXIT

if aws s3api get-object --bucket "$MARKETING_BUCKET" --key "$state_key" "$state_file" \
  >/dev/null 2>"$error_file"; then
  if [[ $(cat "$state_file") == "$tree" ]]; then
    echo "Marketing files already deployed ($tree)."
    exit 0
  fi
elif ! grep -q '(NoSuchKey)' "$error_file"; then
  cat "$error_file" >&2
  exit 1
fi

write_state() {
  printf '%s\n' "$1" > "$state_file"
  aws s3api put-object --bucket "$MARKETING_BUCKET" --key "$state_key" \
    --body "$state_file" --content-type text/plain >/dev/null
}

# An interrupted upload must be repaired even if main reverts to the old tree.
write_state in-progress

# Upload every changed tree in full, with the entry point last. The final sync
# removes retired assets from this dedicated bucket without recopying files.
aws s3 cp "$site_path/" "$origin" --recursive --no-follow-symlinks --only-show-errors \
  --exclude index.html --exclude '*.mjs' --exclude "$state_key"
aws s3 cp "$site_path/" "$origin" --recursive --no-follow-symlinks --only-show-errors \
  --exclude '*' --include '*.mjs' --content-type text/javascript
aws s3 cp "$site_path/index.html" "${origin}index.html" --only-show-errors \
  --content-type text/html
aws s3 sync "$site_path/" "$origin" --delete --size-only --no-follow-symlinks \
  --only-show-errors --exclude "$state_key"

invalidation=$(aws cloudfront create-invalidation --distribution-id "$MARKETING_DISTRIBUTION" \
  --paths '/*' --query Invalidation.Id --output text)
aws cloudfront wait invalidation-completed --distribution-id "$MARKETING_DISTRIBUTION" \
  --id "$invalidation"
for host in ageoflever.com www.ageoflever.com; do
  if ! curl --fail --silent --show-error --retry 2 --max-time 25 \
    --proto '=https' "https://$host/" | cmp "$site_path/index.html" -; then
    echo "The checked index was not served by https://$host/." >&2
    exit 1
  fi
done
write_state "$tree"
echo "Published marketing tree $tree (CloudFront invalidation $invalidation)."
