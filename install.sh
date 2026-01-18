#!/bin/bash
set -e

# Thaings installer
# Usage: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/danott/thaings/main/install.sh)"

THAINGS_ROOT="$HOME/.thaings"
REPO_URL="https://github.com/danott/thaings.git"

echo "Installing Thaings..."
echo

if [ -d "$THAINGS_ROOT" ]; then
  echo "Updating existing installation..."
  git -C "$THAINGS_ROOT" pull --ff-only
else
  echo "Cloning repository..."
  git clone "$REPO_URL" "$THAINGS_ROOT"
fi

echo
exec "$THAINGS_ROOT/bin/install"
