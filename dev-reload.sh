#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if command -v /usr/lib/qt6/bin/qmllint >/dev/null; then
  imports="$(mktemp -d)"
  mkdir -p "$imports/qs"
  ln -sfn /usr/share/omarchy/shell/Ui "$imports/qs/Ui"
  ln -sfn /usr/share/omarchy/shell/Commons "$imports/qs/Commons"
  if /usr/lib/qt6/bin/qmllint -I "$imports" -I /usr/lib/qt6/qml NetBar.qml Service.qml 2>&1 \
      | grep -E '\[syntax\]|\[unqualified\]'; then
    rm -rf "$imports"
    echo "qmllint found problems; not reloading." >&2
    exit 1
  fi
  rm -rf "$imports"
fi

/usr/bin/python3 -c "import ast,sys; ast.parse(open('netbar-scan.py').read())"

omarchy restart shell
echo "NetBar reloaded."
