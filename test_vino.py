"""Tests the vino command line (the Mac app's own binary) using a fake Wine.
Build first (cd mac && swift build -c release), then run: python3 test_vino.py"""
import hashlib, json, os, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).parent
VINO = Path(os.environ.get("VINO_BIN", HERE / "mac/.build/release/Vino"))
home = Path(tempfile.mkdtemp())
calls = home / "calls"
fake = home / "fake-wine"
fake.write_text('#!/bin/sh\necho "$WINEPREFIX|$WINEDEBUG|$FOO|$*|$PWD" >> "$CALLS"\necho "err: boom"\n[ -n "$FAKE_EXIT" ] && echo "0123:err:dll:real problem" && echo "info noise"\n[ -n "$FAKE_SLEEP" ] && sleep "$FAKE_SLEEP"\nexit ${FAKE_EXIT:-0}\n')
fake.chmod(0o755)
(home / "wineserver").write_text(fake.read_text())  # vino finds wineserver next to wine
(home / "wineserver").chmod(0o755)
env = {**os.environ, "HOME": str(home), "VINO_WINE": str(fake), "CALLS": str(calls)}
B = home / "Library/Application Support/vino/bottles"


def vino(*args, **extra):
    return subprocess.run([str(VINO), *args], env={**env, **extra}, capture_output=True, text=True)


def last_call():
    return calls.read_text().splitlines()[-1].split("|")


# run a file: auto-creates the default bottle, quiet fixme logging
exe = home / "setup.exe"
exe.write_text("MZ")
r = vino("run", str(exe), "/S")
assert r.returncode == 0, r.stderr
prefix, debug, _, args, _ = last_call()
assert prefix == str(B / "default") and debug == "fixme-all"
assert args == f"{exe.resolve()} /S", args  # .exe files run directly, so console output reaches the log
assert (B / "default/logs/setup.log").read_text().strip() == "err: boom"
assert json.loads((B / "default/vino-history.json").read_text())["setup"]["code"] == 0
vino("run", "--debug", str(exe))
assert last_call()[1] == "warn+all,+loaddll"

# failure shows the log tail and where the full log is
r = vino("run", str(exe), FAKE_EXIT="3")
assert r.returncode == 1 and "real problem" in r.stderr and "noise" not in r.stderr, r.stderr
assert "exit status 3" in r.stderr and "logs/setup.log" in r.stderr
assert json.loads((B / "default/vino-history.json").read_text())["setup"]["code"] == 3

# installed apps are found by name across bottles, uninstallers hidden
menu = B / "games/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Steam"
menu.mkdir(parents=True)
(menu / "Steam.lnk").write_text("")
(menu / "Uninstall Steam.lnk").write_text("")
desk = B / "default/drive_c/users/me/Desktop"
desk.mkdir(parents=True)
(desk / "Notepad++.lnk").write_text("")
(desk / "some mac folder").mkdir()
(desk / "some mac folder/Old.lnk").write_text("")  # Desktop is the real Mac Desktop: don't dig into it
macdesk = home / "MacDesktop"
macdesk.mkdir()
(macdesk / "Private.lnk").write_text("")
(B / "default/drive_c/users/someone").mkdir(parents=True)
(B / "default/drive_c/users/someone/Desktop").symlink_to(macdesk)  # like Wine does; reading it would trigger a privacy prompt
r = vino("apps")
assert r.stdout.splitlines() == ["Notepad++", "Steam  (games)"], r.stdout
assert [(x["name"], x["bottle"]) for x in json.loads(vino("apps", "--json").stdout)] == [("Notepad++", "default"), ("Steam", "games")]
assert vino("run", "steam").returncode == 0
assert last_call()[0] == str(B / "games") and last_call()[3].endswith("Steam/Steam.lnk")
# a real Wine-made shortcut: vino opens its target itself, in its working folder
npp = B / "npp/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Notepad++.lnk"
npp.parent.mkdir(parents=True)
npp.write_bytes((HERE / "fixtures/notepad++.lnk").read_bytes())
(B / "npp/drive_c/Program Files/Notepad++").mkdir(parents=True)
(B / "npp/dosdevices").mkdir()
(B / "npp/dosdevices/c:").symlink_to("../drive_c")
assert vino("run", "-b", "npp", "notepad++", "a.txt").returncode == 0
_, _, _, args, cwd = last_call()
assert args == f"{B}/npp/dosdevices/c:/Program Files/Notepad++/notepad++.exe a.txt", args
assert Path(cwd).resolve() == (B / "npp/drive_c/Program Files/Notepad++").resolve(), cwd
# quitting one app asks its program to close; quitting a bottle stops everything in it
vino("quit", "-b", "npp", "Notepad++")
assert last_call()[3] == "taskkill /im notepad++.exe", last_call()
vino("quit", "-b", "npp")
assert last_call()[0] == str(B / "npp") and last_call()[3] == "-k"
r = vino("run", "nothing-here")
assert r.returncode == 1 and "vino apps" in r.stderr

# per-bottle settings, including picking a Wine build, and removing one
assert vino("set", "-b", "games", "FOO=bar", "VINO_WINE=" + str(fake)).returncode == 0
vino("run", "Steam")
assert last_call()[2] == "bar"
vino("set", "-b", "games", "FOO=")
assert json.loads((B / "games/vino-env.json").read_text()) == {"VINO_WINE": str(fake)}
assert vino("set", "oops").returncode == 1
assert vino("run", "-b", "../x", str(exe)).returncode == 1

# recipe install: checks sha256 before running anything
data = b"MZinstaller"
inst = home / "SteamSetup.exe"
inst.write_bytes(data)
recipe = home / "steam.json"
good = {"name": "Steam", "bottle": "r", "url": inst.as_uri(), "sha256": hashlib.sha256(data).hexdigest(), "args": ["/S"], "env": {"FOO": "1"}}
recipe.write_text(json.dumps({**good, "sha256": "0" * 64}))
n = len(calls.read_text().splitlines())
r = vino("install", str(recipe))
assert r.returncode == 1 and "sha256" in r.stderr and len(calls.read_text().splitlines()) == n
recipe.write_text(json.dumps(good))
r = vino("install", str(recipe))
assert r.returncode == 0, r.stderr
prefix, _, foo, args, _ = last_call()
assert prefix == str(B / "r") and foo == "1" and args.endswith("SteamSetup.exe /S")

# delete moves to the Trash instead of erasing
assert vino("delete", "r").returncode == 0
assert not (B / "r").exists() and any((home / ".Trash").glob("vino r *"))

# the Mac app's views of bottles, apps, Wine builds and installed programs
assert {"name": "games", "path": str(B / "games"), "env": {"VINO_WINE": str(fake)}} in json.loads(vino("bottles", "--json").stdout)
assert json.loads(vino("wines", "--json").stdout)[0]["path"] == str(fake)
listed = {x["name"]: x for x in json.loads(vino("apps", "--json").stdout)}
assert listed["Steam"]["last"] is None  # its shortcut is unreadable, so there's no real exit code to record
assert listed["Notepad++"]["last"] is not None and listed["Notepad++"]["log"].endswith("logs/Notepad++.log"), listed
(B / "games/system.reg").write_text('WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Steam] 1\n'
    '"DisplayName"="Steam \\"Beta\\""\n"DisplayVersion"="2.10"\n\n[Software\\\\Other] 1\n"DisplayName"="Not a program"\n')
assert json.loads(vino("installed", "-b", "games", "--json").stdout) == [{"name": 'Steam "Beta"', "version": "2.10"}]

# settings that change the bottle run the right Wine commands
vino("set", "-b", "games", "VINO_WINVER=win7")
assert last_call()[3] == "winecfg -v win7"
vino("set", "-b", "games", "VINO_RETINA=1")
assert last_call()[3] == "reg add HKCU\\Control Panel\\Desktop /v LogPixels /t REG_DWORD /d 192 /f", last_call()
vino("set", "-b", "games", "VINO_CMDCTRL=0")
assert last_call()[3] == "reg add HKCU\\Software\\Wine\\Mac Driver /v RightCommandIsCtrl /t REG_SZ /d n /f"
n = len(calls.read_text().splitlines())
vino("set", "-b", "games", "VINO_DXVK=0")  # never turned on: nothing to undo
assert len(calls.read_text().splitlines()) == n and "WINEDLLOVERRIDES" not in json.loads((B / "games/vino-env.json").read_text())

# raw Wine tools and new bottles
vino("wine", "-b", "games", "wineboot", "-r")
assert last_call()[3] == "wineboot -r"
assert vino("new", "fresh").returncode == 0 and last_call()[0] == str(B / "fresh") and last_call()[3] == "wineboot -i"
assert vino("new", "fresh").returncode == 1

# ---- regressions found by the stress-test agents ----
def vino_ok(*args, **extra):
    r = vino(*args, **extra)
    assert "Traceback" not in r.stderr, (args, r.stderr)
    return r

# parallel runs keep every history entry
for i in range(12):
    (home / f"par{i}.exe").write_text("MZ")
procs = [subprocess.Popen([str(VINO), "run", "-b", "race", str(home / f"par{i}.exe")], env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(12)]
[p.wait() for p in procs]
assert len(json.loads((B / "race/vino-history.json").read_text())) == 12

# a setting that fails halfway still records the ones before it
failing = home / "fail-wine"
failing.write_text('#!/bin/sh\nexit 7\n')
failing.chmod(0o755)
r = vino_ok("set", "-b", "half", "FOO=bar", "VINO_RETINA=1", VINO_WINE=str(failing))
assert r.returncode == 1 and json.loads((B / "half/vino-env.json").read_text()) == {"FOO": "bar"}

# a failed new bottle can be retried; bad names are refused cleanly
assert vino_ok("new", "broken", FAKE_EXIT="1").returncode == 1 and not (B / "broken").exists()
assert vino_ok("new", "-b").returncode != 0 and vino_ok("set", "-b", "..", "A=1").returncode == 1

# deleting the same name twice in a second doesn't nest or crash
for _ in range(3):
    (B / "tr").mkdir()
    assert vino_ok("delete", "tr").returncode == 0
assert len(list((home / ".Trash").glob("vino tr *"))) == 3

# junk settings and history files don't crash anything
(B / "junk").mkdir()
(B / "junk/vino-env.json").write_text("[1, 2]")
(B / "junk/vino-history.json").write_text("not json")
for cmd in (["bottles"], ["bottles", "--json"], ["apps", "--json"], ["run", "-b", "junk", str(exe)]):
    assert vino_ok(*cmd).returncode == 0, cmd
(B / "junk/vino-env.json").write_text('{"FOO": 1}')
assert vino_ok("run", "-b", "junk", str(exe)).returncode == 0 and last_call()[2] == "1"

# a broken Wine path gives a message, not a crash
# (a folder or missing path would make vino fall back to the real Wine on this Mac, so use a broken program)
garbage = home / "garbage-wine"
garbage.write_bytes(b"\x00\x01not a program")
garbage.chmod(0o755)
r = vino_ok("run", str(exe), VINO_WINE=str(garbage))
assert r.returncode == 1 and "couldn't start Wine" in r.stderr, r.stderr
assert vino_ok("doctor", VINO_WINE=str(garbage)).returncode == 1
assert vino_ok("set", "-b", "games", "VINO_WINE=" + str(home / "nope")).returncode == 1
assert vino_ok("set", "-b", "games", "VINO_RETINA=yes").returncode == 1
assert vino_ok("set", "-b", "games", "VINO_WINVER=win98").returncode == 1

# very long names, folders posing as shortcuts, empty names, and duplicate names across bottles
long = home / ("x" * 250)
long.write_text("MZ")
assert vino_ok("run", str(long)).returncode == 0
odd = B / "odd/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs"
odd.mkdir(parents=True)
(odd / "Folder.lnk").mkdir()
(odd / "Dangling.lnk").symlink_to(home / "missing")
assert "Folder" not in vino_ok("apps").stdout
assert vino_ok("run", "").returncode == 1 and vino_ok("quit", "").returncode == 1
dup = B / "dup/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs"
dup.mkdir(parents=True)
(dup / "Steam.lnk").write_text("")
r = vino_ok("run", "Steam")
assert r.returncode == 1 and "-b dup" in r.stderr and "-b games" in r.stderr

# running a .lnk file directly opens its target and waits
direct = home / "direct.lnk"
direct.write_bytes((HERE / "fixtures/notepad++.lnk").read_bytes())
vino_ok("run", "-b", "npp", str(direct))
assert last_call()[3].endswith("dosdevices/c:/Program Files/Notepad++/notepad++.exe"), last_call()

# bad recipes give messages, not crashes
for bad in ([1], {"name": "x"}, {**good, "bottle": 5}, {**good, "args": "/S"}, {**good, "env": {"A": None}}, {**good, "url": "nonsense"}):
    recipe.write_text(json.dumps(bad))
    assert vino_ok("install", str(recipe)).returncode == 1, bad
assert vino_ok("install", str(home / "missing.json")).returncode == 1

# ---- regressions found against real Wine ----
# an installer's "restart needed" code (3010 arrives as 194) counts as success
assert vino_ok("run", str(exe), FAKE_EXIT="194").returncode == 0
# quitting with vino quit isn't reported as a crash
slow = subprocess.Popen([str(VINO), "run", "-b", "npp", "Notepad++"], env={**env, "FAKE_SLEEP": "2", "FAKE_EXIT": "1"},
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(0.8)
vino_ok("quit", "-b", "npp")
_, err = slow.communicate()
assert slow.returncode == 0 and "Traceback" not in err, err
assert json.loads((B / "npp/vino-history.json").read_text())["Notepad++"]["code"] == 0
# the previous log survives a re-run
assert (B / "default/logs/setup.prev.log").exists()
# vino wine shows the program's output instead of hiding it in a log
assert "err: boom" in vino_ok("wine", "-b", "games", "cmd", "/c", "ver").stdout
# emoji in program names, and hidden system parts and updates
(B / "games/user.reg").write_text('WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Part] 1\n'
    '"DisplayName"="Hidden part"\n"SystemComponent"=dword:00000001\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\KB1] 1\n'
    '"DisplayName"="An update"\n"ParentKeyName"="Steam"\n')
assert [x["name"] for x in json.loads(vino_ok("installed", "-b", "games", "--json").stdout)] == ['Steam "Beta"']

# ---- native panels: controllers, run in a window, task manager ----
vino_ok("set", "-b", "games", "VINO_SDL=0")
assert last_call()[3] == "reg add HKLM\\System\\CurrentControlSet\\Services\\WineBus /v Enable SDL /t REG_DWORD /d 0 /f", last_call()
vino_ok("set", "-b", "games", "VINO_DESKTOP=1280x800")
assert last_call()[3] == "reg add HKCU\\Software\\Wine\\Explorer /v Desktop /t REG_SZ /d Default /f", last_call()
vino_ok("set", "-b", "games", "VINO_DESKTOP=")
assert last_call()[3] == "reg delete HKCU\\Software\\Wine\\Explorer /v Desktop /f", last_call()
assert vino_ok("set", "-b", "games", "VINO_DESKTOP=900").returncode == 1
vino_ok("set", "-b", "games", "VINO_PADS_OFF=Pad A|Pad B")
n = len(calls.read_text().splitlines())
vino_ok("set", "-b", "games", "VINO_PADS_OFF=Pad B")  # Pad A switched back on
assert len(calls.read_text().splitlines()) == n + 1
assert last_call()[3] == "reg delete HKCU\\Software\\Wine\\DirectInput\\Joysticks /v Pad A /f", last_call()
n = len(calls.read_text().splitlines())
assert vino_ok("ps", "-b", "games", "--json").stdout.strip() == "[]"  # nothing running: answers without starting Wine
assert len(calls.read_text().splitlines()) == n
vino_ok("kill", "-b", "games", "42")
assert last_call()[3] == "taskkill /pid 42"
vino_ok("kill", "-b", "games", "--force", "42")
assert last_call()[3] == "taskkill /pid 42 /f"
assert vino_ok("kill", "-b", "games", "abc").returncode == 1

# ---- Get Apps catalog ----
cat = json.loads(vino_ok("catalog", "--json", VINO_RECIPES=str(HERE / "recipes")).stdout)
assert {"7-Zip", "Notepad++"} <= {c["name"] for c in cat}, cat
assert all(c["file"].endswith(".json") and "args" not in c for c in cat)
assert next(c for c in cat if c["name"] == "7-Zip")["app"] == "7-Zip File Manager"
r = vino_ok("install", "No Such App", VINO_RECIPES=str(HERE / "recipes"))
assert r.returncode == 1 and "vino catalog" in r.stderr
# apps know which program they run, so the app can tell when it's really running
assert next(x for x in json.loads(vino_ok("apps", "-b", "npp", "--json").stdout) if x["name"] == "Notepad++")["exe"] == "notepad++.exe"

# ---- per-app settings, Mac shortcuts, Windows components ----
assert vino_ok("configure", "-b", "npp", "Notepad++", "VINO_ARGS=-multiInst -nosession", "FOO=perapp").returncode == 0
vino_ok("run", "-b", "npp", "Notepad++", "extra.txt")
_, _, foo, args, _ = last_call()
assert foo == "perapp" and args.endswith("notepad++.exe -multiInst -nosession extra.txt"), (foo, args)
assert next(x for x in json.loads(vino_ok("apps", "-b", "npp", "--json").stdout) if x["name"] == "Notepad++")["settings"]["FOO"] == "perapp"
vino_ok("configure", "-b", "npp", "Notepad++", "FOO=")
assert "FOO" not in json.loads((B / "npp/vino-apps.json").read_text())["Notepad++"]
assert vino_ok("configure", "-b", "npp", "Nope", "A=1").returncode == 1

r = vino_ok("shortcut", "-b", "npp", "Notepad++")
app = Path(r.stdout.strip())
assert app == home / "Applications/Notepad++.app", app
launcher = (app / "Contents/MacOS/launch").read_text()
assert "run -b 'npp' -- 'Notepad++'" in launcher and os.access(app / "Contents/MacOS/launch", os.X_OK)
import plistlib
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleExecutable"] == "launch" and info["LSApplicationCategoryType"] == "public.app-category.games"
assert subprocess.run([str(app / "Contents/MacOS/launch")], env=env).returncode == 0  # the shortcut really opens it
assert last_call()[3].endswith("notepad++.exe -multiInst -nosession")

wt = home / "fake-winetricks"
wt.write_text('#!/bin/sh\necho "$WINEPREFIX|$*" >> "$CALLS.wt"\nshift\nfor v in "$@"; do echo "$v" >> "$WINEPREFIX/winetricks.log"; done\n')
wt.chmod(0o755)
assert vino_ok("winetricks", "-b", "games", "vcrun2022", "corefonts", VINO_WINETRICKS=str(wt)).returncode == 0
assert (home / "calls.wt").read_text().strip().endswith("|--unattended vcrun2022 corefonts")
comps = {c["verb"]: c["installed"] for c in json.loads(vino_ok("components", "-b", "games", "--json").stdout)}
assert comps["vcrun2022"] and comps["corefonts"] and not comps["dotnet48"], comps
assert vino_ok("winetricks", "-b", "games", "vcrun2022;rm", VINO_WINETRICKS=str(wt)).returncode == 1  # names are checked

print("all vino tests passed")
