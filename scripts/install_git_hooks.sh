#!/usr/bin/env bash
# Installs a plain git pre-commit hook that runs gitleaks on staged changes.
# Use this if you don't have Python's pre-commit (works in Git Bash on Windows).
# Requires gitleaks on PATH: https://github.com/gitleaks/gitleaks/releases
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT_DIR/.git/hooks/pre-commit"
[[ -d "$ROOT_DIR/.git" ]] || { echo "Run inside the git repo." >&2; exit 1; }

cat > "$HOOK" <<'HOOK'
#!/usr/bin/env bash
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "pre-commit: gitleaks not installed - commit blocked. Install it or ask Asher." >&2
  exit 1
fi
gitleaks protect --staged --config .gitleaks.toml --redact -v || {
  echo "pre-commit: possible secret found - commit blocked (Spec 4.9 §4)." >&2
  echo "If a real password was ever committed, CHANGE that password now." >&2
  exit 1
}
HOOK
chmod +x "$HOOK"
echo "Installed $HOOK"
