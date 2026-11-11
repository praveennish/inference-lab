#!/usr/bin/env bash
# Installs the project's tools. Safe to re-run: each step skips if already installed.
# Run manually with: bash .devcontainer/setup.sh
set -euo pipefail

TERRAFORM_VERSION="1.11.4"
BIN_DIR="/usr/local/bin"

case "$(uname -m)" in
  x86_64) TF_ARCH="amd64"; AWS_ARCH="x86_64" ;;
  aarch64 | arm64) TF_ARCH="arm64"; AWS_ARCH="aarch64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! command -v unzip >/dev/null || ! command -v zip >/dev/null; then
  echo "==> Installing zip and unzip"
  sudo apt-get update -qq && sudo apt-get install -y -qq zip unzip
fi

if ! terraform version 2>/dev/null | grep -q "v${TERRAFORM_VERSION}"; then
  echo "==> Installing Terraform ${TERRAFORM_VERSION}"
  base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  zip="terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip"
  curl -fsSL --retry 3 -o "$tmp/$zip" "$base/$zip"
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  (cd "$tmp" && grep " ${zip}\$" SHA256SUMS | sha256sum -c -)
  unzip -o -q "$tmp/$zip" -d "$tmp"
  sudo install -m 0755 "$tmp/terraform" "$BIN_DIR/terraform"
fi

if ! command -v aws >/dev/null; then
  echo "==> Installing AWS CLI v2"
  curl -fsSL --retry 3 -o "$tmp/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  sudo "$tmp/aws/install" --update
fi

if ! command -v uv >/dev/null; then
  echo "==> Installing uv"
  pipx install uv
fi

echo "==> Installing Python dependencies"
uv sync --all-groups

echo
terraform version | head -1
aws --version
uv --version
echo "==> Setup complete"
