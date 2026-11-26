#!/usr/bin/env bash
# Emit OS/ARCH in forms useful for downloads (GOOS/GOARCH + uname variants).
set -euo pipefail

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  darwin|linux) ;;
  msys*|mingw*|cygwin*) OS=windows ;;
  *) echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=arm ;;
  *) echo "unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

# kind release asset uses "amd64"/"arm64"; some tools use "x86_64"
case "$ARCH" in
  amd64) ARCH_ALT=x86_64 ;;
  arm64) ARCH_ALT=arm64 ;;
  *) ARCH_ALT="$ARCH" ;;
esac

cat <<EOF
OS=$OS
ARCH=$ARCH
ARCH_ALT=$ARCH_ALT
GOOS=$OS
GOARCH=$ARCH
PLATFORM=${OS}/${ARCH}
EOF
