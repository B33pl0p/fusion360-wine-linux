#!/bin/bash
# setup.sh — Automated setup for Fusion 360 on Linux (Wine/Bottles)
#
# Applies all four confirmed fixes:
#   1. Compile fake_statvfs.so (disk space shim for Wine fstatfs)
#   2. Expand swap to 16 GB if needed (prevent OOM kill)
#   3. Create dxvk.conf in the Fusion360 bottle (Intel ANV crash fix)
#   4. Register adskidmgr:// URL handler (OAuth login fix)
#
# Supported distributions:
#   - Ubuntu / Debian (and derivatives like Zorin OS, Pop!_OS, Linux Mint)
#   - Arch Linux (and derivatives like Manjaro, EndeavourOS)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh            # normal run
#   ./setup.sh --dry-run  # preview all actions without executing sudo commands
#
# The script is idempotent — safe to re-run.

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Colours & helpers
# ─────────────────────────────────────────────────────────────────────────────

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
heading() { echo -e "\n${BOLD}==> $*${RESET}"; }
dryrun_step() { echo -e "${CYAN}  ->  ${RESET}$*"; }

# --dry-run / --help flag parsing
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run]"
            echo ""
            echo "  --dry-run   Print all actions without executing sudo commands."
            echo "              Useful for auditing what the script will do before running it."
            exit 0
            ;;
        *)
            error "Unknown argument: $arg"
            echo "Usage: $0 [--dry-run]"
            exit 1
            ;;
    esac
done

if $DRY_RUN; then
    warn "DRY-RUN mode: sudo commands will be printed but not executed."
fi

# Wrapper: run or preview sudo commands
run_sudo() {
    if $DRY_RUN; then
        dryrun_step "[dry-run] sudo $*"
    else
        sudo "$@"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Distro detection
# ─────────────────────────────────────────────────────────────────────────────

heading "Detecting Linux distribution"

DISTRO="unknown"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"

    if [[ "$OS_ID" == "arch" || "$OS_ID_LIKE" == *"arch"* ]]; then
        DISTRO="arch"
    elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_ID_LIKE" == *"ubuntu"* || "$OS_ID_LIKE" == *"debian"* ]]; then
        DISTRO="debian"
    fi

    info "Detected: $OS_PRETTY (DISTRO=$DISTRO)"
else
    warn "Could not read /etc/os-release — package hints will be generic"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Package hint helper — prints the right install command for missing packages
# Usage: pkg_hint "<arch-pkg>" "<debian-pkg>"
# ─────────────────────────────────────────────────────────────────────────────

pkg_hint() {
    local arch_pkg="$1"
    local debian_pkg="$2"
    case "$DISTRO" in
        arch)   echo "  sudo pacman -S --needed $arch_pkg" ;;
        debian) echo "  sudo apt install $debian_pkg" ;;
        *)      echo "  Arch:   sudo pacman -S --needed $arch_pkg"
                echo "  Ubuntu: sudo apt install $debian_pkg" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# GPU auto-detection (best-effort, for Vulkan driver hints)
# ─────────────────────────────────────────────────────────────────────────────

detect_gpu() {
    local gpu="unknown"
    for vendor_file in /sys/class/drm/card*/device/vendor; do
        [[ -f "$vendor_file" ]] || continue
        local vendor_id
        vendor_id=$(cat "$vendor_file" 2>/dev/null)
        case "$vendor_id" in
            0x8086) gpu="intel";  break ;;
            0x1002) gpu="amd";    break ;;
            0x10de) gpu="nvidia"; break ;;
        esac
    done
    echo "$gpu"
}

GPU=$(detect_gpu)
if [[ "$GPU" != "unknown" ]]; then
    info "Detected GPU vendor: $GPU"
else
    warn "Could not auto-detect GPU vendor — Vulkan hints will cover all options"
fi

vulkan_pkg_hint() {
    case "$DISTRO" in
        arch)
            case "$GPU" in
                intel)  echo "  sudo pacman -S --needed vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader" ;;
                amd)    echo "  sudo pacman -S --needed vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader" ;;
                nvidia) echo "  sudo pacman -S --needed nvidia-utils lib32-nvidia-utils vulkan-icd-loader lib32-vulkan-icd-loader" ;;
                *)      printf "  Intel:  sudo pacman -S --needed vulkan-intel lib32-vulkan-intel vulkan-icd-loader\n"
                        printf "  AMD:    sudo pacman -S --needed vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader\n"
                        printf "  Nvidia: sudo pacman -S --needed nvidia-utils lib32-nvidia-utils vulkan-icd-loader\n" ;;
            esac
            ;;
        debian)
            case "$GPU" in
                intel)  echo "  sudo apt install intel-media-va-driver libvulkan1 mesa-vulkan-drivers" ;;
                amd)    echo "  sudo apt install mesa-vulkan-drivers libvulkan1" ;;
                nvidia) echo "  sudo apt install libvulkan1 nvidia-driver" ;;
                *)      echo "  sudo apt install libvulkan1 mesa-vulkan-drivers" ;;
            esac
            ;;
        *)  echo "  Install Vulkan drivers for your GPU. See your distro's wiki." ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

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

# Check Flatpak is installed
if command -v flatpak &>/dev/null; then
    info "flatpak found"
else
    error "flatpak not found. Install it first:"
    pkg_hint "flatpak" "flatpak" | while IFS= read -r line; do error "$line"; done
    exit 1
fi

# Check Bottles Flatpak
if flatpak info com.usebottles.bottles &>/dev/null; then
    BOTTLES_VER=$(flatpak info com.usebottles.bottles 2>/dev/null | awk '/Version/{print $2}')
    info "Bottles Flatpak found (version $BOTTLES_VER)"
else
    error "Bottles Flatpak not found. Install it first:"
    error "  flatpak install flathub com.usebottles.bottles"
    exit 1
fi

# Check gcc
if command -v gcc &>/dev/null; then
    info "gcc found ($(gcc --version | head -1))"
else
    error "gcc not found. Install build tools:"
    pkg_hint "base-devel" "build-essential" | while IFS= read -r line; do error "$line"; done
    exit 1
fi

# Check Vulkan (optional but recommended)
if command -v vulkaninfo &>/dev/null; then
    info "vulkaninfo found"
else
    warn "vulkaninfo not found — install Vulkan tools to verify GPU support:"
    vulkan_pkg_hint | while IFS= read -r line; do warn "$line"; done
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
if $DRY_RUN; then
    dryrun_step "[dry-run] gcc -shared -fPIC -o \"$SHIM_DEST\" \"$SRC\" -ldl"
else
    gcc -shared -fPIC -o "$SHIM_DEST" "$SRC" -ldl
    info "Built and installed: $SHIM_DEST"
fi

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

TARGET_SWAP_GB=16

# Detect filesystem type of root (affects swap creation method on btrfs)
ROOT_FS=$(stat -f -c%T / 2>/dev/null || echo "unknown")
info "Root filesystem type: $ROOT_FS"

# Check current total swap size
CURRENT_SWAP_TOTAL_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
CURRENT_SWAP_TOTAL_GB=$(( CURRENT_SWAP_TOTAL_KB / 1024 / 1024 ))

# Detect if swap is a partition (block device) — do not attempt to resize
SWAP_IS_PARTITION=false
if swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -q "partition"; then
    SWAP_IS_PARTITION=true
fi

if (( CURRENT_SWAP_TOTAL_GB >= TARGET_SWAP_GB )); then
    info "Swap is already ${CURRENT_SWAP_TOTAL_GB} GB — no change needed"

elif $SWAP_IS_PARTITION; then
    warn "Swap is a partition (not a file). Automatic resize skipped to avoid data loss."
    warn "Manually expand your swap partition or add a swapfile to reach ${TARGET_SWAP_GB} GB total."
    MANUAL_STEPS+=("Manually expand swap to ${TARGET_SWAP_GB} GB (swap partition detected — cannot auto-resize)")

elif [[ "$ROOT_FS" == "btrfs" ]]; then
    # btrfs: fallocate produces a corrupt swapfile — must use btrfs mkswapfile
    SWAP_FILE="/swap/swapfile"
    echo "btrfs filesystem detected — using btrfs-native swap creation at $SWAP_FILE"
    echo "(This requires sudo)"

    if ! btrfs subvolume show /swap &>/dev/null 2>&1; then
        run_sudo btrfs subvolume create /swap
        if ! $DRY_RUN; then info "Created btrfs /swap subvolume"; fi
    else
        info "/swap btrfs subvolume already exists"
    fi

    run_sudo btrfs filesystem mkswapfile --size "${TARGET_SWAP_GB}g" --uuid clear "$SWAP_FILE"
    run_sudo swapon "$SWAP_FILE"
    if ! $DRY_RUN; then info "Swap created and enabled at $SWAP_FILE (${TARGET_SWAP_GB} GB)"; fi

    if ! $DRY_RUN && ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap defaults 0 0" | run_sudo tee -a /etc/fstab > /dev/null
        info "Added $SWAP_FILE to /etc/fstab"
    elif $DRY_RUN; then
        dryrun_step "[dry-run] Add '$SWAP_FILE none swap defaults 0 0' to /etc/fstab (if not already present)"
    else
        info "/etc/fstab already has $SWAP_FILE entry"
    fi

else
    # ext4 / xfs / other: standard fallocate path
    SWAP_FILE="/swapfile"
    echo "Current swap: ${CURRENT_SWAP_TOTAL_GB} GB. Expanding to ${TARGET_SWAP_GB} GB..."
    echo "(This requires sudo)"

    run_sudo swapoff "$SWAP_FILE" 2>/dev/null || true
    run_sudo fallocate -l "${TARGET_SWAP_GB}G" "$SWAP_FILE"
    run_sudo chmod 600 "$SWAP_FILE"
    run_sudo mkswap "$SWAP_FILE"
    run_sudo swapon "$SWAP_FILE"
    if ! $DRY_RUN; then info "Swap expanded to ${TARGET_SWAP_GB} GB at $SWAP_FILE"; fi

    if ! $DRY_RUN && ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE swap swap defaults 0 0" | run_sudo tee -a /etc/fstab > /dev/null
        info "Added $SWAP_FILE to /etc/fstab"
    elif $DRY_RUN; then
        dryrun_step "[dry-run] Add '$SWAP_FILE swap swap defaults 0 0' to /etc/fstab (if not already present)"
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
    if $DRY_RUN; then
        dryrun_step "[dry-run] cp \"$DXVK_SRC\" \"$DXVK_CONF_DEST\""
    else
        cp "$DXVK_SRC" "$DXVK_CONF_DEST"
        info "Installed: $DXVK_CONF_DEST"
    fi

    echo ""
    echo "  You must also add this to your Fusion360 bottle's environment variables:"
    echo ""
    echo "    DXVK_CONFIG_FILE = C:\\dxvk.conf"
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
if $DRY_RUN; then
    dryrun_step "[dry-run] cp \"$SCRIPT_DIR/adskidmgr-handler.sh\" \"$HANDLER_DEST\""
    dryrun_step "[dry-run] chmod +x \"$HANDLER_DEST\""
else
    cp "$SCRIPT_DIR/adskidmgr-handler.sh" "$HANDLER_DEST"
    chmod +x "$HANDLER_DEST"
    info "Installed handler: $HANDLER_DEST"
fi

# Try to auto-detect the AdskIdentityManager.exe hash
ADSK_EXE_PATH=""
if [[ -d "$BOTTLE_PATH/drive_c" ]]; then
    ADSK_EXE_PATH=$(find "$BOTTLE_PATH/drive_c" -name "AdskIdentityManager.exe" 2>/dev/null | head -1)
fi

if [[ -n "$ADSK_EXE_PATH" ]]; then
    ADSK_HASH=$(echo "$ADSK_EXE_PATH" | sed 's|.*/production/\([^/]*\)/.*|\1|')
    info "Detected AdskIdentityManager hash: $ADSK_HASH"
    if $DRY_RUN; then
        dryrun_step "[dry-run] sed -i 's|<HASH>|$ADSK_HASH|g' \"$HANDLER_DEST\""
    else
        sed -i "s|<HASH>|$ADSK_HASH|g" "$HANDLER_DEST"
        info "Handler patched with real hash"
    fi
else
    warn "AdskIdentityManager.exe not found yet — handler will auto-detect at runtime"
    warn "Install Fusion 360 first, then re-run setup.sh to bake in the hash."
fi

# Create .desktop file
mkdir -p "$DESKTOP_DIR"
if $DRY_RUN; then
    dryrun_step "[dry-run] Write $DESKTOP_FILE"
else
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
fi

# Register the handler
if $DRY_RUN; then
    dryrun_step "[dry-run] xdg-mime default adskidmgr.desktop x-scheme-handler/adskidmgr"
else
    xdg-mime default adskidmgr.desktop x-scheme-handler/adskidmgr
    info "Registered adskidmgr:// URL scheme handler"
fi

# Update desktop database (not always installed — skip gracefully if missing)
if command -v update-desktop-database &>/dev/null; then
    if $DRY_RUN; then
        dryrun_step "[dry-run] update-desktop-database \"$DESKTOP_DIR\""
    else
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
        info "Desktop database updated"
    fi
else
    warn "update-desktop-database not found — skipping (handler will still work)"
    pkg_hint "desktop-file-utils" "desktop-file-utils" | while IFS= read -r line; do warn "  Install it: $line"; done
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Setup complete — Summary"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
if $DRY_RUN; then
    echo -e "${YELLOW}DRY-RUN: No changes were made. Re-run without --dry-run to apply.${RESET}"
    echo ""
fi

echo -e "${GREEN}Automated steps completed:${RESET}"
echo "  [1] fake_statvfs.so built and placed at: $SHIM_DEST"
echo "  [2] Swap expanded to ${TARGET_SWAP_GB} GB (or already sufficient / skipped)"
echo "  [3] dxvk.conf installed (if bottle exists)"
echo "  [4] adskidmgr:// URL handler registered"
echo ""

if (( ${#MANUAL_STEPS[@]} > 0 )); then
    echo -e "${YELLOW}Manual steps still required:${RESET}"
    i=1
    for step_text in "${MANUAL_STEPS[@]}"; do
        echo "  [$i] $step_text"
        (( i++ ))
    done
    echo ""
fi

echo -e "${BOLD}Bottle settings checklist (in Bottles > Fusion360 > Settings):${RESET}"
echo "  - Runner:          sys-wine-11.0 (or latest Wine stable)"
echo "  - Windows:         Windows 10"
echo "  - DXVK:            Enabled (dxvk-2.x)"
echo "  - Renderer:        gl  (use 'vulkan' only if you have AMD or Nvidia GPU)"
echo "  - Virtual desktop: ENABLED, resolution = your screen resolution"
echo "  - DLL overrides:   Leave empty (do NOT add d3d11 or dxgi)"
echo ""
echo -e "${BOLD}Environment Variables to add in Bottles (copy-paste ready):${RESET}"
echo ""
echo "    LD_PRELOAD       = $SHIM_DEST"
echo "    DXVK_CONFIG_FILE = C:\\dxvk.conf"
echo ""
echo "See README.md for full instructions and troubleshooting."
