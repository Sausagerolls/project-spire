#!/usr/bin/env python3
"""Reads the user's own Fable II disc image for Project Spire.

Usage:
    spire_disc.py check   <image.iso> <game_versions.json>
    spire_disc.py extract <image.iso> <game_versions.json> <out_dir>

check reads only default.xex and the directory tables, then prints one JSON
line: {"ok": bool, "name": ..., "id": ..., "message": ...}. extract does the
same check, then copies default.xex and data/ (all the game needs) into
out_dir, printing "PROGRESS <done> <total>" lines in bytes. Nothing is
extracted from a disc whose default.xex is not a supported build.

The disc filesystem is XDVDFS. Plain XISO images and full XGD1/2/3 dumps
are handled by probing the known game partition offsets.
"""

import hashlib
import json
import os
import struct
import sys

SECTOR = 0x800
MAGIC = b"MICROSOFT*XBOX*MEDIA"
DIR_FLAG = 0x10
PARTITION_OFFSETS = (0x0, 0x2080000, 0xFD90000, 0x18300000)


class DiscError(Exception):
    pass


def find_partition(f):
    for base in PARTITION_OFFSETS:
        f.seek(base + 32 * SECTOR)
        vd = f.read(SECTOR)
        if len(vd) == SECTOR and vd[:20] == MAGIC and vd[0x7EC:0x800] == MAGIC:
            root_sector, root_size = struct.unpack_from("<II", vd, 0x14)
            return base, root_sector, root_size
    raise DiscError("This file is not an Xbox 360 disc image.")


def walk_dir(f, base, sector, size, prefix=""):
    """Yields (path, start_sector, size, is_dir) for one directory table."""
    if size == 0:
        return
    f.seek(base + sector * SECTOR)
    table = f.read(size)
    seen = set()
    stack = [0]
    while stack:
        off = stack.pop()
        if off in seen or off + 14 > len(table):
            continue
        seen.add(off)
        left, right, start, fsize, attr, nlen = struct.unpack_from("<HHIIBB", table, off)
        if left == 0xFFFF and right == 0xFFFF:
            continue
        name = table[off + 14:off + 14 + nlen].decode("ascii", "replace")
        if left:
            stack.append(left * 4)
        if right:
            stack.append(right * 4)
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            raise DiscError(f"The disc has an unsafe file name: {name!r}")
        path = prefix + name
        is_dir = bool(attr & DIR_FLAG)
        yield path, start, fsize, is_dir
        if is_dir:
            yield from walk_dir(f, base, start, fsize, path + "/")


def read_entries(f):
    base, root_sector, root_size = find_partition(f)
    entries = {}
    for path, start, fsize, is_dir in walk_dir(f, base, root_sector, root_size):
        # XDVDFS names are case-insensitive; the game's files are lower case.
        entries[path.lower()] = (path, start, fsize, is_dir)
    return base, entries


def copy_range(f, base, start, size, out, on_bytes=None):
    f.seek(base + start * SECTOR)
    remaining = size
    while remaining:
        chunk = f.read(min(remaining, 8 << 20))
        if not chunk:
            raise DiscError("The disc image ended early. It may be incomplete.")
        out.write(chunk)
        remaining -= len(chunk)
        if on_bytes:
            on_bytes(len(chunk))


def xex_hash(f, base, entries):
    entry = entries.get("default.xex")
    if not entry or entry[3]:
        raise DiscError("default.xex was not found on this disc.")

    class Hasher:
        def __init__(self):
            self.h = hashlib.sha256()

        def write(self, data):
            self.h.update(data)

    hasher = Hasher()
    copy_range(f, base, entry[1], entry[2], hasher)
    return hasher.h.hexdigest()


def classify(versions, hash_hex, has_file, has_dir):
    """Matches launcher/Fable2.Launcher/GameCompatibility.cs Classify."""
    for v in versions["versions"]:
        if hash_hex.lower() != v["hash"].lower():
            continue
        if not v.get("compatible"):
            return False, v["name"], v.get("id"), v.get("reason", "This version is not supported.")
        if v.get("codeGroup") != versions.get("codeGroup"):
            return False, v["name"], v.get("id"), "This version's game code is not part of this build."
        reject_files = v.get("rejectFiles", [])
        reject_dirs = v.get("rejectDirectories", [])
        if reject_files or reject_dirs:
            if all(map(has_file, reject_files)) and all(map(has_dir, reject_dirs)):
                return False, v["name"], v.get("id"), (
                    "This disc mixes files from different releases. Use a complete dump of one disc.")
        if not all(map(has_file, v.get("requiredFiles", []))):
            return False, v["name"], v.get("id"), "Some game files are missing. The dump may be incomplete."
        return True, v["name"], v.get("id"), v.get("reason", "")
    return False, None, None, (
        "This disc is not a supported Fable II release (default.xex SHA-256 " + hash_hex + ").")


def check(f, versions):
    base, entries = read_entries(f)
    hash_hex = xex_hash(f, base, entries)

    def has_file(p):
        e = entries.get(p.lower())
        return bool(e) and not e[3]

    def has_dir(p):
        e = entries.get(p.lower())
        return bool(e) and e[3]

    return base, entries, classify(versions, hash_hex, has_file, has_dir)


def emit(ok, name, version_id, message):
    print(json.dumps({"ok": ok, "name": name, "id": version_id, "message": message}), flush=True)


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("check", "extract"):
        raise SystemExit(__doc__)
    mode, image, versions_path = sys.argv[1:4]
    with open(versions_path) as vf:
        versions = json.load(vf)
    try:
        with open(image, "rb") as f:
            base, entries, (ok, name, version_id, message) = check(f, versions)
            emit(ok, name, version_id, message)
            if not ok:
                return 2
            if mode == "check":
                return 0
            if len(sys.argv) != 5:
                raise SystemExit(__doc__)
            out_dir = os.path.realpath(sys.argv[4])
            wanted = [e for key, e in sorted(entries.items())
                      if key == "default.xex" or key.startswith("data/")]
            total = sum(e[2] for e in wanted if not e[3])
            done = 0
            last = -1

            def on_bytes(n):
                nonlocal done, last
                done += n
                step = done * 200 // max(total, 1)
                if step != last:
                    last = step
                    print(f"PROGRESS {done} {total}", flush=True)

            for path, start, fsize, is_dir in wanted:
                dest = os.path.realpath(os.path.join(out_dir, path))
                if not dest.startswith(out_dir + os.sep):
                    raise DiscError(f"The disc has a path outside the game folder: {path!r}")
                if is_dir:
                    os.makedirs(dest, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest + ".part", "wb") as out:
                    copy_range(f, base, start, fsize, out, on_bytes)
                os.replace(dest + ".part", dest)
            print(f"PROGRESS {total} {total}", flush=True)
    except (DiscError, OSError) as e:
        emit(False, None, None, str(e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
