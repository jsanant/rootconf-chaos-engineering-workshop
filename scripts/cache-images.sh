#!/usr/bin/env bash
# Pull images listed in artifacts/images.txt and save as tar under artifacts/images/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="${1:-$ROOT/artifacts/images.txt}"
OUT="${IMAGE_CACHE_DIR:-$ROOT/artifacts/images}"
mkdir -p "$OUT"

safe_name() {
  echo "$1" | sed -e 's|/|_|g' -e 's|:|__|g'
}

while IFS= read -r line || [[ -n "$line" ]]; do
  img="$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$img" ]] && continue
  tar="$OUT/$(safe_name "$img").tar"
  echo "==> pull $img"
  docker pull "$img"
  echo "==> save $tar"
  docker save -o "$tar" "$img"
done < "$LIST"

echo "Cached images in $OUT"
