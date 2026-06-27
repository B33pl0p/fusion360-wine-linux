# Fusion 360 on Linux via Wine/Bottles

Get Autodesk Fusion 360 running on Linux using [Bottles](https://usebottles.com/) (Flatpak) and Wine. This guide documents four specific bugs that prevent a working install and their confirmed fixes, along with an automated setup script.

**Tested configuration:**
- OS: Zorin OS 17 / Ubuntu 24.04 (Wayland session)
- GPU: Intel Iris Plus Graphics 645 (Coffee Lake, i5-8259U class)
- RAM: 8 GB
- Bottles: Flatpak (`com.usebottles.bottles`), latest stable
- Wine: 11.0 (via Bottles `sys-wine-11.0`)
- DXVK: 2.7.1

---

## Quick start

```bash
git clone https://github.com/mxioi/fusion360-wine-linux.git
cd fusion360-wine-linux
chmod +x setup.sh
./setup.sh
```

Then follow the manual steps printed at the end (Bottles bottle configuration).

---

## Prerequisites

### 1. Install Bottles

```bash
flatpak install flathub com.usebottles.bottles
```

Bottles must be installed as a **Flatpak** — the handler script in Fix 4 depends on the Flatpak sandbox path. A native package install will require adapting the `flatpak run` commands.

### 2. Install build tools (for the disk space shim)

```bash
sudo apt install build-essential
```

### 3. Check Vulkan support

```bash
sudo apt install vulkan-tools
vulkaninfo --summary
```

Your GPU needs a working Vulkan driver. For Intel iGPUs on Ubuntu/Zorin:

```bash
sudo apt install intel-media-va-driver libvulkan1 mesa-vulkan-drivers
```

---

## Create the Fusion360 bottle

Open Bottles and create a new bottle with these exact settings:

| Setting | Value |
|---|---|
| Name | `Fusion360` |
| Environment | Application (custom) |
| Runner | `sys-wine-11.0` (or latest stable Wine) |
| Windows version | Windows 10 |
| DXVK | Enabled |
| Renderer | `gl` — **not** Vulkan |
| Virtual Desktop | **Enabled** |
| Virtual Desktop Resolution | Your screen resolution (e.g. `2560x1600`) |
| DLL Overrides | **Leave empty** |

> **Why virtual desktop?** On Wayland, Wine windows don't integrate cleanly with the compositor unless you wrap them in a virtual desktop (an XWayland window). Without this, Fusion 360 may not receive input or display properly.

> **Why `gl` renderer and not `vulkan`?** With Vulkan renderer selected in Bottles, DXVK translates D3D → Vulkan directly but some configurations on XWayland produce rendering artifacts. `gl` uses DXVK's OpenGL fallback path which is more stable on this hardware. DXVK is still active; you're changing the Bottles wrapper layer, not disabling DXVK.

---

## The four fixes

### Fix 1 — Disk space pre-check (`fake_statvfs` shim)

**Symptom:** Fusion 360 installer or launcher immediately exits with "Not enough disk space" even though you have plenty of space. This happens even when the drive has hundreds of GB free.

**Root cause:** Fusion 360 checks for at least ~50 GB of free disk space before proceeding. The check goes through Wine's `ntdll.so`, which calls the Linux `fstatfs()` syscall to query disk space — not `statvfs()` as you might expect. Standard Wine workarounds (fake `DISKFREEBYTES` registry keys, drive size settings) operate at a different layer and do not intercept this call.

**Fix:** Build a small shared library that intercepts `fstatfs()` and `statfs()` via `LD_PRELOAD` and substitutes artificially large block counts. This shim is loaded into the Wine process before any Wine code runs, so the spoofed values reach `ntdll.so`'s disk check.

```bash
gcc -shared -fPIC -o fake_statvfs.so fake_statvfs.c -ldl
```

Place the `.so` anywhere on the host filesystem (not inside `drive_c`). The recommended location is alongside your bottle data:

```
~/.var/app/com.usebottles.bottles/data/bottles/bottles/fake_statvfs.so
```

In Bottles, open your Fusion360 bottle → **Settings** → **Environment Variables** → Add:

```
LD_PRELOAD = /home/YOUR_USERNAME/.var/app/com.usebottles.bottles/data/bottles/bottles/fake_statvfs.so
```

The `setup.sh` script compiles and places this file automatically.

---

### Fix 2 — OOM kill (expand swap)

**Symptom:** Fusion 360 appears to load (splash screen, login prompt), but approximately 60–90 seconds after launch the application is killed without warning. No crash dialog appears. Checking `journalctl -b | grep -i oom` or `dmesg | grep -i kill` shows `systemd-oomd` terminated a process.

**Root cause:** Fusion 360's "home dashboard" is a Chromium-based web view. Between Wine overhead, the Chromium renderer, and Fusion's geometry kernel, peak RSS easily exceeds 8 GB on a machine with 8 GB of RAM. Linux's `systemd-oomd` monitors memory pressure and kills the most expensive cgroup when the system approaches exhaustion. With no swap space (or small swap), this happens within the first minute of loading.

**Fix:** Expand the system swapfile to 16 GB so there is headroom for memory spikes.

```bash
sudo swapoff /swapfile
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Verify `/etc/fstab` contains:
```
/swapfile swap swap defaults 0 0
```

If you don't have a swapfile at all, create one:
```bash
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
```

The `setup.sh` script handles this automatically.

---

### Fix 3 — DXVK crash on Intel ANV (`VK_EXT_graphics_pipeline_library`)

**Symptom:** Fusion 360 loads, login succeeds, the home dashboard appears — but as soon as you open or create a design document, the application crashes or freezes. The Bottles log shows activity stopping at a line containing `CreateNewDocTask END`, often followed by a Vulkan device-lost or GPU hang error.

**Root cause:** DXVK 2.x introduced support for `VK_EXT_graphics_pipeline_library`, a Vulkan extension that allows async pipeline compilation (pipelines are built in background threads while rendering proceeds with stubs). This reduces shader compilation stutter significantly.

Intel's ANV Vulkan driver (used on Iris Plus / UHD 6xx / Coffee Lake iGPUs) advertises support for `VK_EXT_graphics_pipeline_library` but has bugs in that code path that cause a GPU hang when the first complex D3D11 scene is rendered. Fusion 360's 3D viewport is the first such scene, so it reliably crashes on document open.

**Why not use wined3d instead?** Setting `d3d11=builtin` in DLL overrides disables DXVK and uses Wine's built-in D3D11 implementation (wined3d). On Wayland / XWayland, wined3d produces a completely blank 3D viewport — the application loads and responds to interaction but renders nothing in the design area. This is not a usable workaround.

**Fix:** Create a `dxvk.conf` file that disables the broken extension, placed inside `drive_c`:

```
~/.var/app/com.usebottles.bottles/data/bottles/bottles/Fusion360/drive_c/dxvk.conf
```

```ini
[dxvk]
dxvk.enableGraphicsPipelineLibrary = Disabled
dxvk.enableAsync = False
```

Then add to your bottle's environment variables in Bottles:

```
DXVK_CONFIG_FILE = C:\dxvk.conf
```

The `C:\` path is a Windows path inside Wine — `drive_c` maps to `C:\`. The `setup.sh` script copies the file automatically.

---

### Fix 4 — OAuth login (`adskidmgr://` URL scheme)

**Symptom:** When you click "Sign In", a browser window opens and you can enter your Autodesk credentials. After submitting, the browser shows a page saying "No apps installed to open this link" or the login flow just hangs, and Fusion 360 never receives the authentication token.

**Root cause:** Autodesk's sign-in uses OAuth 2.0 with a custom URI scheme callback. After the browser-based login completes, Autodesk's server redirects to a URL like `adskidmgr://xxxxxxx`. The browser asks the OS to open this URL with a registered handler, and the OS passes it to `AdskIdentityManager.exe` running inside Wine. On Linux, `adskidmgr://` is not registered as a known URL scheme, so the OS has no handler and the callback is dropped.

**Fix:** Register a shell script as the system handler for `x-scheme-handler/adskidmgr`. When the browser triggers the callback URL, the OS invokes the script with the URL as an argument. The script uses `flatpak run --command=/app/bin/wine` to pass the URL to `AdskIdentityManager.exe` inside the bottle.

The `--command=/app/bin/wine` form is critical. Using plain `flatpak run com.usebottles.bottles` would start a new Bottles session with its own isolated wineserver, which cannot communicate with the Fusion 360 process already running. The `--command` form invokes Wine directly and shares the existing wineserver via the socket at `/run/user/1000/.flatpak/com.usebottles.bottles/tmp/`.

`AdskIdentityManager.exe` lives at a path that includes a hex hash that changes between Autodesk update cycles:

```
C:\users\USERNAME\AppData\Local\Autodesk\webdeploy\production\<HASH>\Autodesk Identity Manager\AdskIdentityManager.exe
```

The `adskidmgr-handler.sh` script auto-detects this hash at runtime using `find`, so it survives updates.

**Installation:**

```bash
# The setup.sh script does all of this automatically:

cp adskidmgr-handler.sh ~/adskidmgr-handler.sh
chmod +x ~/adskidmgr-handler.sh

mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/adskidmgr.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Autodesk Identity Manager
Exec=/home/YOUR_USERNAME/adskidmgr-handler.sh %u
MimeType=x-scheme-handler/adskidmgr;
NoDisplay=true
Terminal=false
EOF

xdg-mime default adskidmgr.desktop x-scheme-handler/adskidmgr
update-desktop-database ~/.local/share/applications
```

---

## Bottle configuration reference (`bottle.yml` key fields)

After applying all fixes, your bottle's relevant configuration should look like:

```yaml
Runner: sys-wine-11.0
DXVK: dxvk-2.7.1-19-b0bb947   # or latest available
Parameters:
    dxvk: true
    renderer: gl
    virtual_desktop: true
    virtual_desktop_res: 2560x1600   # match your display resolution
DLL_Overrides: {}                    # leave empty — no d3d11/dxgi overrides
Environment_Variables:
    DXVK_CONFIG_FILE: 'C:\dxvk.conf'
    LD_PRELOAD: /home/YOUR_USERNAME/.var/app/com.usebottles.bottles/data/bottles/bottles/fake_statvfs.so
Windows: win10
```

---

## Installation steps (full walkthrough)

1. **Install prerequisites** — Bottles Flatpak, `build-essential`, Vulkan drivers (see Prerequisites above)
2. **Run `setup.sh`** — compiles fake_statvfs.so, expands swap, creates dxvk.conf, registers URL handler
3. **Create the Fusion360 bottle** in Bottles with the settings in the table above
4. **Set environment variables** in Bottles (Fusion360 bottle → Settings → Environment Variables):
   - `LD_PRELOAD` → path to `fake_statvfs.so` (printed by setup.sh)
   - `DXVK_CONFIG_FILE` → `C:\dxvk.conf`
5. **Enable Virtual Desktop** in Bottles (Fusion360 bottle → Settings → Display)
6. **Download and run the Fusion 360 installer** from inside the bottle:
   - In Bottles, click "Run Executable" and select the Fusion 360 installer EXE
   - Or download `Fusion360installer.exe` from Autodesk and run it via Bottles
7. **Sign in** — when the Autodesk login browser window opens, complete login normally; the URL handler will route the callback back to Wine
8. **Open a design** — the 3D viewport should render without crashing

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| "Not enough disk space" on install/launch | fstatfs check failing | Fix 1 (fake_statvfs shim) — check LD_PRELOAD is set in Bottles env vars |
| App killed ~60–90s after launch, no crash dialog | systemd-oomd OOM kill | Fix 2 — expand swap to 16 GB |
| Crash on opening/creating a design document | DXVK `VK_EXT_graphics_pipeline_library` bug on Intel ANV | Fix 3 — install dxvk.conf, set DXVK_CONFIG_FILE env var |
| Login browser opens but app never receives auth token | Missing `adskidmgr://` URL scheme handler | Fix 4 — run setup.sh to register handler |
| 3D viewport is completely blank, rest of app works | wined3d active instead of DXVK | Do NOT set `d3d11=builtin` in DLL overrides; remove it if present |
| Virtual desktop window appears but gets no input | Virtual desktop mode not enabled | Enable Virtual Desktop in Bottles display settings |
| `flatpak run` in handler fails / wrong wineserver | Handler uses `flatpak run com.usebottles.bottles` directly | Ensure handler uses `--command=/app/bin/wine` form |
| adskidmgr handler can't find AdskIdentityManager.exe | Hash-based path not detected | Install Fusion 360 first, then re-run setup.sh |

---

## File listing

| File | Purpose |
|---|---|
| `setup.sh` | Automated setup script — run this first |
| `fake_statvfs.c` | Source for the disk space shim (Fix 1) |
| `dxvk.conf` | DXVK pipeline library disable config (Fix 3) |
| `adskidmgr-handler.sh` | OAuth URL scheme handler script (Fix 4) |

---

## Contributing

If you've confirmed this works on different hardware (AMD GPU, Nvidia, different Coffee Lake variants, ARM), please open an issue or PR with your configuration details.

Known untested configurations:
- AMD GPU with RADV driver
- Nvidia GPU with proprietary driver
- Bottles installed as native package (non-Flatpak) — Fix 4 will need path changes
- X11 session (non-Wayland) — virtual desktop may not be needed

---

## License

MIT — do whatever you want with this. Autodesk Fusion 360 itself is proprietary software subject to Autodesk's terms.
