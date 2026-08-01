#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <path> [path ...]" >&2
  exit 2
fi

patterns=(
  '-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'
  'ssh-rsa [A-Za-z0-9+/=]{80,}'
  'sk-[A-Za-z0-9_-]{20,}'
  'sk-proj-[A-Za-z0-9_-]{20,}'
  'ghp_[A-Za-z0-9_]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{20,}'
  'AKIA[0-9A-Z]{16}'
  'AIza[0-9A-Za-z_-]{20,}'
  'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
  '(password|passwd|pwd|api[_ -]?key|token|secret|passkey)[[:space:]]*[:=][[:space:]]*[^[:space:]`'\''"]{6,}'
)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for target in "$@"; do
  if [ ! -e "$target" ]; then
    echo "WARN missing path: $target" >&2
    continue
  fi

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      [ -n "${file:-}" ] || continue
      case "$match" in
        *REDACTED*|*'<APP_API_KEY_FROM_CONFIG>'*|*'<PLEX_TOKEN_FROM_CONFIG>'*|*'<REPLACE'*|*'<YOUR_'*|*'your_'*|*'example.com'*|*'token=$('*|*'apiKey = REDACTED'*)
          continue
          ;;
      esac
      echo "POTENTIAL_SECRET ${file}:${line}" >> "$tmp"
    done < <(
      rg --hidden --glob '!**/.git/**' --glob '!**/.agents/skills/**' --glob '!**/.claude/skills/**' --glob '!**/.claude/worktrees/**/.claude/skills/**' --glob '!**/node_modules/**' --glob '!**/*.zip' --glob '!**/*.png' --glob '!**/*.jpg' --glob '!**/*.jpeg' --glob '!**/*.sqlite' --glob '!**/*.db' --line-number --no-heading -i "$pattern" "$target" 2>/dev/null || true
    )
  done
done

sort -u "$tmp"

if [ -s "$tmp" ]; then
  echo "Secret scan found potential leaks. Review the file/line locations without pasting secret values into docs." >&2
  exit 1
fi

exit 0
