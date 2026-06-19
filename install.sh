#!/usr/bin/env bash

set -e

REPO="andrewinsoul/devpulse"
VERSION="${VERSION:-latest}"

OS="$(uname -s)"
ARCH="$(uname -m)"

if [[ "$OS" == "Darwin" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    BINARY="devpulse-macos-arm64"
  else
    BINARY="devpulse-macos-x86_64"
  fi
elif [[ "$OS" == "Linux" ]]; then
  BINARY="devpulse-linux-x86_64"
else
  echo "Unsupported OS"
  exit 1
fi

URL="https://github.com/$REPO/releases/download/$VERSION/$BINARY"

echo "Downloading $URL"

curl -L --fail "$URL" -o devpulse
chmod +x devpulse

mkdir -p "$HOME/.local/bin"
mv devpulse "$HOME/.local/bin/devpulse"

echo "Installed DevPulse ✔"