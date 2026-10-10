"""Create a reproducible source archive from the repository's tracked files."""
from pathlib import Path
import gzip
import hashlib
import io
import os
import re
import subprocess
import tarfile

root = Path(__file__).resolve().parents[1]
version = re.fullmatch(r"return '([0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)?)'\s*", (root / "lua/rivet/version.lua").read_text()).group(1)
files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
files = sorted(path for path in files if path)
if not {"LICENSE", "bin/rivet", "lua/rivet/init.lua", "plugin/rivet.lua"}.issubset(files):
    raise SystemExit("Track the complete plugin source and license before packaging.")
stamp = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
name = f"rivet.nvim-{version}"
output = root / "dist"
output.mkdir(exist_ok=True)
archive = output / f"{name}.tar.gz"
with archive.open("wb") as stream, gzip.GzipFile(fileobj=stream, mode="wb", filename="", mtime=stamp) as compressed, tarfile.open(fileobj=compressed, mode="w") as tar:
    for relative in files:
        source = root / relative
        if source.is_symlink() or not source.is_file():
            raise SystemExit(f"Expected a regular source file: {relative}")
        data = source.read_bytes()
        entry = tarfile.TarInfo(f"{name}/{relative}")
        entry.size, entry.mtime = len(data), stamp
        entry.mode = 0o755 if os.access(source, os.X_OK) else 0o644
        entry.uid = entry.gid = 0
        entry.uname = entry.gname = ""
        tar.addfile(entry, io.BytesIO(data))
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(archive.with_suffix(archive.suffix + ".sha256")).write_text(f"{digest}  {archive.name}\n")
print(archive)
print(digest)
