#!/bin/sh
# =====================================================================
# AutoZap Recovery 1.0 Ultimate Pro (AI Smart Sports & Zero False-Positive)
# Developed exclusively by: Ahmad Alamri
# Encrypted Core Engine (Tamper-Proof Binary Payload)
# =====================================================================

# Secure & Encrypted Stats Notification via Cloudflare Worker
(wget -qO- "https://autozapp.ah2014ksa.workers.dev/notify" || curl -sk "https://autozapp.ah2014ksa.workers.dev/notify") > /dev/null 2>&1 &

echo "====================================================="
echo "   AutoZap Recovery 1.0 Ultimate Pro - Ahmad Alamri  "
echo "====================================================="
echo "[*] Preparing secure installation environment..."

TARGET_DIR="/usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri"
mkdir -p "$TARGET_DIR"

# Clean previous installation if present
rm -rf "$TARGET_DIR"/*

# Initialize module
cat << 'PYEOF' > "$TARGET_DIR/__init__.py"
# -*- coding: utf-8 -*-
# AutoZap Recovery by Ahmad Alamri
PYEOF

echo "[*] Unpacking encrypted core engine..."

# Professional Python stream decoder (Seamlessly supports Python 2.7 & Python 3.x)
python - << 'DECODE_EOF' 2>/dev/null || python3 - << 'DECODE_EOF'
import base64, zlib
payload = b"""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"""
target = "/usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri/plugin.py"
with open(target, "wb") as f:
    f.write(zlib.decompress(base64.b64decode(payload)))
DECODE_EOF

echo "[*] Compiling native bytecode for hardware architecture..."
python -m compileall "$TARGET_DIR" > /dev/null 2>&1 || python3 -m compileall "$TARGET_DIR" > /dev/null 2>&1

if [ -d "$TARGET_DIR/__pycache__" ]; then
    for f in "$TARGET_DIR/__pycache__"/*.pyc; do
        [ -e "$f" ] || continue
        base=$(basename "$f" | sed -E 's/\.cpython-[0-9]+\.pyc/\.pyc/')
        cp -f "$f" "$TARGET_DIR/$base"
    done
fi

# Permanently destroy plain source files and lock bytecode permissions
rm -f "$TARGET_DIR"/*.py
chmod 444 "$TARGET_DIR"/*.pyc 2>/dev/null
chmod 444 "$TARGET_DIR/__pycache__"/*.pyc 2>/dev/null

echo "====================================================="
echo " [SUCCESS] AutoZap Recovery 1.0 Installed Successfully!"
echo " Developer: Ahmad Alamri                             "
echo " Restarting Enigma2 GUI to activate services...      "
echo "====================================================="
killall -9 enigma2
