# omarchy-resolve

Install, repair and diagnose [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve)
on [Omarchy](https://omarchy.com) (Arch Linux + Hyprland, NVIDIA) — from a panel
in the shell, or from the terminal.

Resolve is built for CentOS/RHEL and bundles its own copies of libraries that
Arch has moved on from. Getting it running means replacing some of those and
keeping others, repointing every RPATH in the tree, forcing XWayland, and
working around an ALSA quirk that otherwise makes renders hang with no error.
This does all of that, then keeps the checks around for when something goes
wrong later.

## Requirements

- **OS**: Omarchy 4 (Arch Linux). The panel needs omarchy-shell; the engine
  alone works on any Arch + Hyprland install.
- **GPU**: NVIDIA with working proprietary drivers.
- **Audio**: PipeWire + Wireplumber 0.5+ (Omarchy default) — the audio fix uses
  the SPA-JSON rule format introduced in 0.5.
- **Kernel**: any with `snd-aloop` available (`modinfo snd-aloop`).
- **Disk**: ~10 GB free wherever the ZIP lives, for temporary extraction.
- **The Resolve ZIP**: Blackmagic puts a form in front of the download, so you
  have to fetch it yourself. Save it to `~/Downloads/`.
- **Studio users**: nothing extra to do here — the licence folder permission
  that trips up a manual install is handled. See
  [Studio licensing](#studio-licensing) if you installed Resolve some other way.

## Install

### As a shell plugin

```bash
omarchy plugin add https://github.com/28allday/omarchy-resolve.git --enable
omarchy-shell shell toggle nosignal.davinci-resolve
```

`--enable` adds a bar icon. Leave it off if your bar is full — the panel is
still reachable by the toggle command above, or from a keybinding.

### As a command

```bash
git clone https://github.com/28allday/omarchy-resolve.git
cd omarchy-resolve
bin/omarchy-resolve install
```

Then launch Resolve from your app menu, from the panel, or with
`resolve-nvidia-open`.

## The panel

| Tab | What it is for |
|-----|----------------|
| **Status** | What is installed, which GPU and driver, which ZIP is waiting, whether a newer one has appeared. Launch Resolve from here. |
| **Install** | Pick the ZIP, set the options, install or uninstall. Live progress and a step list while it runs. |
| **Health** | The checks that explain Resolve misbehaving — audio backend, snd-aloop, window rules, opacity, NVENC, log errors, disk space — plus an NVENC test and a codec probe. |
| **Log** | The install log as it happens, or the tail of Resolve's own `ResolveDebug.txt`. |

Things worth knowing:

- **You are asked for your password once.** The work is split into a root half
  and a user half; only the root half is elevated, through `pkexec`, which
  Omarchy renders with its own themed authentication dialog — fingerprint
  included, if you have one enrolled.
- **Closing the panel does not stop the install.** The work belongs to the
  plugin's service, not the window. Reopen it whenever; the bar icon badges
  while it runs.
- **Dry run** rehearses the whole thing — same prompt, same progress — and
  writes nothing.
- **Uninstall never touches your Project Library.**

The panel can open straight to a tab, which makes a reasonable keybinding:

```bash
omarchy-shell nosignal.davinci-resolve show health
omarchy-shell nosignal.davinci-resolve show log
```

## The engine

The panel is a face on `bin/omarchy-resolve`, which stands on its own:

```bash
bin/omarchy-resolve check         # preflight as JSON: ZIP, GPU, versions, space
bin/omarchy-resolve install       # full install (asks for sudo)
bin/omarchy-resolve diagnose      # the Health tab's checks, as JSON
bin/omarchy-resolve probe <file>  # will Resolve read this clip?
bin/omarchy-resolve nvenc-test    # confirm NVENC actually encodes
bin/omarchy-resolve logs 200      # tail ResolveDebug.txt
bin/omarchy-resolve uninstall --phase root   # and --phase user
```

`--dry-run` prints what would happen without doing it. `--machine` adds
progress events for a GUI to parse; that is how the panel follows along.

### Why two phases

`--phase root` does the system work: packages, `/opt/resolve`, RPATH patching,
udev rules, the launcher, `snd-aloop`. `--phase user` does the session work:
Hyprland rules, the PipeWire bridge, your desktop entry, your Resolve config.

They are separate because a GUI has no terminal to answer a `sudo` prompt, so
the root half runs under a single `pkexec` — and under `pkexec`, `$HOME` is
root's. Running the user half elevated would write every one of those files
into `/root`, so the engine refuses to do it.

## What the install actually does

1. **Installs dependencies** one package at a time — `pacman` aborts the whole
   transaction if a single target is missing from the repos, which once took
   the entire install down when Arch dropped `gtk2`.
2. **Extracts** ZIP → `.run` → squashfs payload in a temp dir, cleaned up on
   exit however the run ends.
3. **Swaps glib for the system copies** (`libglib-2.0`, `libgio-2.0`,
   `libgmodule-2.0`) and **keeps the bundled `libc++`/`libc++abi`** — Resolve is
   compiled against a specific C++ ABI and replacing those crashes it on
   startup.
4. **Repoints every RPATH** in the tree at `/opt/resolve`, including the ~200 MB
   Qt WebEngine library, which cannot be skipped for size because it links to
   other Resolve libraries. This is the slow part.
5. **Symlinks legacy `libcrypt.so.1`**, which Arch replaced with `.so.2`.
6. **Installs an XWayland wrapper** at `/usr/local/bin/resolve-nvidia-open`:
   Resolve has no native Wayland support, so it forces `QT_QPA_PLATFORM=xcb`,
   clears the Qt single-instance lockfiles a crash leaves behind, and unsets the
   Kvantum/GTK Qt theme variables Omarchy sets globally (Resolve's bundled Qt
   has neither plugin).
7. **Makes `/opt/resolve/.license` writable** so Resolve Studio can store its
   activation. See [Studio licensing](#studio-licensing).
8. **Switches the audio backend from DeckLink to ALSA** — Resolve's shipped
   default aborts on first launch on any machine without a Blackmagic card.
9. **Sets up `snd-aloop`** and bridges it to your real output. See below.
10. **Installs Hyprland window rules** — only on an Omarchy old enough to need
    them; current versions ship these fixes themselves.

### The `snd-aloop` business

Resolve opens raw ALSA hardware directly (`snd_pcm_open("hw:%d")`) and walks
every card looking for one it can own outright. When PipeWire holds them all,
that walk never settles: the render queue says "in progress", the ETA grows,
the encoder is never invoked, and nothing appears in the log. Traced with
`strace`, it is 14,000+ `SNDRV_CTL_IOCTL_PCM_INFO` and 47,000+
`/dev/snd/controlC*` calls after you press Render.

Loading the kernel's `snd-aloop` module gives Resolve a virtual card PipeWire
does not claim. It settles on that, and the render proceeds.

Two follow-on pieces come with it: a PipeWire loopback module bridging the
loopback's capture side to your default sink (otherwise monitoring is silent),
and a Wireplumber rule keeping the loopback out of the default-sink rotation
(otherwise it promotes itself the moment Resolve plays audio, and the bridge
feeds itself instead of your speakers).

Skip all of it with the panel toggle or `--no-aloop` if you have a dedicated
audio interface Resolve is happy with.

## Configuration

| Option | Panel toggle | Engine flag |
|--------|--------------|-------------|
| Full system upgrade first | Full system upgrade first | `--full-upgrade` |
| Skip the snd-aloop audio fix | Set up snd-aloop (off) | `--no-aloop` |
| Leave Hyprland alone | Manage Hyprland window rules (off) | `--no-hypr-rules` |
| Write the local window rules anyway | — | `--force-hypr-rules` |
| Change nothing, just report | Dry run | `--dry-run` |

### Hybrid GPU laptops (Optimus)

Edit `/usr/local/bin/resolve-nvidia-open` and uncomment:

```bash
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
```

## Troubleshooting

### Studio licensing

**If you are running DaVinci Resolve Studio, `/opt/resolve/.license` must be
writable by the user running Resolve.** The install creates it as root, so on a
manual install it ends up read-only, Resolve Studio cannot store its
activation, and licensing fails — with nothing in the interface explaining
why. It looks like a bad dongle or a rejected key.

This installer sets the permission for you. If you installed Resolve some other
way, or you are fixing an existing install:

```bash
sudo chmod 7777 /opt/resolve/.license
```

The Health tab checks this, and says so plainly if the folder is missing or
not writable. The free edition never writes here, so the permission is
harmless either way.

### A clip imports with picture but no sound

**The Linux build of Resolve has no AAC decoder.** An ordinary camera or phone
`.mp4`/`.mov` carries AAC, so it lands on the timeline silent with nothing in
the UI to explain it. Remux the audio to PCM — fast, and the picture is not
re-encoded:

```bash
ffmpeg -i input.mp4 -c:v copy -c:a pcm_s16le output.mov
```

Two neighbouring facts, since they get confused:

- **H.264 and H.265 decode need Resolve Studio on Linux.** The free edition
  cannot read them.
- **ProRes and ProRes RAW are supported.** Resolve ships its own decoder
  (`/opt/resolve/libs/libProResRAW.so`) and loads a bundled conversion plugin at
  startup. The `ProRes RAW SDK raw conversion plug-in loading error(s): unable
  to open default plug-in directory /usr/local/lib/proresraw/plugins` line in
  the log is **harmless** — that directory is for optional third-party plugins
  and its absence is the normal state.

`bin/omarchy-resolve probe <file>`, or the Health tab, tells you which codecs a
clip uses and whether Resolve will read them.

### The render queue runs forever and produces nothing

Check `snd-aloop` is loaded:

```bash
lsmod | grep snd_aloop
sudo modprobe snd-aloop                                    # if absent
echo 'snd-aloop' | sudo tee /etc/modules-load.d/snd-aloop.conf
```

If it is loaded and renders still hang, check the clip with
`bin/omarchy-resolve probe`.

### The default sink keeps flipping to "Loopback"

The Wireplumber exclusion rule is missing or not in effect:

```bash
cat ~/.config/wireplumber/wireplumber.conf.d/51-resolve-aloop-no-default.conf
systemctl --user restart wireplumber pipewire pipewire-pulse
```

### Resolve will not start

```bash
setsid /usr/local/bin/resolve-nvidia-open >/tmp/resolve-stderr.log 2>&1 &
bin/omarchy-resolve logs 200
```

`Cannot open display` means the XWayland wrapper is being bypassed — launch via
`resolve-nvidia-open`, not `/opt/resolve/bin/resolve`. "Single instance already
running" after a crash is a stale Qt lockfile; the wrapper clears those, so
launching through it again is the fix.

### The bar covers Resolve's menu bar, or a dialog traps the pointer

Current Omarchy fixes both itself. On an older one, the engine installs the
rules; run `bin/omarchy-resolve diagnose` to see which copy is in force.

### Missing library errors

Usually a partial install. Re-run the install — it is safe to repeat, and the
RPATH pass skips files already correct.

## What gets installed

| Path | What |
|------|------|
| `/opt/resolve` | The application |
| `/opt/resolve/.omarchy-resolve.json` | Which version, from which ZIP, when |
| `/opt/resolve/.license` | Studio activation — made writable, or Studio licensing fails |
| `/usr/local/bin/resolve-nvidia-open` | XWayland wrapper (the real launcher) |
| `/usr/bin/davinci-resolve` | Convenience shim to the wrapper |
| `/usr/share/applications/*.desktop`, `/usr/share/icons/hicolor/**` | Menu entries and icons |
| `/usr/lib/udev/rules.d/99-*.rules` | Blackmagic panels, keyboards, capture cards |
| `/etc/modules-load.d/snd-aloop.conf` | Loads the virtual audio card at boot |
| `/etc/pki/tls` | Symlink to `/etc/ssl`, for Resolve's CentOS-path certificate lookup |
| `~/.local/share/applications/davinci-resolve-wrapper.desktop` | User entry, outranks the system one |
| `~/.config/pipewire/pipewire.conf.d/50-resolve-aloop-bridge.conf` | Monitor audio bridge |
| `~/.config/wireplumber/wireplumber.conf.d/51-resolve-aloop-no-default.conf` | Keeps the loopback out of the default-sink rotation |
| `~/.config/hypr/davinci-resolve.lua` | Window rules, only on an Omarchy that needs them |

Your projects and settings live in `~/.local/share/DaVinciResolve` and are never
touched by an install, a reinstall, or an uninstall.

## Updating Resolve

Blackmagic put a form in front of their downloads, so nothing can fetch a new
release for you. Once the ZIP is in `~/Downloads/`, though, the rest is handled:

1. Download the new version to `~/Downloads/`.
2. Open the panel. The Status tab compares the ZIP against what you are running
   and says **"Update waiting: 21.0 is newer than 21.0b2"**.
3. Press **Reinstall** (or pick a specific ZIP first on the Install tab).

Or from the terminal — the newest ZIP is picked automatically:

```bash
bin/omarchy-resolve install
```

An update is a full reinstall: `/opt/resolve` is replaced wholesale, which is
how Blackmagic ship it anyway. What survives untouched:

- `~/.local/share/DaVinciResolve` — your Project Library, settings, layouts,
  keyboard mappings and the LUTs you have imported into your user folder.
- Your Hyprland rules, PipeWire bridge and desktop entries, which are rewritten
  identically rather than lost.

What does not survive, because it lives inside `/opt/resolve`: anything you
dropped into the install tree yourself — OFX plugins installed to
`/opt/resolve/OFX`, custom LUTs placed under `/opt/resolve/LUT`, Fusion
templates. Copy those out first if you have any.

### How "newer" is decided

Every install through this tool records what it installed in
`/opt/resolve/.omarchy-resolve.json`, and the ZIP filename carries the version,
so the two are compared directly. Beta ordering is handled: `21.0b2` is newer
than `21.0b1`, and `21.0` is newer than either.

Two honest limits:

- **An install that predates this tool has no record**, so there is nothing
  exact to compare against. Resolve's own docs give only the major version
  ("21"), which is enough to spot a whole new major release but not a point
  release — so within a major it says nothing rather than guessing. The first
  install through the panel fixes this permanently.
- **The ZIP offered is the newest by modification time**, matching what the
  installer has always picked. If that turns out to be an older build than the
  one you are running, it says so and calls it a downgrade instead of an
  update. The Install tab lists every ZIP you have, so you can pick another.

## Uninstalling

Press **Uninstall** on the panel's Install tab, or:

```bash
sudo bin/omarchy-resolve uninstall --phase root
bin/omarchy-resolve uninstall --phase user
```

Add `--purge-data` to the user phase to delete `~/.local/share/DaVinciResolve`
as well, including the Project Library. That is not reversible.

To remove the plugin itself: `omarchy plugin remove nosignal.davinci-resolve`.

## Related

The original terminal-only installer this grew out of lives at
[DaVinci-Resolve-Omarchy](https://github.com/28allday/DaVinci-Resolve-Omarchy).
There is an AMD sibling for RDNA 2/3/4 cards, which has its own ROCm pinning and
`DRI_PRIME` handling.

DaVinci Resolve is a product of Blackmagic Design. This project is not
affiliated with or endorsed by them.

## License

MIT
