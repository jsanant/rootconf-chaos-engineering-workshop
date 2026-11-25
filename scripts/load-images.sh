#!/usr/bin/env bash
# Load cached image tars into local docker and (optionally) into a kind cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${IMAGE_CACHE_DIR:-$ROOT/artifacts/images}"
CLUSTER="${CLUSTER_NAME:-cnpg-chaos}"
LOAD_KIND="${LOAD_KIND:-1}"

if [[ ! -d "$DIR" ]]; then
  echo "missing image cache dir: $DIR (run: make cache)" >&2
  exit 1
fi

shopt -s nullglob
tars=("$DIR"/*.tar)
if [[ ${#tars[@]} -eq 0 ]]; then
  echo "no *.tar files in $DIR" >&2
  exit 1
fi

for tar in "${tars[@]}"; do
  echo "==> docker load $tar"
  docker load -i "$tar"
done

if [[ "$LOAD_KIND" == "1" ]] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  for tar in "${tars[@]}"; do
    # Skip the kind node image archive; kind create already uses it from docker.
    base="$(basename "$tar")"
    if [[ "$base" == kindest_node* ]]; then
      continue
    fi
    echo "==> kind load image-archive $tar -> $CLUSTER"
    kind load image-archive "$tar" --name "$CLUSTER"
  done
fi

echo "Loaded cached images"
