#!/usr/bin/env bash
# Install workshop CLI tools into ./bin (repo-local, no sudo, no Homebrew):
#   kind, kubectl, helm, jq, krew (+ kubectl-cnpg plugin via krew)
#
# A tool is only installed when it is NOT already usable on PATH: if the
# system copy (Homebrew, apt, choco, ./bin, ...) exists and meets the minimum
# version below, it is left alone. Missing or too-old tools are installed at
# the pinned version into BIN_DIR, which the Makefile puts first on PATH.
# Checksums are verified where upstream publishes them.
#
# Env (set by the Makefile; defaults here for standalone use):
#   BIN_DIR OS ARCH KIND_VERSION KUBECTL_VERSION HELM_VERSION JQ_VERSION
#   KIND_MIN KUBECTL_MIN HELM_MIN JQ_MIN   minimum acceptable versions
#   FORCE=1  ignore system copies and install pinned versions into BIN_DIR
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${BIN_DIR:-$ROOT/bin}"
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.2}"
HELM_VERSION="${HELM_VERSION:-v4.3.1}"
JQ_VERSION="${JQ_VERSION:-1.8.1}"
FORCE="${FORCE:-0}"

# Minimums: kind 0.33 is the first to generate kubeadm v1beta4 for v1.37 nodes;
# kubectl must be within one minor of the v1.37 server; helm 3.x is EOL.
KIND_MIN="${KIND_MIN:-0.33.0}"
KUBECTL_MIN="${KUBECTL_MIN:-1.36.0}"
HELM_MIN="${HELM_MIN:-4.0.0}"
JQ_MIN="${JQ_MIN:-1.6}"

# --- platform -------------------------------------------------------------
if [[ -z "${OS:-}" ]]; then
  case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac
fi
if [[ -z "${ARCH:-}" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
fi

# Apple Silicon under Rosetta reports x86_64 — you'd get Intel binaries and,
# worse, an amd64 loadgen image inside arm64 kind nodes.
if [[ "$OS" == darwin && "$ARCH" == amd64 ]] && \
   [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" == 1 ]]; then
  echo "WARN: this shell runs under Rosetta on Apple Silicon; installing arm64 tools instead." >&2
  echo "      Open a native terminal (or run: arch -arm64 make ...) for the rest of the setup." >&2
  ARCH=arm64
fi

EXE=""; [[ "$OS" == windows ]] && EXE=".exe"
mkdir -p "$BIN_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

export PATH="$BIN_DIR:${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
echo "Checking tools for $OS/$ARCH (missing ones go into $BIN_DIR)"

# --- helpers --------------------------------------------------------------
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# verify FILE EXPECTED_HASH
verify() {
  local got; got="$(sha256 "$1")"
  if [[ "$got" != "$2" ]]; then
    echo "ERROR: checksum mismatch for $(basename "$1")" >&2
    echo "  expected $2" >&2; echo "  got      $got" >&2
    exit 1
  fi
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# ver_ge A B -> true if version A >= B
ver_ge() { [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# usable NAME MIN VERSION_CMD... -> 0 if NAME on PATH (incl. BIN_DIR) is >= MIN
usable() {
  local name="$1" min="$2"; shift 2
  [[ "$FORCE" == 1 ]] && return 1
  local path; path="$(command -v "$name$EXE" 2>/dev/null || command -v "$name" 2>/dev/null)" || {
    echo "$name: not found"; return 1; }
  local v; v="$("$path" "$@" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  if [[ -n "$v" ]] && ver_ge "$v" "$min"; then
    echo "$name $v: ok ($path)"; return 0
  fi
  echo "$name ${v:-?} at $path is older than $min — installing pinned version into $BIN_DIR"
  return 1
}

# --- kind -----------------------------------------------------------------
if ! usable kind "$KIND_MIN" version; then
  echo "Downloading kind $KIND_VERSION..."
  url="https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$OS-$ARCH"
  fetch "$url" "$TMP/kind"
  fetch "$url.sha256sum" "$TMP/kind.sha"
  verify "$TMP/kind" "$(awk '{print $1}' "$TMP/kind.sha")"
  install -m 0755 "$TMP/kind" "$BIN_DIR/kind$EXE"
fi

# --- kubectl --------------------------------------------------------------
if ! usable kubectl "$KUBECTL_MIN" version --client; then
  echo "Downloading kubectl $KUBECTL_VERSION..."
  url="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl$EXE"
  fetch "$url" "$TMP/kubectl"
  fetch "$url.sha256" "$TMP/kubectl.sha"
  verify "$TMP/kubectl" "$(awk '{print $1}' "$TMP/kubectl.sha")"
  install -m 0755 "$TMP/kubectl" "$BIN_DIR/kubectl$EXE"
fi

# --- helm -----------------------------------------------------------------
if ! usable helm "$HELM_MIN" version --short; then
  echo "Downloading helm $HELM_VERSION..."
  ext="tar.gz"; [[ "$OS" == windows ]] && ext="zip"
  file="helm-$HELM_VERSION-$OS-$ARCH.$ext"
  fetch "https://get.helm.sh/$file" "$TMP/$file"
  fetch "https://get.helm.sh/$file.sha256sum" "$TMP/helm.sha"
  verify "$TMP/$file" "$(awk '{print $1}' "$TMP/helm.sha")"
  if [[ "$ext" == zip ]]; then unzip -q "$TMP/$file" -d "$TMP"
  else tar -xzf "$TMP/$file" -C "$TMP"; fi
  install -m 0755 "$TMP/$OS-$ARCH/helm$EXE" "$BIN_DIR/helm$EXE"
fi

# --- jq -------------------------------------------------------------------
if ! usable jq "$JQ_MIN" --version; then
  echo "Downloading jq $JQ_VERSION..."
  jq_os="$OS"; [[ "$OS" == darwin ]] && jq_os=macos
  asset="jq-$jq_os-$ARCH$EXE"
  base="https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION"
  fetch "$base/$asset" "$TMP/jq"
  fetch "$base/sha256sum.txt" "$TMP/jq.sums"
  verify "$TMP/jq" "$(awk -v a="$asset" '$2==a {print $1}' "$TMP/jq.sums")"
  install -m 0755 "$TMP/jq" "$BIN_DIR/jq$EXE"
fi

# --- krew + cnpg plugin ---------------------------------------------------
# krew installs into ${KREW_ROOT:-~/.krew} (the Makefile already puts
# ~/.krew/bin on PATH). Windows: use `choco install krew` or WSL.
if [[ "$OS" == windows ]]; then
  echo "krew: skipped on Windows (choco install kubernetes-krew, or use WSL)"
else
  if [[ "$FORCE" != 1 ]] && kubectl krew version >/dev/null 2>&1; then
    echo "krew: ok ($(command -v kubectl-krew || echo "$HOME/.krew/bin/kubectl-krew"))"
  else
    echo "Installing krew..."
    krew="krew-${OS}_${ARCH}"
    base="https://github.com/kubernetes-sigs/krew/releases/latest/download"
    fetch "$base/$krew.tar.gz" "$TMP/$krew.tar.gz"
    fetch "$base/$krew.tar.gz.sha256" "$TMP/krew.sha"
    verify "$TMP/$krew.tar.gz" "$(awk '{print $1}' "$TMP/krew.sha")"
    tar -xzf "$TMP/$krew.tar.gz" -C "$TMP"
    "$TMP/$krew" install krew >/dev/null
  fi
  if kubectl cnpg version >/dev/null 2>&1; then
    echo "kubectl-cnpg: ok"
  else
    echo "Installing kubectl cnpg plugin..."
    kubectl krew update >/dev/null 2>&1 || true
    kubectl krew install cnpg
  fi
fi

echo ""
echo "Using:"
for t in kind kubectl helm jq; do printf '  %-8s %s\n' "$t" "$(command -v "$t$EXE" || command -v "$t")"; done
if [[ -n "$(ls -A "$BIN_DIR" 2>/dev/null)" ]]; then
  echo ""
  echo "make targets already use $BIN_DIR. For your own shell, add:"
  echo "  export PATH=\"$BIN_DIR:\${KREW_ROOT:-\$HOME/.krew}/bin:\$PATH\""
fi
