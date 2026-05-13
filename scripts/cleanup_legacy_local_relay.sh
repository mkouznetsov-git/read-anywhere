#!/usr/bin/env bash
set -Eeuo pipefail

APPLY=false

if [[ "${1:-}" == "--apply" ]]; then
  APPLY=true
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: scripts/cleanup_legacy_local_relay.sh [--apply]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

run_cmd() {
  if [[ "$APPLY" == "true" ]]; then
    "$@"
  else
    printf '[dry-run] '
    printf '%q ' "$@"
    echo
  fi
}

echo "ReadArc legacy local relay cleanup"
echo "Root: $ROOT"
echo "Mode: $([[ "$APPLY" == "true" ]] && echo apply || echo dry-run)"
echo

FILES_TO_REMOVE=(
  "scripts/run_local_relay.sh"
  "scripts/tailscale_start_funnel.sh"
  "scripts/tailscale_status.sh"
  "scripts/install_local_relay_service_macos.sh"
  "scripts/uninstall_local_relay_service_macos.sh"
  "scripts/install_local_relay_service_linux.sh"
  "scripts/uninstall_local_relay_service_linux.sh"
)

echo "Removing obsolete local relay / Tailscale scripts..."
for file in "${FILES_TO_REMOVE[@]}"; do
  if [[ -e "$file" ]]; then
    if git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
      run_cmd git rm "$file"
    else
      run_cmd rm -f "$file"
    fi
  else
    echo "Already absent: $file"
  fi
done

echo
echo "Updating README_RU.md and relay health helper..."

python3 - "$APPLY" <<'PY'
from pathlib import Path
import difflib
import re
import sys

apply = sys.argv[1].lower() == "true"

def write_or_diff(path: Path, new_text: str):
    old_text = path.read_text() if path.exists() else ""
    if old_text == new_text:
        print(f"No changes: {path}")
        return

    if apply:
        path.write_text(new_text)
        print(f"Updated: {path}")
    else:
        print(f"\n--- diff: {path} ---")
        for line in difflib.unified_diff(
            old_text.splitlines(True),
            new_text.splitlines(True),
            fromfile=str(path),
            tofile=str(path),
        ):
            print(line, end="")
        print()

readme = Path("README_RU.md")
if readme.exists():
    s = readme.read_text()

    s = s.replace(
        "READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_android.sh",
        "READARC_DEFAULT_RELAY_URL=https://relay.readarc.ru ./scripts/package_android.sh",
    )
    s = s.replace(
        "repository variable `READANYWHERE_DEFAULT_RELAY_URL`",
        "repository variable `READARC_DEFAULT_RELAY_URL`",
    )

    s = re.sub(
        r"\n## Sprint 4\.1: Personal Hub \+ Tailscale Funnel\n.*?(?=\n## Sprint 4\.1 cleanup:)",
        """
## Архив: Personal Hub / Tailscale Funnel

Историческая документация по локальному relay, Tailscale Funnel и Cloudflare Tunnel сохранена в `docs/`, но актуальный production-режим ReadArc использует официальный relay:

```text
https://relay.readarc.ru
mkdir -p scripts

cat > scripts/cleanup_legacy_local_relay.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APPLY=false

if [[ "${1:-}" == "--apply" ]]; then
  APPLY=true
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: scripts/cleanup_legacy_local_relay.sh [--apply]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

run_cmd() {
  if [[ "$APPLY" == "true" ]]; then
    "$@"
  else
    printf '[dry-run] '
    printf '%q ' "$@"
    echo
  fi
}

echo "ReadArc legacy local relay cleanup"
echo "Root: $ROOT"
echo "Mode: $([[ "$APPLY" == "true" ]] && echo apply || echo dry-run)"
echo

FILES_TO_REMOVE=(
  "scripts/run_local_relay.sh"
  "scripts/tailscale_start_funnel.sh"
  "scripts/tailscale_status.sh"
  "scripts/install_local_relay_service_macos.sh"
  "scripts/uninstall_local_relay_service_macos.sh"
  "scripts/install_local_relay_service_linux.sh"
  "scripts/uninstall_local_relay_service_linux.sh"
)

echo "Removing obsolete local relay and Tailscale scripts..."
for file in "${FILES_TO_REMOVE[@]}"; do
  if [[ -e "$file" ]]; then
    if git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
      run_cmd git rm "$file"
    else
      run_cmd rm -f "$file"
    fi
  else
    echo "Already absent: $file"
  fi
done

echo
echo "Updating README_RU.md and relay health helper..."

python3 - "$APPLY" <<'PY'
from pathlib import Path
import difflib
import re
import sys

apply = sys.argv[1].lower() == "true"

def write_or_diff(path: Path, new_text: str) -> None:
    old_text = path.read_text() if path.exists() else ""
    if old_text == new_text:
        print(f"No changes: {path}")
        return

    if apply:
        path.write_text(new_text)
        print(f"Updated: {path}")
        return

    print(f"\n--- diff: {path} ---")
    for line in difflib.unified_diff(
        old_text.splitlines(True),
        new_text.splitlines(True),
        fromfile=str(path),
        tofile=str(path),
    ):
        print(line, end="")
    print()

readme = Path("README_RU.md")
if readme.exists():
    s = readme.read_text()

    s = s.replace(
        "READANYWHERE_DEFAULT_RELAY_URL=https://your-service.koyeb.app ./scripts/package_android.sh",
        "READARC_DEFAULT_RELAY_URL=https://relay.readarc.ru ./scripts/package_android.sh",
    )

    s = s.replace(
        "repository variable `READANYWHERE_DEFAULT_RELAY_URL`",
        "repository variable `READARC_DEFAULT_RELAY_URL`",
    )

    archive_block = """
## Архив: Personal Hub / Tailscale Funnel

Историческая документация по локальному relay, Tailscale Funnel и Cloudflare Tunnel сохранена в папке docs.

Актуальный production-режим ReadArc использует официальный relay:

    https://relay.readarc.ru

Скрипты локального relay и Tailscale удалены из актуального набора scripts, чтобы не путать production-сценарий.

"""

    s = re.sub(
        r"\n## Sprint 4\.1: Personal Hub \+ Tailscale Funnel\n.*?(?=\n## Sprint 4\.1 cleanup:)",
        "\n" + archive_block,
        s,
        flags=re.S,
    )

    s = re.sub(
        r"\n### Personal Hub connectivity hotfix\n\n.*?(?=\n\n## Sprint 4\.2:)",
        "\n",
        s,
        flags=re.S,
    )

    s = s.replace("Добавлен MVP-pairing:", "Добавлено подключение по коду:")

    s = s.replace(
        "Ручной ввод `accountId` оставлен только как fallback для разработки.",
        "Ручной ввод `accountId` больше не является основным production-сценарием.",
    )

    write_or_diff(readme, s)

health = Path("scripts/check_relay_health.sh")
if health.exists():
    s = health.read_text()

    old = 'RELAY_URL="${1:-${READANYWHERE_RELAY_URL:-http://127.0.0.1:8787}}"'
    new = 'RELAY_URL="${1:-${READARC_RELAY_URL:-${READANYWHERE_RELAY_URL:-https://relay.readarc.ru}}}"'

    if old in s:
        s = s.replace(old, new)
    elif "READANYWHERE_RELAY_URL" in s and "READARC_RELAY_URL" not in s:
        s = s.replace("READANYWHERE_RELAY_URL", "READARC_RELAY_URL")

    write_or_diff(health, s)
PY

echo
echo "Post-check: remaining legacy matches"
echo "These matches may be expected in historical docs, protocol compatibility, or release cleanup logic."
echo

grep -R "run_local_relay\|tailscale\|local_relay\|readanywhere" \
  -n . \
  --exclude-dir=.git \
  --exclude-dir=build \
  --exclude-dir=.dart_tool \
  --exclude-dir=.idea \
  --exclude="cleanup_legacy_local_relay.sh" || true

echo
if [[ "$APPLY" == "true" ]]; then
  echo "Cleanup applied."
  echo "Review with:"
  echo "  git status"
  echo "  git diff --cached"
  echo "  git diff"
else
  echo "Dry-run completed."
  echo "To apply:"
  echo "  scripts/cleanup_legacy_local_relay.sh --apply"
fi
