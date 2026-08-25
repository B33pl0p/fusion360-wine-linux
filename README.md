# Fusion 360 on Linux (Wine + Bottles)

Getting Fusion 360 to actually run on Linux takes more than just "install Wine and go". There are four distinct failure modes, each with a non-obvious fix. This repo documents all of them and includes a setup script that handles most of the work automatically.

Works on Ubuntu/Debian and Arch Linux. The script detects your distro, filesystem, and GPU automatically.

**Tested on:**
- Zorin OS 17 / Ubuntu 24.04 — Intel Iris Plus 645 (Coffee Lake), Wayland, 8 GB RAM
- Arch Linux — same hardware

---

## Quick start

```bash
git clone https://github.com/biplop/fusion360-wine-linux.git
cd fusion360-wine-linux
chmod +x setup.sh
./setup.sh
```

Follow the manual steps printed at the end to finish configuring the Bottles bottle.

If you want to see what it'll do before running anything with sudo:

```bash
./setup.sh --dry-run
```

---

## Prerequisites

### Flatpak + Bottles

Bottles needs to be the **Flatpak** version specifically — the OAuth fix (Fix 4) relies on the Flatpak sandbox path. A native install will need the handler script adapted.

**Ubuntu / Debian / Zorin:**
```bash
sudo apt install flatpak
flatpak install flathub com.usebottles.bottles
```

**Arch:**
```bash
sudo pacman -S --needed flatpak
flatpak install flathub com.usebottles.bottles
```

### Build tools

Needed to compile the disk space shim (Fix 1).

**Ubuntu / Debian:**
```bash
sudo apt install build-essential
```

**Arch:**
```bash
sudo pacman -S --needed base-devel
```

### Vulkan drivers

Run `vulkaninfo --summary` to check. If it errors, install drivers for your GPU:

**Ubuntu / Debian — Intel:**
```bash
sudo apt install vulkan-tools intel-media-va-driver libvulkan1 mesa-vulkan-drivers
```

**Arch — Intel:**
```bash
sudo pacman -S --needed vulkan-tools vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader
```

**Arch — AMD:**
```bash
sudo pacman -S --needed vulkan-tools vulkan-radeon lib32-vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader
```

**Arch — Nvidia:**
```bash
sudo pacman -S --needed vulkan-tools nvidia-utils lib32-nvidia-utils vulkan-icd-loader lib32-vulkan-icd-loader
```

`setup.sh` auto-detects your GPU and prints the right command if something's missing.

---

## Create the Fusion360 bottle

Open Bottles, create a new bottle, name it exactly `Fusion360`, and use these settings:

| Setting | Value |
|---|---|
| Environment | Application (custom) |
| Runner | `sys-wine-11.0` (or latest stable) |
| Windows version | Windows 10 |
| DXVK | Enabled |
| Renderer | `gl` (Intel iGPU) or `vulkan` (AMD/Nvidia) |
| Virtual Desktop | **Enabled** |
| Virtual Desktop Resolution | Your screen resolution |
| DLL Overrides | Leave empty |

**Virtual Desktop:** On Wayland, Wine doesn't integrate cleanly with the compositor without this. Input and display both break without it.

**Renderer — why `gl` for Intel?** Intel's ANV Vulkan driver (Iris Plus / Coffee Lake) has a bug with `VK_EXT_graphics_pipeline_library` that causes a GPU hang the moment Fusion's 3D viewport renders anything. The `gl` renderer sidesteps this entirely — DXVK is still active, you're just changing which backend it uses. AMD (RADV) and Nvidia don't have this problem and can use `vulkan`.

---

## The four fixes

### Fix 1 — "Not enough disk space"

**What happens:** The installer or launcher quits immediately saying there's no disk space, even with hundreds of GB free.

**Why:** Fusion 360 requires at least ~50 GB free before it'll proceed. The check goes through Wine's `ntdll.so`, which calls `fstatfs()` directly — not `statvfs()`. The usual Wine workarounds (fake registry keys, drive size settings) don't intercept this call.

**Fix:** An `LD_PRELOAD` shim that intercepts `fstatfs()` and `statfs()` and returns inflated values. It gets loaded before any Wine code, so it catches the check.

```bash
gcc -shared -fPIC -o fake_statvfs.so fake_statvfs.c -ldl
```

The `.so` goes anywhere on the host filesystem (not inside `drive_c`). `setup.sh` builds it and puts it here:

```
~/.var/app/com.usebottles.bottles/data/bottles/bottles/fake_statvfs.so
```

Then in Bottles → Fusion360 → Settings → Environment Variables:

```
LD_PRELOAD = /home/YOUR_USERNAME/.var/app/com.usebottles.bottles/data/bottles/bottles/fake_statvfs.so
```

---

### Fix 2 — App dies silently after ~60 seconds

**What happens:** Fusion 360 starts fine, login screen appears, then roughly a minute later the whole thing just disappears. No crash dialog. `journalctl -b | grep -i oom` or `dmesg | grep -i kill` will show `systemd-oomd` killed it.

**Why:** Fusion's home dashboard runs a Chromium-based web view. Combined with Wine overhead and the geometry kernel, peak memory usage easily clears 8 GB. `systemd-oomd` watches memory pressure and kills the most expensive cgroup when things get tight. Without enough swap headroom, it fires within the first minute.

**Fix:** 16 GB of swap gives enough breathing room.

**Ubuntu / Debian (ext4):**
```bash
sudo swapoff /swapfile
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
```

**Arch — btrfs root:**

> Don't use `fallocate` on btrfs — it creates a corrupt swapfile. Use this instead:

```bash
sudo btrfs subvolume create /swap
sudo btrfs filesystem mkswapfile --size 16g --uuid clear /swap/swapfile
sudo swapon /swap/swapfile
echo '/swap/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab
```

**Arch — ext4 root:**
```bash
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
```

`setup.sh` detects your filesystem type and picks the right method. It also checks if swap is already large enough (skips if so) and won't try to resize a swap partition.

---

### Fix 3 — Crash when opening a design document

**What happens:** Everything works — Fusion loads, you log in, the home dashboard comes up — but the moment you open or create a design, it crashes. The Bottles log cuts off at `CreateNewDocTask END`, usually followed by a GPU hang or device-lost error.

**Why:** DXVK 2.x uses `VK_EXT_graphics_pipeline_library` for async pipeline compilation. Intel's ANV driver advertises support for this extension but has a bug that causes a GPU hang when the first complex D3D11 scene renders. Fusion's 3D viewport is the first such scene, so it crashes every time.

Using `d3d11=builtin` (wined3d) doesn't help — on Wayland/XWayland, wined3d renders a completely blank viewport. The app runs but you can't see anything.

**Fix:** A `dxvk.conf` that disables the broken extension:

```ini
[dxvk]
dxvk.enableGraphicsPipelineLibrary = Disabled
dxvk.enableAsync = False
```

Place it inside `drive_c`:
```
~/.var/app/com.usebottles.bottles/data/bottles/bottles/Fusion360/drive_c/dxvk.conf
```

Then in the bottle's environment variables:
```
DXVK_CONFIG_FILE = C:\dxvk.conf
```

`C:\` is just `drive_c` as seen by Wine. `setup.sh` copies the file automatically.

---

### Fix 4 — Login completes in browser but Fusion never signs in

**What happens:** The Autodesk sign-in browser window opens fine, you enter your credentials, it completes — but Fusion 360 just sits there waiting, never receiving the auth token.

**Why:** Autodesk's OAuth flow redirects the browser to `adskidmgr://...` after login. The browser asks the OS to open that URL with a registered handler, which is supposed to be `AdskIdentityManager.exe` running inside Wine. On Linux, `adskidmgr://` isn't registered as a URL scheme, so the callback just gets dropped.

**Fix:** Register a shell script as the handler for `x-scheme-handler/adskidmgr`. When the browser fires the callback, the OS calls the script with the URL as an argument, and the script passes it to `AdskIdentityManager.exe` via `flatpak run --command=/app/bin/wine`.

The `--command` form is important. Running `flatpak run com.usebottles.bottles` directly starts a new Bottles session with its own isolated wineserver — that new instance can't talk to the Fusion 360 process that's already running. `--command=/app/bin/wine` invokes Wine directly and shares the existing wineserver at `/run/user/1000/.flatpak/com.usebottles.bottles/tmp/`.

`AdskIdentityManager.exe` is buried under a hash that changes with Autodesk updates:
```
C:\users\USERNAME\AppData\Local\Autodesk\webdeploy\production\<HASH>\Autodesk Identity Manager\AdskIdentityManager.exe
```

The handler script auto-detects this at runtime with `find`, so it keeps working after updates.

`setup.sh` installs everything automatically:
```bash
cp adskidmgr-handler.sh ~/adskidmgr-handler.sh
chmod +x ~/adskidmgr-handler.sh
# creates ~/.local/share/applications/adskidmgr.desktop
# runs xdg-mime default adskidmgr.desktop x-scheme-handler/adskidmgr
```

---

## bottle.yml reference

What the relevant parts of your bottle config should look like after all fixes:

```yaml
Runner: sys-wine-11.0
DXVK: dxvk-2.7.1-19-b0bb947
Parameters:
    dxvk: true
    renderer: gl
    virtual_desktop: true
    virtual_desktop_res: 2560x1600
DLL_Overrides: {}
Environment_Variables:
    DXVK_CONFIG_FILE: 'C:\dxvk.conf'
    LD_PRELOAD: /home/YOUR_USERNAME/.var/app/com.usebottles.bottles/data/bottles/bottles/fake_statvfs.so
Windows: win10
```

---

## Full installation walkthrough

1. Install prerequisites (Flatpak, Bottles, build tools, Vulkan drivers)
2. Run `./setup.sh` — handles fixes 1–4 automatically
3. Create the `Fusion360` bottle in Bottles with the settings above
4. In Bottles → Fusion360 → Settings → Environment Variables, add:
   - `LD_PRELOAD` → path printed by setup.sh
   - `DXVK_CONFIG_FILE` → `C:\dxvk.conf`
5. Enable Virtual Desktop in the bottle's display settings
6. Download the Fusion 360 installer from Autodesk, run it via Bottles → Run Executable
7. Sign in — complete the browser login normally; the URL handler routes the callback back
8. Open a design — viewport should render without crashing

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| "Not enough disk space" immediately | fstatfs check failing | Fix 1 — verify LD_PRELOAD is set in bottle env vars |
| App killed ~60–90s in, no crash dialog | systemd-oomd OOM kill | Fix 2 — expand swap to 16 GB |
| Crash on opening/creating a document | DXVK `VK_EXT_graphics_pipeline_library` bug on Intel ANV | Fix 3 — dxvk.conf + DXVK_CONFIG_FILE env var |
| Browser login completes but app never authenticates | Missing `adskidmgr://` handler | Fix 4 — re-run setup.sh |
| 3D viewport blank, rest of app works | wined3d active instead of DXVK | Remove `d3d11=builtin` from DLL overrides |
| Virtual desktop window gets no keyboard/mouse input | Virtual desktop not enabled | Enable in Bottles → Display settings |
| `flatpak run` in handler fails | Handler using wrong invocation | Make sure handler uses `--command=/app/bin/wine` form |
| Handler can't find AdskIdentityManager.exe | Fusion 360 not installed yet | Install Fusion 360 first, then re-run setup.sh |

---

## Files

| File | What it does |
|---|---|
| `setup.sh` | Main setup script — run this |
| `fake_statvfs.c` | Source for the LD_PRELOAD disk space shim |
| `dxvk.conf` | DXVK config that disables the broken pipeline extension |
| `adskidmgr-handler.sh` | OAuth callback URL handler |

---

## Contributing

If this works for you on hardware not listed here — different GPU, distro, RAM config — open an issue or PR with details.

Tested:
- Intel Iris Plus 645 (Coffee Lake) — Ubuntu 24.04, Zorin OS 17, Arch Linux — Wayland

Not yet tested:
- AMD GPU (RADV) — script generates correct pacman command; dxvk.conf probably not needed
- Nvidia proprietary driver
- Arch with btrfs root — swap logic is in there but unverified; please report
- Bottles native package (non-Flatpak) — Fix 4 handler paths will need changes
- X11 session — virtual desktop may be unnecessary
- ARM

---

## License

MIT. Autodesk Fusion 360 is proprietary software and subject to Autodesk's own terms.
