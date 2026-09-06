#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

HELPER_DIR=/usr/local/lib/netbar
HELPER=$HELPER_DIR/netbar-docker
SUDOERS=/etc/sudoers.d/netbar-docker

die() { printf '{"ok": false, "error": %s}\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (use pkexec)"

TARGET_UID=${PKEXEC_UID:-${SUDO_UID:-}}
[[ -n $TARGET_UID ]] || die "cannot determine which user to authorize"
TARGET_USER=$(getent passwd "$TARGET_UID" | cut -d: -f1)
[[ -n $TARGET_USER ]] || die "no user for uid $TARGET_UID"

if [[ ${1:-} == --disable ]]; then
  rm -f "$SUDOERS" "$HELPER"
  rmdir "$HELPER_DIR" 2>/dev/null || true
  printf '{"ok": true, "enabled": false, "user": "%s"}\n' "$TARGET_USER"
  exit 0
fi

command -v docker >/dev/null || die "docker is not installed"

install -d -o root -g root -m 0755 "$HELPER_DIR"

cat > "$HELPER" <<'HELPEREOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
case "${1:-}" in
  ps)
    exec docker ps --format '{{.ID}}	{{.Names}}	{{.Image}}	{{.Ports}}'
    ;;
  stop)
    id=${2:-}
    [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "bad container id" >&2; exit 2; }
    exec docker stop -- "$id"
    ;;
  *)
    echo "usage: netbar-docker {ps|stop <id>}" >&2
    exit 2
    ;;
esac
HELPEREOF
chown root:root "$HELPER"
chmod 0755 "$HELPER"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
# Installed by NetBar. Remove with: netbar-enable-docker.sh --disable
$TARGET_USER ALL=(root) NOPASSWD: $HELPER
EOF
chmod 0440 "$tmp"
visudo -cqf "$tmp" || die "generated sudoers rule failed validation"
install -o root -g root -m 0440 "$tmp" "$SUDOERS"

printf '{"ok": true, "enabled": true, "user": "%s"}\n' "$TARGET_USER"
