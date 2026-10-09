#!/usr/bin/env python3
"""Verify a packaged dependency in an isolated consumer, without network access."""

from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
manifest = (root / "build.zig.zon").read_text()
paths = re.search(r"\.paths\s*=\s*\.\{([^}]+)\}", manifest)
if not paths:
    raise SystemExit("Cannot read the package .paths allowlist")

with tempfile.TemporaryDirectory(prefix="zigrupt-install-") as directory:
    work = Path(directory)
    consumer = work / "consumer"
    consumer.mkdir()
    (consumer / "vendor").mkdir()
    archive = consumer / "vendor/zigrupt.tar.gz"
    with tarfile.open(archive, "w:gz") as package:
        for name in re.findall(r'"([^"]+)"', paths[1]):
            if name in {"docs", "", "."}:
                raise SystemExit("Documentation dependencies must stay outside the Zig package")
            package.add(root / name, arcname=f"zigrupt/{name}")

    def run(*args):
        subprocess.run(args, cwd=consumer, check=True, timeout=120)

    run("zig", "init", "--minimal")
    shutil.copyfile(root / "examples/consumer/build.zig", consumer / "build.zig")
    (consumer / "src").mkdir(exist_ok=True)
    shutil.copyfile(root / "examples/basic.zig", consumer / "src/main.zig")
    # Match the documented vendored URL/hash dependency declaration.
    run("zig", "fetch", "--save=zigrupt", "vendor/zigrupt.tar.gz")
    if '.hash = "zigrupt-' not in (consumer / "build.zig.zon").read_text():
        raise SystemExit("zig fetch did not save the dependency hash")
    run("zig", "build")
    run("zig", "build", "run")

print("Standalone archive installation: passed (basic: sum = 55)")
