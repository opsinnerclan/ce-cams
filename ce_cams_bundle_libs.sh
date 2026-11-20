#!/usr/bin/env bash
# ce_cams_bundle_libs.sh - makes the CE Cams client .deb install on Ubuntu releases that no longer
# have libxml2.so.2 (Ubuntu 25.10 and 26.04 moved to libxml2.so.16, a new incompatible version).
#
#   ./ce_cams_bundle_libs.sh CLIENT.deb [OUT.deb]      (default OUT: CLIENT-bundled.deb)
#
# The client's web view (Qt WebEngine) is linked against libxml2.so.2 and libxslt.so.1. This puts
# Ubuntu 24.04's builds of those (and the ICU 74 libraries libxml2 uses) into the client's own lib
# folder, makes them find each other there, drops "libxml2" and "libxslt1.1" from the package's
# dependencies, adds a visible menu entry (the package only has the hidden cecams:// link
# handler) and makes the client start on X11 (its Qt can't use the system's Wayland plugin).
# The libraries come from archive.ubuntu.com and are checked against the SHA-256 in Ubuntu's
# package index. Needs dpkg-deb, python3 and patchelf (installed if missing).
set -euo pipefail

[ $# -ge 1 ] || { sed -n '2,14p' "$0"; exit 2; }
DEB=$(realpath "$1")
OUT=${2:-${DEB%.deb}-bundled.deb}
[ -f "$DEB" ] || { echo "No such file: $DEB"; exit 1; }
if ! command -v patchelf >/dev/null; then
    echo "  Installing patchelf (sudo apt install patchelf)"
    sudo apt-get install -y patchelf >/dev/null
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
dpkg-deb -R "$DEB" "$W/pkg"
# (libQt6Core.so.6 is usually a symlink to libQt6Core.so.6.x.y)
qtcore=$(find "$W/pkg/opt" -name 'libQt6Core.so.6*' \( -type f -o -type l \) | head -1)
[ -n "$qtcore" ] || { echo "Not a CE Cams client package (no libQt6Core in /opt)"; exit 1; }
LIBDIR=$(dirname "$qtcore")
echo "  Client libraries: ${LIBDIR#"$W/pkg"}"

echo "  Getting libxml2, libxslt and ICU 74 from Ubuntu 24.04"
python3 - "$W" <<'EOF'
import gzip, hashlib, re, sys, time, urllib.request
from pathlib import Path


def get(url: str) -> bytes:
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ce-cams-build"})
            return urllib.request.urlopen(req, timeout=300).read()
        except Exception as e:
            if attempt == 3:
                sys.exit(f"Couldn't download {url}: {e}")
            time.sleep(3)

work = Path(sys.argv[1])
want = ["libxml2", "libxslt1.1", "libicu74"]
base = "http://archive.ubuntu.com/ubuntu"
found = {}
for suite in ("noble-updates", "noble"):          # newest first
    url = f"{base}/dists/{suite}/main/binary-amd64/Packages.gz"
    index = gzip.decompress(get(url)).decode()
    for block in index.split("\n\n"):
        name = re.search(r"^Package: (\S+)$", block, re.M)
        if not name or name.group(1) not in want or name.group(1) in found:
            continue
        found[name.group(1)] = (re.search(r"^Filename: (\S+)$", block, re.M).group(1),
                                re.search(r"^SHA256: (\S+)$", block, re.M).group(1))
missing = [p for p in want if p not in found]
if missing:
    sys.exit(f"Not in Ubuntu 24.04's index: {', '.join(missing)}")
for pkg in want:
    filename, sha = found[pkg]
    data = get(f"{base}/{filename}")
    if hashlib.sha256(data).hexdigest() != sha:
        sys.exit(f"{filename}: checksum doesn't match Ubuntu's index; not used")
    (work / f"{pkg}.deb").write_bytes(data)
    print(f"    {filename.rsplit('/', 1)[1]} (checksum ok)")
EOF

mkdir -p "$W/x"
for p in libxml2 libxslt1.1 libicu74; do dpkg-deb -x "$W/$p.deb" "$W/x"; done
src="$W/x/usr/lib/x86_64-linux-gnu"
for pattern in 'libxml2.so.2*' 'libxslt.so.1*' 'libexslt.so.0*' 'libicuuc.so.74*' \
               'libicudata.so.74*' 'libicui18n.so.74*'; do
    for f in "$src"/$pattern; do
        # (never over a library the client already ships)
        [ -e "$f" ] && [ ! -e "$LIBDIR/$(basename "$f")" ] && cp -a "$f" "$LIBDIR/"
    done
done
# They have no RUNPATH: make them find each other (and the client's other libraries) next to
# themselves rather than on the system, where ICU and libxml2 are other versions.
for f in "$LIBDIR"/libxml2.so.2.* "$LIBDIR"/libxslt.so.1.* "$LIBDIR"/libexslt.so.0.* \
         "$LIBDIR"/libicuuc.so.74.* "$LIBDIR"/libicui18n.so.74.*; do
    [ -f "$f" ] && [ ! -L "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"
done

# Menu entry: the package's only .desktop file is the hidden cecams:// link handler
# (NoDisplay=true), so the client never showed up in the app list. Add a visible one.
for handler in "$W"/pkg/usr/share/applications/*.desktop; do
    [ -f "$handler" ] && grep -q '^NoDisplay=true' "$handler" || continue
    visible="${handler%.desktop}-client.desktop"
    [ -e "$visible" ] && continue
    sed -e '/^NoDisplay=/d' -e '/^MimeType=/d' -e 's/^Exec=\(.*\) %u$/Exec=\1/' \
        -e 's/^\(Icon=[^/].*\)\.png$/\1/' -e 's/^Comment=.*/Comment=Video management client/' \
        "$handler" > "$visible"
    grep -q '^Categories=' "$visible" || echo 'Categories=AudioVideo;Video;' >> "$visible"
    echo "  Menu entry: /usr/share/applications/$(basename "$visible")"
done

# Platform: on a Wayland desktop Qt picks its Wayland plugin, which then loads the system's
# (newer) Qt Wayland libraries and aborts ("Could not load the Qt platform plugin wayland").
# The client's start script now defaults to X11 (xcb, through XWayland on Wayland desktops).
for start in "$W"/pkg/opt/*/client/*/bin/client; do
    [ -f "$start" ] && head -c2 "$start" | grep -q '#!' || continue
    grep -q 'QT_QPA_PLATFORM' "$start" && continue
    sed -i '1a export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"   # CE Cams: bundled Qt vs system Wayland Qt' "$start"
    echo "  Start script: X11 (xcb) by default"
done

# Dependencies: drop the two now inside the package.
python3 - "$W/pkg/DEBIAN/control" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
def fix(m):
    deps = [d.strip() for d in m.group(1).split(",")]
    keep = [d for d in deps if not re.match(r"^(libxml2|libxslt1\.1)(\s|$|\()", d)]
    return "Depends: " + ", ".join(keep)
text = re.sub(r"^Depends: (.*)$", fix, text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
EOF

# Anything in the client still unable to find libxml2/libxslt/ICU?
bad=$(find "$LIBDIR" -maxdepth 1 -name '*.so*' -type f -exec sh -c \
      'LD_LIBRARY_PATH="$(dirname "$1")" ldd "$1" 2>/dev/null | grep -E "lib(xml2|xslt|exslt|icu[a-z]*)\.so.* not found" && echo "  in $1"' _ {} \; || true)
[ -z "$bad" ] || { echo "Still missing after bundling:"; echo "$bad"; exit 1; }

dpkg-deb --root-owner-group -Zxz --build "$W/pkg" "$OUT" >/dev/null
echo "  Made $OUT"
