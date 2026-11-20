#!/usr/bin/env python3
"""
ce_cams_fetch_sources.py - gets source archives that nx_open's Conan recipes download from Network
Optix's internal server (artifactory.us.nxteam.dev, unreachable from outside), from the
projects' public download sites instead, and puts them in Conan's download cache where the
recipe finds them.

  python ce_cams_fetch_sources.py BUILD_LOG CONAN_DATA_DIR DOWNLOAD_CACHE_DIR

Reads the failed download URLs from the build log. A file is used only if its checksum is one
the recipe itself lists, so the build gets exactly the source Nx's recipe expects. The recipe
(its copy in the build's Conan cache) is then pointed at the public URL, keeping its checksum
check: Conan 1 didn't use the download cache for these, so that alone wasn't enough. Exit code:
0 = fixed something (run the build again), 1 = nothing to do or not possible.
"""

from __future__ import annotations

import hashlib
import re
import sys
import urllib.request
from pathlib import Path

INTERNAL = "artifactory.us.nxteam.dev"

# file name -> where the project publishes it ({file} is the file name)
PUBLIC = [
    (re.compile(r"^ffmpeg-[\d.]+\.tar\.(xz|bz2|gz)$"), ["https://ffmpeg.org/releases/{file}"]),
    (re.compile(r"^openal-soft-([\d.]+)\.tar\.bz2$"),
     ["https://openal-soft.org/openal-releases/{file}",
      "https://github.com/kcat/openal-soft/releases/download/{v1}/{file}"]),
    (re.compile(r"^SVT-AV1-v?([\d.]+)\.tar\.(gz|bz2)$"),
     ["https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v{v1}/{file}"]),
]


def failed_downloads(log: str) -> list[tuple[str, str]]:
    """(package/version, url) for each source download from the internal server that failed."""
    out = []
    for m in re.finditer(r"(\S+/[\w.\-]+): ERROR: Error downloading file (https://\S+?):", log):
        pkg, url = m.group(1), m.group(2)
        if INTERNAL in url and (pkg, url) not in out:
            out.append((pkg, url))
    return out


def recipe_text(conan_data: Path, pkg: str) -> str:
    name, version = pkg.split("/", 1)
    text = ""
    for f in (conan_data / name / version).glob("*/*/export/*"):
        if f.suffix in (".py", ".yml", ".yaml"):
            text += f.read_text(encoding="utf-8", errors="replace")
    return text


def point_recipe_at(conan_data: Path, pkg: str, internal_url: str, public_url: str) -> bool:
    """Makes the exported recipe download public_url instead of the internal server."""
    name, version = pkg.split("/", 1)
    changed = False
    for f in (conan_data / name / version).glob("*/*/export/conanfile.py"):
        text = f.read_text(encoding="utf-8")
        if public_url in text:
            return True
        new = text.replace(internal_url, public_url)
        if new == text:
            # The ffmpeg recipe builds its URL in self.url: get(self, self.url, md5=self.md5, ...)
            new = re.sub(r"\bget\(self, self\.url,", f'get(self, "{public_url}",', text)
        if new != text:
            orig = f.with_name(f.name + ".orig")
            if not orig.exists():
                orig.write_text(text, encoding="utf-8")
            f.write_text(new, encoding="utf-8")
            changed = True
    return changed


def cache_key(url: str, checksum: str) -> str:
    # Conan 1.66 CachedFileDownloader._get_hash for user downloads: sha256(url + checksum)
    return hashlib.sha256((url + checksum).encode()).hexdigest()


def fetch(pkg: str, url: str, conan_data: Path, cache: Path) -> bool:
    file = url.rsplit("/", 1)[1]
    sources = []
    for pattern, urls in PUBLIC:
        m = pattern.match(file)
        if m:
            v1 = m.group(1) if m.groups() else ""
            sources = [u.format(file=file, v1=v1) for u in urls]
            break
    if not sources:
        print(f"  {pkg}: no public download site known for {file}")
        return False
    recipe = recipe_text(conan_data, pkg)
    if not recipe:
        print(f"  {pkg}: recipe not found under {conan_data}")
        return False
    for src in sources:
        print(f"  {pkg}: downloading {src}")
        try:
            req = urllib.request.Request(src, headers={"User-Agent": "ce-cams-build"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
        except Exception as e:
            print(f"    failed: {e}")
            continue
        sums = {"md5": hashlib.md5(data).hexdigest(), "sha1": hashlib.sha1(data).hexdigest(),
                "sha256": hashlib.sha256(data).hexdigest()}
        # Conan uses sha256, else sha1, else md5 as the cache key: the strongest one the
        # recipe gives, which is the one found in it.
        for kind in ("sha256", "sha1", "md5"):
            if sums[kind] in recipe:
                cache.mkdir(parents=True, exist_ok=True)
                (cache / cache_key(url, sums[kind])).write_bytes(data)
                print(f"    ok: matches the recipe's {kind}")
                if point_recipe_at(conan_data, pkg, url, src):
                    print(f"    the recipe now downloads it from {src}")
                else:
                    print("    couldn't find the download line in the recipe; left in Conan's "
                          "download cache only")
                return True
        print(f"    not the file the recipe expects (md5 {sums['md5']}); not used")
    return False


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip())
        return 2
    log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    conan_data, cache = Path(sys.argv[2]), Path(sys.argv[3])
    todo = failed_downloads(log)
    if not todo:
        return 1
    print("Getting sources Nx's recipes fetch from Nx's internal server:")
    got = [fetch(pkg, url, conan_data, cache) for pkg, url in todo]
    return 0 if any(got) else 1


if __name__ == "__main__":
    sys.exit(main())
