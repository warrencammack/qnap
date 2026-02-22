#!/bin/bash
set -e

echo "Verifying project tooling..."

# GitHub CLI
if command -v gh &> /dev/null; then
  if gh auth status &> /dev/null; then
    echo "✓ GitHub CLI authenticated"
  else
    echo "✗ GitHub CLI not authenticated. Run: gh auth login"
    exit 1
  fi
else
  echo "⚠ GitHub CLI not installed. Run: brew install gh"
fi

# SSH key for QNAP
if [ -f ~/.ssh/qnap_rsa_key ]; then
  echo "✓ QNAP SSH key found (~/.ssh/qnap_rsa_key)"
else
  echo "⚠ QNAP SSH key not found at ~/.ssh/qnap_rsa_key"
  echo "  Generate with: ssh-keygen -t rsa -b 4096 -f ~/.ssh/qnap_rsa_key"
fi

# SSH connectivity (optional check)
if command -v ssh &> /dev/null; then
  echo "✓ SSH client available"
fi

echo ""
echo "Tooling verification complete!"
