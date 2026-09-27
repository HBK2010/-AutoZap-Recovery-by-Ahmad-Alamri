#!/bin/sh
# ================================================================
#   AutoZap Recovery - Full Uninstaller (all versions)
#   Designed & Developed by: Ahmad Alamri
#   (C) 2026 Ahmad Alamri - All Rights Reserved
# ================================================================
PLUGIN_DIR="/usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri"

echo ""
echo ">>> Removing AutoZap Recovery (all versions)..."
if [ -d "$PLUGIN_DIR" ]; then
    command -v chattr >/dev/null 2>&1 && chattr -R -i "$PLUGIN_DIR" >/dev/null 2>&1
    chmod -R u+w "$PLUGIN_DIR" >/dev/null 2>&1
    rm -rf "$PLUGIN_DIR"
fi
rm -f /tmp/autozap.log /tmp/autozap.log.1 /tmp/*autozap* >/dev/null 2>&1

# settings are removed while the GUI is stopped (otherwise Enigma2 rewrites them)
cat > /tmp/autozap_wipe.sh << 'AZ_EOF'
S=/etc/enigma2/settings
if [ -f "$S" ]; then
    grep -v '^config\.plugins\.autozap_alamri\.' "$S" > /tmp/az_settings.new
    cat /tmp/az_settings.new > "$S"
    rm -f /tmp/az_settings.new
fi
AZ_EOF

# ---------------------------------------------------------------
# Safe GUI restart - runs detached so it also works when this
# script was started from a terminal plugin inside Enigma2.
# $1 = optional shell file to run while the GUI is stopped
# ---------------------------------------------------------------
az_restart_gui() {
    R=/tmp/autozap_restart.sh
    {
        echo '#!/bin/sh'
        echo 'sleep 2'
        echo 'if command -v systemctl >/dev/null 2>&1 && systemctl is-active enigma2 >/dev/null 2>&1; then'
        echo '    systemctl stop enigma2; sleep 2'
        [ -n "$1" ] && echo "    sh $1"
        echo '    systemctl start enigma2'
        echo 'else'
        echo '    init 4 >/dev/null 2>&1'
        echo '    i=0'
        echo '    while pidof enigma2 >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done'
        [ -n "$1" ] && echo "    sh $1"
        echo '    if pidof enigma2 >/dev/null 2>&1; then killall -9 enigma2 >/dev/null 2>&1; else init 3 >/dev/null 2>&1; fi'
        echo 'fi'
        [ -n "$1" ] && echo "rm -f $1"
        echo 'rm -f /tmp/autozap_restart.sh'
    } > "$R"
    chmod 755 "$R"
    if command -v nohup >/dev/null 2>&1; then
        nohup sh "$R" >/dev/null 2>&1 &
    else
        sh "$R" >/dev/null 2>&1 &
    fi
}

echo ">>> Plugin files removed. Settings will be wiped and the GUI restarted..."
az_restart_gui /tmp/autozap_wipe.sh
exit 0
