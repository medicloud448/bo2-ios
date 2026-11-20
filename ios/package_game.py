"""Build a personal all-mode IPA on a Mac with Xcode and XcodeGen.

By default the app is signed with your Xcode team and carries the game files.

--unsigned leaves signing to a tool such as SideStore or a signing service.

--shell-only leaves the game files out; they are then installed from the app.

The output volume needs space for the unpacked game, the app and the final ZIP.
"""

import argparse
from contextlib import nullcontext
from ipaddress import IPv4Address
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from zipfile import ZipFile, ZIP_DEFLATED

from runtime_catalog import write_catalog

ALL_MODES = ("sps", "mps", "zms")
EXECUTABLES = {"sps": "t6sp.exe", "mps": "t6mp.exe", "zms": "t6zm.exe"}

def command(*args):
    subprocess.run([str(a) for a in args], check=True)

def unpack_game(game, app, modes):
    """Unpack the game archive into <app>/Game as a flat, browsable tree.

    The archive is often zipped from a folder, so every member can sit under one
    wrapper directory ("Game/", "Call of Duty Black Ops II/"). The runtime looks
    for t6sp.exe and zone/all/ directly inside <app>/Game, so that wrapper has to
    be stripped or the game starts with no files at all.
    """
    target = app / "Game"
    target.mkdir(parents=True, exist_ok=True)

    names = [n for n in game.namelist() if n and not n.endswith("/")]
    tops = {Path(n).parts[0] for n in names if Path(n).parts}
    prefix = ""
    if len(tops) == 1:
        top = tops.pop()
        # Only strip when the top component is a directory, never a bare file.
        if all(Path(n).parts[0] == top for n in names) and top not in names:
            prefix = top + "/"

    for name in game.namelist():
        if not name.startswith(prefix):
            continue
        relative = name[len(prefix):]
        if not relative:
            continue
        destination = target / relative
        if name.endswith("/"):
            destination.mkdir(parents=True, exist_ok=True)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with game.open(name) as source, open(destination, "wb") as sink:
            shutil.copyfileobj(source, sink)

    missing = [EXECUTABLES[mode] for mode in modes if not (target / EXECUTABLES[mode]).is_file()]
    if missing:
        raise ValueError("Game archive did not unpack the expected executables into Game/: " + ", ".join(missing))
    if not (target / "zone" / "all").is_dir():
        raise ValueError("Game archive did not unpack zone/all into Game/")
    return target

def package(root, game_zip, out, team, work, bundle_id, library_origin, lan_root, private_server,
            unsigned=False, shell_only=False, modes=ALL_MODES):
    MODES = tuple(mode for mode in ALL_MODES if mode in modes)
    if not MODES:
        raise ValueError("No game mode to package")

    root, out, work = root.resolve(), out.resolve(), work.resolve()
    src = Path(__file__).resolve().parent

    mode_dirs = {mode: (lan_root if lan_root and mode in ("mps", "zms") else root / "device") / mode for mode in MODES}

    private = {mode: mode != "sps" and (bool(lan_root) or (mode_dirs[mode] / "pluto_pe_sections.bin").is_file()) for mode in MODES}

    for mode, mode_dir in mode_dirs.items():
        binary = mode_dir / (mode + ".framework") / mode
        sections = root / "conversion/boot_cache" / mode / "pe_sections.bin"
        if not sections.is_file() or not binary.is_file():
            raise RuntimeError(f"Missing full {mode} framework or PE sections")
        exports = subprocess.check_output(["xcrun", "nm", "-gUj", str(binary)], text=True).splitlines()
        if not {"_bo2_ios_start", "_bo2_ios_create_surface"} <= set(exports):
            raise ValueError(f"Incomplete {mode} runtime")
        if private[mode]:
            if not {"_bo2_pluto_start", "_bo2_cmd_queue", "_ios_game_event"} <= set(exports):
                raise ValueError(f"Missing private server entry points in {mode}")
            if not (mode_dir / "pluto_pe_sections.bin").is_file():
                raise ValueError(f"Missing private server sections for {mode}")

    settings = dict(PRODUCT_BUNDLE_IDENTIFIER=bundle_id,
                    GENERATE_INFOPLIST_FILE="YES",
                    INFOPLIST_KEY_UILaunchScreen_Generation="YES", INFOPLIST_KEY_UIRequiresFullScreen="YES",
                    INFOPLIST_KEY_UISupportedInterfaceOrientations="UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
                    CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="0.1", IPHONEOS_DEPLOYMENT_TARGET="16.0",
                    SWIFT_VERSION="5.0")
    settings.update(dict(CODE_SIGNING_ALLOWED="NO") if unsigned else
                    dict(DEVELOPMENT_TEAM=team, CODE_SIGN_STYLE="Automatic"))

    project = dict(name="BlackOpsII", targets={"BlackOpsII": dict(type="application", platform="iOS",
                    sources=["FullGame.m", "TouchOverlay.m"],
                    dependencies=[{"sdk": "AVFAudio.framework"}, {"sdk": "libz.tbd"}], settings={"base": settings})})

    out.parent.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)

    with (nullcontext() if shell_only else ZipFile(game_zip)) as game, tempfile.TemporaryDirectory(dir=work) as folder:
        stage = Path(folder)
        if game:
            names = set(game.namelist())
            required = {EXECUTABLES[mode] for mode in MODES}
            if not required <= names or not any(n.startswith("zone/all/") for n in names):
                raise ValueError("Game archive is missing required mode or zone files")
            for name in names:
                if "\\" in name or Path(name).is_absolute() or ".." in Path(name).parts:
                    raise ValueError("Unsafe archive path")
            total = sum(f.file_size for f in game.infolist())
            if shutil.disk_usage(work).free < total + 2 * 1024 ** 3:
                raise RuntimeError("Insufficient space to stage the complete game on the selected volume")

        shutil.copyfile(src / "FullGame.m", stage / "FullGame.m")
        # Guard against building from a stale FullGame.m: without this the app ships
        # with no Documents/Game creation and the Files app shows nothing to fill in.
        fullgame = (stage / "FullGame.m").read_text(encoding="utf-8", errors="replace")
        if "ManualGameDirectory" not in fullgame:
            raise ValueError(
                "FullGame.m does not create the writable Documents/Game folder. "
                "Build from the patched copy in this folder, not an older download."
            )
        for name in ("TouchOverlay.h", "TouchOverlay.m"): shutil.copyfile(src / name, stage / name)

        spec = stage / "project.json"
        spec.write_text(json.dumps(project))

        command("xcodegen", "generate", "--spec", spec)
        command("xcodebuild", "-project", stage / "BlackOpsII.xcodeproj", "-scheme", "BlackOpsII",
                "-configuration", "Release", "-destination", "generic/platform=iOS",
                *([] if unsigned else ["-allowProvisioningUpdates"]), "-derivedDataPath", stage / "Derived", "build")

        app = stage / "Payload/BlackOpsII.app"
        app.parent.mkdir()
        shutil.move(str(stage / "Derived/Build/Products/Release-iphoneos/BlackOpsII.app"), app)

        if not unsigned:
            details = subprocess.run(["codesign", "-dvvv", str(app)], capture_output=True, text=True, check=True).stderr
            identity = next(line.partition("=")[2] for line in details.splitlines() if line.startswith("Authority=Apple Development:"))
            ent = stage / "entitlements.plist"
            ent.write_bytes(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
            plistlib.loads(ent.read_bytes())

        info_path = app / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["NSLocalNetworkUsageDescription"] = "Connect to a private game server on your local network."
        info["CADisableMinimumFrameDurationOnPhone"] = True
        info["UIFileSharingEnabled"] = True
        info["LSSupportsOpeningDocumentsInPlace"] = True

        if private_server:
            info["BO2PrivateServer"] = str(private_server)
        if library_origin:
            info["GameLibraryOrigin"] = library_origin
        info_path.write_bytes(plistlib.dumps(info))

        shutil.copyfile(src / "CYPORT-LICENSE", app / "CYPORT-LICENSE")


        frameworks = app / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        for mode in MODES:
            lib = frameworks / (mode + ".framework")
            shutil.copytree(mode_dirs[mode] / lib.name, lib)
            if not unsigned: command("codesign", "--force", "--sign", identity, lib)
            
            dest = app / "Modes" / mode
            dest.mkdir(parents=True)
            shutil.copyfile(root / "conversion/boot_cache" / mode / "pe_sections.bin", dest / "pe_sections.bin")
            if private[mode]:
                shutil.copyfile(mode_dirs[mode] / "pluto_pe_sections.bin", dest / "pluto_pe_sections.bin")

        shaders = root / "BO2Shaders.metallib"
        if shaders.is_file():
            shutil.copyfile(shaders, app / shaders.name)

        if game: unpack_game(game, app, MODES)

        write_catalog(app, root, MODES)

        if not unsigned:
            command("codesign", "--force", "--sign", identity, "--entitlements", ent, app)
            command("codesign", "--verify", "--deep", "--strict", app)

        with tempfile.NamedTemporaryFile(dir=out.parent, delete=False) as f:
            tmp = Path(f.name)
            try:
                with ZipFile(tmp, "w", compression=ZIP_DEFLATED, compresslevel=1, allowZip64=True) as ipa:
                    for file in sorted(app.rglob("*")):
                        if file.is_file():
                            ipa.write(file, file.relative_to(stage))
                with ZipFile(tmp) as ipa:
                    bad = ipa.testzip()
                    if bad: raise ValueError("IPA readback failed for " + bad)
                os.replace(tmp, out)
            finally:
                tmp.unlink(missing_ok=True)

if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "game_zip", "output", "work"):
        p.add_argument(name, type=Path)
    p.add_argument("--team", help="Your Apple development team; required unless --unsigned")
    p.add_argument("--unsigned", action="store_true", help="Build without signing, for SideStore or a signing service")
    p.add_argument("--shell-only", action="store_true", help="Leave the game files out; game_zip is then ignored")
    p.add_argument("--bundle-id", required=True, help="Your registered app bundle identifier")
    p.add_argument("--library-origin", help="HTTPS origin of your private installation service")
    p.add_argument("--lan-root", type=Path, help="Prebuilt LAN frameworks and sections in mps/ and zms/")
    p.add_argument("--modes", nargs="+", choices=ALL_MODES, default=list(ALL_MODES),
                   help="The modes to put in the app; each one listed must be linked")
    p.add_argument("--private-server", type=IPv4Address, help="Private IPv4 gateway preset for the Join menu and USB fallback")
    a = p.parse_args()
    if not a.unsigned and not a.team: p.error("--team is required unless --unsigned")
    package(a.root, a.game_zip, a.output, a.team, a.work, a.bundle_id, a.library_origin, a.lan_root, a.private_server,
            a.unsigned, a.shell_only, a.modes)
