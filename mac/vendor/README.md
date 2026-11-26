# Bundled tools

Vino ships these small programs inside the app. Each keeps its own license.

## innoextract

`innoextract` unpacks Inno Setup installers without running them. Vino uses it only when an Inno Setup
installer fails in Wine. It is © Daniel Scharrer, zlib license (see `innoextract-LICENSE`),
https://github.com/dscharrer/innoextract

Built from the master branch (1.10-dev, with Inno Setup 6.4 support) with Homebrew's static Boost, xz and zstd:

```
cmake .. -DCMAKE_BUILD_TYPE=Release -DUSE_STATIC_LIBS=ON -DCMAKE_PREFIX_PATH=/opt/homebrew \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DZLIB_LIBRARY=$(xcrun --show-sdk-path)/usr/lib/libz.tbd \
  -DBZIP2_LIBRARIES=$(xcrun --show-sdk-path)/usr/lib/libbz2.tbd -DCMAKE_EXE_LINKER_FLAGS=-L<folder with only libzstd.a>
make
```

The result links only libraries that come with macOS (`otool -L innoextract`).

## winetricks

The Winetricks script, release 20260125, from https://github.com/Winetricks/winetricks (LGPL-2.1, see `winetricks-COPYING`).
It installs Windows components; it checks the checksums of what it downloads.

## cabextract

cabextract 1.11 from https://www.cabextract.org.uk (GPL-2, see `cabextract-COPYING`), which many Winetricks installs need.
Built with `./configure CFLAGS="-O2 -mmacosx-version-min=13.0" && make`; it links only libraries that come with macOS.
