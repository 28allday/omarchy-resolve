#!/usr/bin/env python3
"""AAC Fix - make AAC audio work in DaVinci Resolve on Linux.

DaVinci Resolve on Linux (free and Studio) cannot decode AAC audio: MP4/MOV/M4A
clips import fine but play silent. AAC Fix rewraps such files with ffmpeg -
video copied byte-for-byte, AAC decoded once to PCM - into a MOV Resolve reads.

Install (puts the script in Resolve's Scripts menu and a CLI on your PATH):

      python3 resolve_aac_fix.py install          # current user
      python3 resolve_aac_fix.py install --system # all users (/opt/resolve, needs sudo)
      python3 resolve_aac_fix.py uninstall

Inside Resolve: Workspace > Scripts > Utility > AAC Fix
      Scan Media Pool    - list clips whose audio is AAC (or shows no audio)
      Fix Selected       - convert the selected media-pool clips and relink them
      Fix All            - convert + relink every AAC clip found by the scan
      Import for Resolve - pick files/a folder, convert what needs it, import all

Command line (resolve-aac-fix):
      resolve-aac-fix scan  PATH...                        list AAC files under PATH
      resolve-aac-fix fix   FILE... [--out DIR] [--codec pcm_s24le] [--force]
      resolve-aac-fix probe FILE                           show the stream summary

Converted files are written next to the source as <name>_pcm.mov (or into
--out / the folder chosen in the window). Existing conversions newer than the
source are reused. Video is never re-encoded; originals are never touched.
Needs ffmpeg and ffprobe.
"""
import json
import os
import shutil
import subprocess
import sys
import time

MEDIA_EXT = {".mp4", ".m4v", ".mov", ".m4a", ".3gp", ".3g2", ".mkv", ".aac", ".mp4v"}
PCM_CODECS = ["pcm_s24le", "pcm_s16le", "pcm_s32le", "pcm_f32le"]
SUFFIX = "_pcm"

# ----------------------------------------------------------------------------
# media inspection / conversion (no Resolve dependency)
# ----------------------------------------------------------------------------

def have_tools():
    return shutil.which("ffprobe") and shutil.which("ffmpeg")


def probe(path):
    """Return a summary dict or None if ffprobe cannot read the file."""
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    data = json.loads(out.stdout or "{}")
    streams = data.get("streams", [])
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    video = [s for s in streams if s.get("codec_type") == "video" and s.get("disposition", {}).get("attached_pic", 0) == 0]
    return {
        "path": path,
        "container": data.get("format", {}).get("format_name", ""),
        "video_codec": video[0].get("codec_name", "") if video else "",
        "audio": [{"codec": s.get("codec_name", ""), "profile": s.get("profile", ""), "rate": s.get("sample_rate", ""),
                   "channels": s.get("channels", 0), "layout": s.get("channel_layout", "")} for s in audio],
        "has_aac": any(s.get("codec_name") == "aac" for s in audio),
    }


def describe(info):
    a = ", ".join("%s%s %s Hz %sch" % (s["codec"], (" " + s["profile"]) if s["profile"] else "", s["rate"], s["channels"]) for s in info["audio"]) or "no audio"
    return "%s | video %s | audio: %s" % (info["container"].split(",")[0], info["video_codec"] or "-", a)


def output_path(src, out_dir=None):
    base = os.path.splitext(os.path.basename(src))[0]
    d = out_dir or os.path.dirname(os.path.abspath(src))
    return os.path.join(d, base + SUFFIX + ".mov")


def needs_conversion(src, dst, force=False):
    if force or not os.path.exists(dst):
        return True
    return os.path.getmtime(dst) < os.path.getmtime(src)


def convert(src, dst, codec="pcm_s24le", log=print, force=False):
    """ffmpeg rewrap: copy video, decode AAC to PCM. Returns dst or None."""
    if not needs_conversion(src, dst, force):
        log("  reuse   %s (already converted)" % dst)
        return dst
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    tmp = dst + ".part.mov"
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-nostdin",
           "-i", src,
           "-map", "0:v?", "-map", "0:a",
           "-c:v", "copy", "-c:a", codec,
           "-map_metadata", "0",
           tmp]
    log("  ffmpeg  %s -> %s" % (os.path.basename(src), os.path.basename(dst)))
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        log("  FAILED  %s" % (r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "ffmpeg error %d" % r.returncode))
        if os.path.exists(tmp):
            os.unlink(tmp)
        return None
    os.replace(tmp, dst)
    log("  done    %.1fs, %.1f MB" % (time.time() - t0, os.path.getsize(dst) / 1e6))
    return dst


def scan_paths(paths, log=print):
    """Yield (path, info) for AAC files found under the given files/folders."""
    for p in paths:
        p = os.path.expanduser(p)
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in sorted(files):
                    if os.path.splitext(f)[1].lower() in MEDIA_EXT and SUFFIX + ".mov" not in f:
                        info = probe(os.path.join(root, f))
                        if info and info["has_aac"]:
                            yield info["path"], info
        elif os.path.isfile(p):
            info = probe(p)
            if info and info["has_aac"]:
                yield p, info
        else:
            log("  skip    %s (not found)" % p)


# ----------------------------------------------------------------------------
# self install / uninstall
# ----------------------------------------------------------------------------

USER_SCRIPTS = os.path.expanduser("~/.local/share/DaVinciResolve/Fusion/Scripts/Utility")
SYSTEM_SCRIPTS = "/opt/resolve/Fusion/Scripts/Utility"
SCRIPT_NAME = "AAC Fix.py"
CLI_LINK = os.path.expanduser("~/.local/bin/resolve-aac-fix")


def _sudo_needed(path):
    probe = path
    while not os.path.exists(probe):
        probe = os.path.dirname(probe) or "/"
    return not os.access(probe, os.W_OK)


def _run_privileged(argv):
    return subprocess.run((["sudo"] if _sudo_needed(argv[-1]) else []) + argv).returncode == 0


def do_install(system=False):
    if not have_tools():
        print("WARNING: ffmpeg/ffprobe not found on PATH - install ffmpeg (e.g. sudo pacman -S ffmpeg) before using AAC Fix.")
    src = os.path.abspath(__file__)
    dest_dir = SYSTEM_SCRIPTS if system else USER_SCRIPTS
    dest = os.path.join(dest_dir, SCRIPT_NAME)
    ok = _run_privileged(["mkdir", "-p", dest_dir]) and _run_privileged(["cp", src, dest]) and _run_privileged(["chmod", "644", dest])
    if not ok:
        print("failed to install into", dest_dir); return 1
    print("Resolve script installed:", dest)
    os.makedirs(os.path.dirname(CLI_LINK), exist_ok=True)
    cli_target = dest if system else src
    try:
        if os.path.islink(CLI_LINK) or os.path.exists(CLI_LINK):
            os.unlink(CLI_LINK)
        os.symlink(cli_target, CLI_LINK)
        os.chmod(cli_target, 0o755)
        print("CLI installed:", CLI_LINK, "->", cli_target)
        if os.path.dirname(CLI_LINK) not in os.environ.get("PATH", "").split(":"):
            print("  (add ~/.local/bin to your PATH to use the resolve-aac-fix command)")
    except OSError as e:
        print("could not create CLI link:", e)
    print("\nDone. (Re)start DaVinci Resolve, open a project, then: Workspace > Scripts > Utility > AAC Fix")
    return 0


def do_uninstall():
    removed = 0
    for path in (os.path.join(USER_SCRIPTS, SCRIPT_NAME), os.path.join(SYSTEM_SCRIPTS, SCRIPT_NAME), CLI_LINK):
        if os.path.lexists(path):
            if _run_privileged(["rm", "-f", path]):
                print("removed", path); removed += 1
    print("done" if removed else "nothing to remove", "- converted *_pcm.mov files were left untouched")
    return 0

# ----------------------------------------------------------------------------
# command line
# ----------------------------------------------------------------------------

def cli(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "install":
        return do_install(system="--system" in rest)
    if cmd == "uninstall":
        return do_uninstall()
    if not have_tools():
        print("ffmpeg and ffprobe are required (e.g. sudo pacman -S ffmpeg)")
        return 1
    out_dir = None
    codec = "pcm_s24le"
    force = False
    files = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--out":
            out_dir = os.path.abspath(rest[i + 1]); i += 2
        elif a == "--codec":
            codec = rest[i + 1]; i += 2
        elif a == "--force":
            force = True; i += 1
        else:
            files.append(a); i += 1
    if codec not in PCM_CODECS:
        print("codec must be one of", ", ".join(PCM_CODECS)); return 2
    if cmd == "probe":
        for f in files:
            info = probe(f)
            print(f, "->", describe(info) if info else "unreadable")
        return 0
    if cmd == "scan":
        n = 0
        for path, info in scan_paths(files or ["."]):
            print("%s\n    %s" % (path, describe(info))); n += 1
        print("%d AAC file(s)" % n)
        return 0
    if cmd == "fix":
        rc = 0
        for f in files:
            info = probe(f)
            if not info:
                print("unreadable:", f); rc = 1; continue
            if not info["has_aac"]:
                print("no AAC audio, nothing to do:", f); continue
            print(f, "->", describe(info))
            if not convert(f, output_path(f, out_dir), codec, force=force):
                rc = 1
        return rc
    print("unknown command:", cmd)
    return 2


# ----------------------------------------------------------------------------
# inside DaVinci Resolve (globals `resolve`, `fusion`, `bmd` are injected)
# ----------------------------------------------------------------------------

def resolve_ui(resolve, fusion, bmd):
    ui = fusion.UIManager
    disp = bmd.UIDispatcher(ui)
    win_id = "com.github.resolve-aac.fix"
    existing = ui.FindWindow(win_id)
    if existing:
        existing.Show(); existing.Raise(); return

    win = disp.AddWindow({"ID": win_id, "WindowTitle": "AAC Fix", "Geometry": [200, 200, 760, 560]}, ui.VGroup([
        ui.Label({"Text": "<b>AAC Fix</b> - rewrap AAC clips as PCM MOV (video copied, never re-encoded)", "Weight": 0}),
        ui.HGroup({"Weight": 0}, [
            ui.Label({"Text": "PCM format", "Weight": 0}),
            ui.ComboBox({"ID": "codec", "Weight": 0.3}),
            ui.Label({"Text": "Output folder (empty = next to source)", "Weight": 0}),
            ui.LineEdit({"ID": "outdir", "PlaceholderText": "e.g. /home/me/Videos/pcm", "Weight": 0.7}),
        ]),
        ui.HGroup({"Weight": 0}, [
            ui.Button({"ID": "scan", "Text": "Scan Media Pool"}),
            ui.Button({"ID": "fixsel", "Text": "Fix Selected"}),
            ui.Button({"ID": "fixall", "Text": "Fix All"}),
            ui.Button({"ID": "import", "Text": "Import for Resolve..."}),
        ]),
        ui.TextEdit({"ID": "log", "ReadOnly": True, "AcceptRichText": False,
                     "Font": ui.Font({"Family": "monospace", "PixelSize": 12})}),
        ui.HGroup({"Weight": 0}, [ui.Label({"ID": "status", "Text": "Ready."}), ui.Button({"ID": "close", "Text": "Close", "Weight": 0})]),
    ]))
    items = win.GetItems()
    items["codec"].AddItems(PCM_CODECS)
    found = []  # list of (MediaPoolItem, path, info)

    def log(msg):
        items["log"].Append(msg)

    def status(msg):
        items["status"].Text = msg

    def settings():
        codec = PCM_CODECS[items["codec"].CurrentIndex]
        out_dir = items["outdir"].Text.strip() or None
        return codec, out_dir

    def walk(folder):
        for clip in folder.GetClipList() or []:
            yield clip
        for sub in folder.GetSubFolderList() or []:
            yield from walk(sub)

    def clip_candidates(clips):
        for clip in clips:
            path = clip.GetClipProperty("File Path") or ""
            if not path or not os.path.isfile(path):
                continue
            codec = (clip.GetClipProperty("Audio Codec") or "").strip()
            if codec and "aac" not in codec.lower():
                continue
            info = probe(path)
            if info and info["has_aac"]:
                yield clip, path, info, codec

    def do_scan(_ev=None):
        found.clear()
        project = resolve.GetProjectManager().GetCurrentProject()
        if not project:
            log("no project open"); return
        pool = project.GetMediaPool()
        log("Scanning media pool of '%s'..." % project.GetName())
        n = 0
        for clip, path, info, codec in clip_candidates(walk(pool.GetRootFolder())):
            n += 1
            found.append((clip, path, info))
            log("  [%d] %s\n      %s%s" % (n, clip.GetClipProperty("Clip Name"), describe(info),
                                          "" if codec else "   (Resolve reports no audio codec)"))
        log("%d clip(s) with AAC audio." % n)
        status("%d AAC clip(s) found." % n)

    def fix_clips(triples):
        codec, out_dir = settings()
        ok = 0
        for clip, path, info in triples:
            log("Fixing %s" % clip.GetClipProperty("Clip Name"))
            dst = convert(path, output_path(path, out_dir), codec, log=log)
            if not dst:
                continue
            if clip.ReplaceClip(dst):
                log("  relinked media-pool clip to %s" % os.path.basename(dst)); ok += 1
            else:
                log("  ReplaceClip failed - import %s manually" % dst)
        status("%d clip(s) fixed." % ok)

    def do_fix_selected(_ev=None):
        project = resolve.GetProjectManager().GetCurrentProject()
        clips = project.GetMediaPool().GetSelectedClips() if project else []
        if not clips:
            log("Select clips in the media pool first."); return
        triples = [(c, p, i) for c, p, i, _codec in clip_candidates(clips)]
        if not triples:
            log("None of the selected clips has AAC audio."); return
        fix_clips(triples)

    def do_fix_all(_ev=None):
        if not found:
            do_scan()
        if found:
            fix_clips(list(found))

    def do_import(_ev=None):
        chosen = None
        try:
            chosen = fusion.RequestFile("", "", {"FReqB_SeqGather": False, "FReqS_Title": "Pick a media file (its folder is scanned too if you pick a folder)"})
        except Exception:
            chosen = None
        if not chosen:
            chosen = items["outdir"].Text.strip()
            log("No file picker available - type a file or folder in the output field and press Import again.")
            if not chosen:
                return
        project = resolve.GetProjectManager().GetCurrentProject()
        if not project:
            log("no project open"); return
        pool = project.GetMediaPool()
        codec, out_dir = settings()
        targets = [chosen] if os.path.isfile(chosen) else [chosen]
        to_import = []
        for path, info in scan_paths(targets, log=log):
            log("%s -> %s" % (os.path.basename(path), describe(info)))
            dst = convert(path, output_path(path, out_dir), codec, log=log)
            if dst:
                to_import.append(dst)
        if os.path.isfile(chosen) and not to_import:
            to_import = [chosen]  # not AAC: import as-is
        if to_import:
            imported = pool.ImportMedia(to_import) or []
            log("Imported %d clip(s) into the current bin." % len(imported))
            status("Imported %d clip(s)." % len(imported))

    def on_close(_ev=None):
        disp.ExitLoop()

    win.On.scan.Clicked = do_scan
    win.On.fixsel.Clicked = do_fix_selected
    win.On.fixall.Clicked = do_fix_all
    win.On["import"].Clicked = do_import
    win.On.close.Clicked = on_close
    win.On[win_id].Close = on_close

    if not have_tools():
        log("WARNING: ffmpeg/ffprobe not found on PATH - install ffmpeg first.")
    log("Ready. Converted files are written as <name>%s.mov and relinked in place." % SUFFIX)
    win.Show()
    disp.RunLoop()
    win.Hide()


if __name__ == "__main__":
    g = globals()
    if "resolve" in g and "fusion" in g and "bmd" in g:      # launched from Resolve's Scripts menu
        resolve_ui(g["resolve"], g["fusion"], g["bmd"])
    else:
        sys.exit(cli(sys.argv[1:]))
