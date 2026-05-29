#!/usr/bin/env python3
"""Remove package entries from an xbps repodata file.

The repodata file is a (possibly gzip-compressed) tar archive containing
`index.plist` and optionally `index-files.plist` and `index-meta.plist`,
all in Apple XML plist format with package names as top-level keys.

Usage:
    repodata-strip.py REPODATA NAME [NAME...]

Exit status 0 on success (including no-op when no listed name was present),
nonzero on parse or I/O failure.
"""

from __future__ import annotations

import io
import os
import plistlib
import subprocess
import sys
import tarfile

INDEX_FILES = {"index.plist", "index-files.plist"}


def _zstd_decompress(path: str) -> bytes:
    try:
        return subprocess.check_output(["zstd", "-dc", "--", path])
    except FileNotFoundError:
        sys.stderr.write(
            "error: zstd repodata detected but the `zstd` CLI is not "
            "installed (apt install zstd)\n"
        )
        sys.exit(2)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"error: zstd decompression failed: {e}\n")
        sys.exit(1)


def _zstd_compress(data: bytes) -> bytes:
    try:
        p = subprocess.run(
            ["zstd", "-c"], input=data, capture_output=True, check=True
        )
    except FileNotFoundError:
        sys.stderr.write("error: `zstd` CLI not found for re-compression\n")
        sys.exit(2)
    return p.stdout


def detect_format(path: str) -> str:
    """Returns 'gz', 'bz2', 'zstd', or 'tar' (uncompressed)."""
    with open(path, "rb") as f:
        magic = f.read(6)
    if magic[:2] == b"\x1f\x8b":
        return "gz"
    if magic[:3] == b"BZh":
        return "bz2"
    if magic[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    return "tar"


def open_tar_any(path: str, fmt: str) -> tarfile.TarFile:
    if fmt == "gz":
        return tarfile.open(path, mode="r:gz")
    if fmt == "bz2":
        return tarfile.open(path, mode="r:bz2")
    if fmt == "zstd":
        return tarfile.open(fileobj=io.BytesIO(_zstd_decompress(path)), mode="r:")
    return tarfile.open(path, mode="r:")


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write(f"Usage: {sys.argv[0]} REPODATA [NAME...]\n")
        return 2
    repodata = sys.argv[1]
    drop = set(sys.argv[2:])
    if not drop:
        return 0
    if not os.path.isfile(repodata):
        sys.stderr.write(f"error: not a file: {repodata}\n")
        return 1

    fmt = detect_format(repodata)

    members: list[tuple[tarfile.TarInfo, bytes]] = []
    with open_tar_any(repodata, fmt) as tf:
        for m in tf.getmembers():
            extracted = tf.extractfile(m)
            data = extracted.read() if extracted is not None else b""
            members.append((m, data))

    total_removed = 0
    rewritten: list[tuple[tarfile.TarInfo, bytes]] = []
    for m, data in members:
        if m.name in INDEX_FILES and m.isfile():
            try:
                idx = plistlib.loads(data)
            except Exception as e:
                sys.stderr.write(f"error: failed to parse {m.name}: {e}\n")
                return 1
            if not isinstance(idx, dict):
                rewritten.append((m, data))
                continue
            removed = [k for k in list(idx) if k in drop]
            for k in removed:
                del idx[k]
            if removed:
                total_removed += len(removed)
                print(
                    f"  {m.name}: removed {len(removed)} entries "
                    f"({', '.join(removed)})"
                )
                data = plistlib.dumps(idx, fmt=plistlib.FMT_XML)
                m.size = len(data)
        rewritten.append((m, data))

    if total_removed == 0:
        print("  no matching entries in repodata; nothing to do")
        return 0

    # Build the new (uncompressed) tar in memory, then re-apply the
    # original compression so the on-wire format is preserved.
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:") as tf:
        for m, data in rewritten:
            tf.addfile(m, io.BytesIO(data))
    raw = buf.getvalue()

    if fmt == "zstd":
        out_bytes = _zstd_compress(raw)
    elif fmt == "gz":
        import gzip
        out_bytes = gzip.compress(raw)
    elif fmt == "bz2":
        import bz2
        out_bytes = bz2.compress(raw)
    else:
        out_bytes = raw

    tmp = repodata + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(out_bytes)
        os.replace(tmp, repodata)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
