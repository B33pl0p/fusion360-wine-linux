#!/bin/bash
# adskidmgr-handler.sh — Custom URL scheme handler for Autodesk Identity Manager
#
# Autodesk's web sign-in uses an adskidmgr:// callback URL. When the OAuth
# flow completes in the browser, the OS needs to hand the callback URL back to
# the identity manager running inside Wine. On Linux there is no built-in
# handler for this scheme, so login hangs with "No apps installed" in Chrome.
#
# This script is registered as the system handler for x-scheme-handler/adskidmgr
# and uses `flatpak run --command=/app/bin/wine` to invoke AdskIdentityManager.exe
# inside the Bottles Wine prefix. The --command form (instead of launching
# Bottles directly) is critical: it shares the *already-running* wineserver via
# /run/user/1000/.flatpak/com.usebottles.bottles/tmp/ rather than spawning a
# new isolated instance.
#
# Installation:
#   1. Edit ADSK_IDM_EXE below to match the hash in your installation path, OR
#      run setup.sh which detects the hash automatically.
#   2. cp adskidmgr-handler.sh ~/adskidmgr-handler.sh
#   3. chmod +x ~/adskidmgr-handler.sh
#   4. Create adskidmgr.desktop and run:
#        xdg-mime default adskidmgr.desktop x-scheme-handler/adskidmgr
#        update-desktop-database ~/.local/share/applications/

LOG="$HOME/adskidmgr-handler.log"
echo "$(date): handler called with: $1" >> "$LOG"

# --- CONFIGURE THIS ---
# Replace <HASH> with the actual directory name found under:
#   ~/.var/app/com.usebottles.bottles/data/bottles/bottles/Fusion360/
#   drive_c/users/$USER/AppData/Local/Autodesk/webdeploy/production/<HASH>/
#
# Run this command to find it:
#   find ~/.var/app/com.usebottles.bottles/data/bottles/bottles/Fusion360/drive_c \
#        -name "AdskIdentityManager.exe" 2>/dev/null
#
ADSK_HASH="<HASH>"
ADSK_IDM_EXE="C:\\users\\$USER\\AppData\\Local\\Autodesk\\webdeploy\\production\\${ADSK_HASH}\\Autodesk Identity Manager\\AdskIdentityManager.exe"

WINE_PREFIX="$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/Fusion360"
# ----------------------

if [[ "$ADSK_HASH" == "<HASH>" ]]; then
    # Try to auto-detect
    FOUND=$(find "$WINE_PREFIX/drive_c" -name "AdskIdentityManager.exe" 2>/dev/null | head -1)
    if [[ -n "$FOUND" ]]; then
        ADSK_HASH=$(echo "$FOUND" | sed 's|.*/production/\([^/]*\)/.*|\1|')
        ADSK_IDM_EXE="C:\\users\\$USER\\AppData\\Local\\Autodesk\\webdeploy\\production\\${ADSK_HASH}\\Autodesk Identity Manager\\AdskIdentityManager.exe"
        echo "$(date): auto-detected hash: $ADSK_HASH" >> "$LOG"
    else
        echo "$(date): ERROR: could not find AdskIdentityManager.exe — is Fusion 360 installed?" >> "$LOG"
        exit 1
    fi
fi

flatpak run \
    --command=/app/bin/wine \
    --env=WINEPREFIX="$WINE_PREFIX" \
    com.usebottles.bottles \
    "$ADSK_IDM_EXE" "$1" >> "$LOG" 2>&1

echo "$(date): wine exited with code $?" >> "$LOG"
