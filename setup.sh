#!/bin/bash
# setup.sh — Automated setup for Fusion 360 on Linux (Wine/Bottles)
#
# Applies all four confirmed fixes:
#   1. Compile fake_statvfs.so (disk space shim for Wine fstatfs)
#   2. Expand swap to 16 GB if needed (prevent OOM kill)
#   3. Create dxvk.conf in the Fusion360 bottle (Intel ANV crash fix)
#   4. Register adskidmgr:// URL handler (OAuth login fix)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# The script is idempotent — safe to re-run.

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
heading() { echo -e "\n${BOLD}==> $*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Paths ---
BOTTLES_DATA="$HOME/.var/app/com.usebottles.bottles/data/bottles"
BOTTLE_PATH="$BOTTLES_DATA/bottles/Fusion360"
SHIM_DEST="$BOTTLES_DATA/bottles/fake_statvfs.so"
DXVK_CONF_DEST="$BOTTLE_PATH/drive_c/dxvk.conf"
HANDLER_DEST="$HOME/adskidmgr-handler.sh"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/adskidmgr.desktop"

MANUAL_STEPS=()

# ─────────────────────────────────────────────────────────────────────────────
heading "Prerequisite checks"
# ─────────────────────────────────────────────────────────────────────────────

# Check Bottles Flatpak
if flatpak info com.usebottles.bottles &>/dev/null; then
    BOTTLES_VER=$(flatpak info com.usebottles.bottles 2>/dev/null | grep Version | awk '{print $2}')
    info "Bottles Flatpak found (version $BOTTLES_VER)"
else
    error "Bottles Flatpak not found. Install it first:"
    error "  flatpak install flathub com.usebottles.bottles"
    exit 1
fi

# Check gcc
if ! command -v gcc &>/dev/null; then
    error "gcc not found. Install build tools:"
    error "  sudo apt install build-essential"
    exit 1
fi
info "gcc found"

# Check Vulkan (optional but recommended)
if command -v vulkaninfo &>/dev/null; then
    info "vulkaninfo found"
else
    warn "vulkaninfo not found — install vulkan-tools to verify GPU support"
    warn "  sudo apt install vulkan-tools"
fi

# Check bottle exists
if [[ -d "$BOTTLE_PATH" ]]; then
    info "Fusion360 bottle found at $BOTTLE_PATH"
else
    warn "Fusion360 bottle not found at $BOTTLE_PATH"
    warn "You must create it in Bottles before running this script."
    warn "See README.md for bottle creation instructions."
    MANUAL_STEPS+=("Create a Fusion360 bottle in Bottles (Wine 11.0, Windows 10, DXVK enabled)")
    # Don't exit — we can still do the other steps
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Fix 1: Build fake_statvfs.so (disk space shim)"
# ─────────────────────────────────────────────────────────────────────────────

SRC="$SCRIPT_DIR/fake_statvfs.c"
if [[ ! -f "$SRC" ]]; then
    error "fake_statvfs.c not found at $SRC"
    error "Make sure all files from the repository are present."
    exit 1
fi

echo "Building shim..."
gcc -shared -fPIC -o "$SHIM_DEST" "$SRC" -ldl
info "Built and installed: $SHIM_DEST"

echo ""
echo "  You must now add this to your Fusion360 bottle's environment variables"
echo "  in Bottles (bottle settings -> Environment Variables):"
echo ""
echo "    LD_PRELOAD = $SHIM_DEST"
echo ""
MANUAL_STEPS+=("In Bottles > Fusion360 bottle > Environment Variables: set LD_PRELOAD=$SHIM_DEST")

# ─────────────────────────────────────────────────────────────────────────────
heading "Fix 2: Expand swap to 16 GB"
# ─────────────────────────────────────────────────────────────────────────────

SWAP_FILE="/swapfile"
CURRENT_SWAP_GB=0

if [[ -f "$SWAP_FILE" ]]; then
    CURRENT_SWAP_BYTES=$(stat -c%s "$SWAP_FILE" 2>/dev/null || echo 0)
    CURRENT_SWAP_GB=$(( CURRENT_SWAP_BYTES / 1024 / 1024 / 1024 ))
    info "Found existing swap file: ${CURRENT_SWAP_GB} GB"
fi

TARGET_SWAP_GB=16

if (( CURRENT_SWAP_GB >= TARGET_SWAP_GB )); then
    info "Swap is already ${CURRENT_SWAP_GB} GB — no change needed"
else
    echo "Current swap: ${CURRENT_SWAP_GB} GB. Expanding to ${TARGET_SWAP_GB} GB..."
    echo "(This requires sudo)"
    sudo swapoff "$SWAP_FILE" 2>/dev/null || true
    sudo fallocate -l "${TARGET_SWAP_GB}G" "$SWAP_FILE"
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
    sudo swapon "$SWAP_FILE"
    info "Swap expanded to ${TARGET_SWAP_GB} GB"

    # Ensure fstab entry exists
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE swap swap defaults 0 0" | sudo tee -a /etc/fstab > /dev/null
        info "Added $SWAP_FILE to /etc/fstab"
    else
        info "/etc/fstab already has $SWAP_FILE entry"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Fix 3: Create dxvk.conf in bottle (Intel ANV crash fix)"
# ─────────────────────────────────────────────────────────────────────────────

DXVK_SRC="$SCRIPT_DIR/dxvk.conf"
if [[ ! -f "$DXVK_SRC" ]]; then
    error "dxvk.conf not found at $DXVK_SRC"
    exit 1
fi

if [[ -d "$BOTTLE_PATH/drive_c" ]]; then
    cp "$DXVK_SRC" "$DXVK_CONF_DEST"
    info "Installed: $DXVK_CONF_DEST"

    echo ""
    echo "  You must also add this to your Fusion360 bottle's environment variables:"
    echo ""
    echo "    DXVK_CONFIG_FILE = C:\dxvk.conf"
    echo ""
    MANUAL_STEPS+=("In Bottles > Fusion360 bottle > Environment Variables: set DXVK_CONFIG_FILE=C:\\dxvk.conf")
else
    warn "Bottle drive_c not found — skipping dxvk.conf installation"
    warn "Once you create the Fusion360 bottle, run: cp $DXVK_SRC $DXVK_CONF_DEST"
    MANUAL_STEPS+=("After creating bottle: cp $DXVK_SRC $DXVK_CONF_DEST")
    MANUAL_STEPS+=("In Bottles > Fusion360 bottle > Environment Variables: set DXVK_CONFIG_FILE=C:\\dxvk.conf")
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Fix 4: Register adskidmgr:// URL handler (OAuth login)"
# ─────────────────────────────────────────────────────────────────────────────

# Install handler script
cp "$SCRIPT_DIR/adskidmgr-handler.sh" "$HANDLER_DEST"
chmod +x "$HANDLER_DEST"
info "Installed handler: $HANDLER_DEST"

# Try to auto-detect the AdskIdentityManager.exe hash
ADSK_EXE_PATH=""
if [[ -d "$BOTTLE_PATH/drive_c" ]]; then
    ADSK_EXE_PATH=$(find "$BOTTLE_PATH/drive_c" -name "AdskIdentityManager.exe" 2>/dev/null | head -1)
fi

if [[ -n "$ADSK_EXE_PATH" ]]; then
    ADSK_HASH=$(echo "$ADSK_EXE_PATH" | sed 's|.*/production/\([^/]*\)/.*|\1|')
    info "Detected AdskIdentityManager hash: $ADSK_HASH"
    # Patch the handler with the real hash
    sed -i "s|<HASH>|$ADSK_HASH|g" "$HANDLER_DEST"
    info "Handler patched with real hash"
else
    warn "AdskIdentityManager.exe not found yet — handler will auto-detect at runtime"
    warn "Install Fusion 360 first, then re-run setup.sh to bake in the hash."
fi

# Create .desktop file
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Autodesk Identity Manager
Exec=$HANDLER_DEST %u
MimeType=x-scheme-handler/adskidmgr;
NoDisplay=true
Terminal=false
EOF
info "Created: $DESKTOP_FILE"

# Register the handler
xdg-mime default adskidmgr.desktop x-scheme-handler/adskidmgr
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
info "Registered adskidmgr:// URL scheme handler"

# ─────────────────────────────────────────────────────────────────────────────
heading "Setup complete — Summary"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}Automated steps completed:${RESET}"
echo "  [1] fake_statvfs.so built and placed at: $SHIM_DEST"
echo "  [2] Swap expanded to ${TARGET_SWAP_GB} GB"
echo "  [3] dxvk.conf installed (if bottle exists)"
echo "  [4] adskidmgr:// URL handler registered"
echo ""

if (( ${#MANUAL_STEPS[@]} > 0 )); then
    echo -e "${YELLOW}Manual steps still required:${RESET}"
    i=1
    for step in "${MANUAL_STEPS[@]}"; do
        echo "  [$i] $step"
        (( i++ ))
    done
    echo ""
fi

echo -e "${BOLD}Bottle settings checklist (in Bottles > Fusion360 > Settings):${RESET}"
echo "  - Runner:     sys-wine-11.0 (or latest Wine stable)"
echo "  - Windows:    Windows 10"
echo "  - DXVK:       Enabled (dxvk-2.x)"
echo "  - Renderer:   gl  (NOT vulkan)"
echo "  - Virtual desktop: ENABLED, resolution = your screen resolution"
echo "  - DLL overrides:   Leave empty (do NOT add d3d11 or dxgi)"
echo ""
echo -e "${BOLD}Environment Variables to add in Bottles:${RESET}"
echo "  LD_PRELOAD       = $SHIM_DEST"
echo "  DXVK_CONFIG_FILE = C:\\dxvk.conf"
echo ""
echo "See README.md for full instructions and troubleshooting."
