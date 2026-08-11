#!/data/data/com.termux/files/usr/bin/bash
# Run Local Chat server on an Android phone via Termux + Tailscale.
set -euo pipefail
cd "$(dirname "$0")"

VENV=.venv

echo "Local Chat (Termux) — ensure Tailscale app is Connected on this phone."

# A venv copied from Windows has Scripts/ instead of bin/ and cannot be used here.
if [ -d "$VENV" ] && [ ! -x "$VENV/bin/python" ]; then
  echo "Found a non-Termux venv (no bin/python). Recreating..."
  rm -rf "$VENV"
fi

if [ ! -d "$VENV" ]; then
  echo "Creating venv (with system site-packages so Termux's prebuilt"
  echo "python-cryptography can be reused instead of compiling Rust)..."
  python -m venv --system-site-packages "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null

# Rust-backed wheels (pydantic-core, cryptography) build via maturin, which cannot
# detect this on its own. 24 is Termux's minimum API level, so it works everywhere.
export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"
echo "ANDROID_API_LEVEL=$ANDROID_API_LEVEL"

echo "Installing dependencies..."
if ! python -m pip install --prefer-binary -r requirements.txt; then
  echo
  echo "Full install failed (usually a native build: cryptography / grpcio)."
  echo "Tip: pkg install python-cryptography python-grpcio c-ares rust openssl libffi clang make"
  echo "Falling back to requirements-termux.txt — chat works, FCM push disabled."
  echo
  python -m pip install --prefer-binary -r requirements-termux.txt
fi

if python -c "import firebase_admin" 2>/dev/null; then
  echo "FCM: firebase-admin available (push wake-ups possible)."
else
  echo "FCM: firebase-admin missing — local/WebSocket notifications only."
fi

# Keep CPU awake while chatting (requires Termux:API / termux-wake-lock).
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock || true
fi

if command -v tailscale >/dev/null 2>&1; then
  echo "This device Tailscale IPv4: $(tailscale ip -4 2>/dev/null || echo unknown)"
else
  echo "Tip: open the Tailscale Android app and copy this phone's 100.x.x.x IP."
fi

# Survive SSH drops: re-exec inside tmux when available and not already in one.
if command -v tmux >/dev/null 2>&1 && [ -z "${TMUX:-}" ]; then
  echo "Starting server inside tmux session 'localchat' (detach: Ctrl+B then D)."
  exec tmux new-session -A -s localchat "python run.py"
fi

python run.py
