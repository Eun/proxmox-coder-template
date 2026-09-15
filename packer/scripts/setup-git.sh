#!/bin/bash
set -euo pipefail

AUTHOR_NAME="${1:-}"
AUTHOR_EMAIL="${2:-}"
export HOME=/home/coder

# --- Git identity ---
git config --global --add safe.directory "$HOME"
echo "→ git safe.directory += $HOME"

if [ -n "$AUTHOR_NAME" ]; then
  git config --global user.name "$AUTHOR_NAME"
  echo "→ git user.name = $AUTHOR_NAME"
fi
if [ -n "$AUTHOR_EMAIL" ]; then
  git config --global user.email "$AUTHOR_EMAIL"
  echo "→ git user.email = $AUTHOR_EMAIL"
fi

git config --global url."git@github.com:".insteadOf "https://github.com/"
echo "→ git url.insteadOf: https://github.com/ → git@github.com:"

# --- SSH config ---
mkdir -p "$HOME/.ssh/config.d" && chmod 700 "$HOME/.ssh"

echo 'Include config.d/*' > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

cat > "$HOME/.ssh/config.d/00-host-key-verification" << 'EOF'
Host *
    StrictHostKeyChecking accept-new
    VerifyHostKeyDNS yes
EOF
chmod 600 "$HOME/.ssh/config.d/00-host-key-verification"
echo "→ SSH config written"

# --- SSH signing ---
SIGNING_KEY="$HOME/.ssh/coder_signing"

if [ -f /etc/coder-agent.env ]; then
  source /etc/coder-agent.env
fi

if [ -n "${CODER_AGENT_TOKEN:-}" ] && [ -n "${CODER_AGENT_URL:-}" ]; then
  echo "Fetching Coder git SSH key from agent API..."
  GITSSH_RESPONSE=$(curl -sf \
    -H "Coder-Session-Token: $CODER_AGENT_TOKEN" \
    "${CODER_AGENT_URL}/api/v2/workspaceagents/me/gitsshkey" 2>/dev/null || true)
  if [ -n "$GITSSH_RESPONSE" ]; then
    echo "$GITSSH_RESPONSE" | jq -r '.private_key' > "$SIGNING_KEY"
    echo "$GITSSH_RESPONSE" | jq -r '.public_key' > "$SIGNING_KEY.pub"
    chmod 600 "$SIGNING_KEY"
    chmod 644 "$SIGNING_KEY.pub"
  fi
fi

if [ -f "$SIGNING_KEY" ]; then
  git config --global gpg.format ssh
  git config --global user.signingkey "$SIGNING_KEY"
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true

  GIT_EMAIL=$(git config --global user.email || true)
  if [ -n "$GIT_EMAIL" ] && [ -f "$SIGNING_KEY.pub" ]; then
    echo "$GIT_EMAIL $(cat "$SIGNING_KEY.pub")" > "$HOME/.ssh/allowed_signers"
    git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
  fi

  cat > "$HOME/.ssh/config.d/10-commit-signing" << SSHSIGNING
Host *
    IdentityFile $SIGNING_KEY
SSHSIGNING
  chmod 600 "$HOME/.ssh/config.d/10-commit-signing"
  echo "✅ Git commit signing enabled (SSH)"
fi

echo "✅ Git configured"