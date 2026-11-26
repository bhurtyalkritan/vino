# Vino

Run Windows apps on your Mac. Free, and one download: Vino sets up Rosetta and its own copy of Wine (WineHQ 11.0, built by Gcenx) the first time you open it.

Drop an installer on the window, and the app shows up with its real icon. Click it to open it.

## Build

```
cd mac
./build.sh            # makes mac/build/Vino.app
```

Needs Xcode (Swift 5.9+), macOS 13 or later.

## The command line

The app's own binary is also the `vino` command:

```
ln -s /Applications/Vino.app/Contents/Resources/vino /usr/local/bin/vino
vino doctor                      # checks your Mac and tells you exactly what to fix
vino setup                       # installs Rosetta and Wine if they're missing
vino run ~/Downloads/setup.exe   # installs or runs anything, no setup first
vino apps                        # what you have installed
vino run Notepad++               # start an installed app by name
```

Everything goes into one bottle called `default` unless you add `-b NAME` to keep an app separate.

| Command | What it does |
|---|---|
| `run [--debug] FILE-or-NAME [args]` | Runs a .exe/.msi/.lnk, or an installed app by name. `--debug` logs everything for a bug report |
| `apps` | Lists installed apps (Start Menu and Desktop shortcuts) |
| `quit [NAME]` | Asks an app to close, or closes everything in the bottle |
| `bottles` / `new NAME` / `delete NAME` | Lists, creates, or moves a bottle to the Trash |
| `installed` | Lists the programs installed in a bottle |
| `set NAME=value` | Saves a bottle setting. `NAME=` removes one. See below |
| `wine PROGRAM [args]` | Runs a Wine tool in the bottle: `taskmgr`, `regedit`, `winecfg`, `wineboot -r` |
| `wines` | Lists the Wine versions on this Mac |
| `files` | Opens the bottle's C: drive in Finder |
| `install recipe.json` | Downloads, checks and installs an app |
| `setup` / `doctor` | Installs what's missing / checks everything |

Settings for `set` (all per bottle):

| Setting | Effect |
|---|---|
| `VINO_DXVK=1` | DirectX 10/11 through DXVK (downloaded once, checksum-pinned) |
| `DXVK_HUD=fps` | Frame-rate counter in DXVK games |
| `VINO_RETINA=1` | Retina resolution |
| `VINO_CMDCTRL=1` | ⌘ acts as Ctrl, so ⌘C/⌘V copy and paste |
| `VINO_WINVER=win7` | Windows version: `win11`, `win10`, `win81`, `win8`, `win7`, `vista`, `winxp` |
| `VINO_WINE=/path/to/wine` | This bottle's own Wine build |
| anything else | Passed to Wine as an environment variable |

Each run is logged to `<bottle>/logs/<app>.log` (the run before is kept as `.prev.log`). App icons are read from the Windows program and cached in `<bottle>/icons/`.

## Recipes

```json
{
  "name": "Notepad++",
  "url": "https://github.com/…/npp.8.9.9.1.Installer.x64.exe",
  "sha256": "<sha256 of the file>",
  "args": ["/S"],
  "env": {"VINO_CMDCTRL": "1"}
}
```

`sha256` is required. Vino won't run a download that doesn't match it. See `recipes/`.

## Tests

```
cd mac && swift build -c release && swift test     # unit tests
python3 test_vino.py                               # the command line, end to end, with a fake Wine
cd mac && VINO_TEST_DOWNLOAD=1 swift test --filter testDownloadWine   # downloads Wine (185 MB) into a temp folder
```

## License

MIT, see `LICENSE`. innoextract (in `mac/vendor`) has its own zlib license. Wine is LGPL; Vino downloads it rather than including it.
