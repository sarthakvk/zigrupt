"""Fetch pinned source archives and build the four unmodified implementations."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent
BIN = ROOT / ".bin"
DEPS = ROOT / ".deps"
SOURCES = json.loads((ROOT / "sources.json").read_text())
ADAPTER_FILES = ("native.zig", "platform.c", "rust/src/main.rs", "rust/build.rs", "rust/Cargo.toml", "rust/Cargo.lock", "java/Bench.java")


def adapter_hashes() -> dict[str, str]:
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ADAPTER_FILES}


def execute(command: list[str], **kwargs: object) -> str:
    print("+", " ".join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE, **kwargs)
    return result.stdout.strip()


def tree_hash(path: Path, suffixes: set[str] | None = None) -> str:
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file() and (suffixes is None or file.suffix in suffixes):
            digest.update(str(file.relative_to(path)).encode())
            digest.update(file.read_bytes())
    return digest.hexdigest()


def fetch(name: str, source: dict[str, str]) -> None:
    destination = DEPS / name
    marker = destination / ".benchmark-revision"
    if marker.exists():
        if marker.read_text().strip() != source["revision"]:
            raise RuntimeError(f"Unexpected source in {destination}; move it aside before rebuilding")
        return
    if destination.exists():
        raise RuntimeError(f"Unverified source directory: {destination}; move it aside")
    archive = DEPS / f"{source['revision']}.tar.gz"
    with archive.open("wb") as output:
        subprocess.run(["gh", "api", f"repos/{source['repository']}/tarball/{source['revision']}"],
                       stdout=output, check=True)
    with tempfile.TemporaryDirectory(dir=DEPS) as temporary:
        with tarfile.open(archive) as tar:
            tar.extractall(temporary, filter="data")
        entries = list(Path(temporary).iterdir())
        if len(entries) != 1:
            raise RuntimeError("Unexpected source archive layout")
        entries[0].rename(destination)
    marker.write_text(source["revision"] + "\n")


def main() -> None:
    BIN.mkdir(exist_ok=True)
    DEPS.mkdir(exist_ok=True)
    for name, source in SOURCES.items():
        fetch(name, source)
        if tree_hash(DEPS / name) != source["tree_sha256"]:
            raise RuntimeError(f"Pinned source tree changed: {name}")
    execute(["gcc", "-O3", "-fPIC", "-c", "platform.c", "-o", str(BIN / "platform.o")])
    execute(["ar", "rcs", str(BIN / "libplatform.a"), str(BIN / "platform.o")])
    versions: dict[str, str] = {}
    for name in ("zigrupt", "ziggy"):
        compiler = ["zig"] if name == "zigrupt" else ["devbox", "run", "-c", str(ROOT / "ziggy"), "--", "zig"]
        versions[name] = execute(compiler + ["version"])
        config = BIN / f"{name}-config.zig"
        config.write_text(f"pub const ziggy = {'true' if name == 'ziggy' else 'false'};\n")
        library = ROOT.parent / "src/root.zig" if name == "zigrupt" else DEPS / "ziggy/src/ring_buffer.zig"
        execute(compiler + ["build-lib", "-O", "ReleaseFast", "-mcpu=native", "-fPIC", "-lc",
                           "--dep", "config", "--dep", "library", f"-Mroot={ROOT / 'native.zig'}",
                           f"-Mconfig={config}", "-O", "ReleaseFast", "-mcpu=native", f"-Mlibrary={library}",
                           f"-femit-bin={BIN / (name + '.a')}"])
        execute(["gcc", "-O3", "-DZIG_MAIN", "platform.c", str(BIN / f"{name}.a"),
                 "-lpthread", "-ldl", "-lm", "-o", str(BIN / name)])
    env: dict[str, str] = dict(os.environ)
    env["RUSTFLAGS"] = "-C target-cpu=native"
    cargo = ["cargo", "build", "--release", "--manifest-path", "rust/Cargo.toml"]
    if (ROOT / "rust/Cargo.lock").exists():
        cargo.append("--locked")
    execute(cargo, env=env)
    shutil.copy2(ROOT / "rust/target/release/disruptor-bench", BIN / "rust")
    java_home = Path(shutil.which("javac")).resolve().parent.parent
    execute(["gcc", "-O3", "-shared", "-fPIC", "-DJNI", "platform.c",
             f"-I{java_home / 'include'}", f"-I{java_home / 'include/linux'}",
             "-o", str(BIN / "libbenchplatform.so")])
    classes = BIN / "java-adapter"
    library_classes = BIN / "java-library"
    classes.mkdir(exist_ok=True)
    library_classes.mkdir(exist_ok=True)
    java_sources = sorted((DEPS / "java/src/main/java").rglob("*.java"))
    execute(["javac", "--release", "21", "-d", str(library_classes), *map(str, java_sources)])
    execute(["javac", "--release", "21", "-cp", str(library_classes), "-d", str(classes), "java/Bench.java"])
    for name, command in {"rustc": ["rustc", "--version"], "cargo": ["cargo", "--version"],
                          "jdk": ["java", "-version"], "gcc": ["gcc", "--version"],
                          "python": ["python", "--version"]}.items():
        versions[name] = execute(command, stderr=subprocess.STDOUT)
    metadata = {
        "sources": SOURCES, "versions": versions, "adapter_sha256": adapter_hashes(),
        "zigrupt_commit": execute(["git", "rev-parse", "HEAD"]),
        "zigrupt_source_sha256": tree_hash(ROOT.parent / "src"),
        "competitor_source_sha256": {name: tree_hash(DEPS / name, {".rs", ".zig", ".java"}) for name in SOURCES},
        "build_options": {"zig": "ReleaseFast -mcpu=native -fPIC -lc",
                          "rust": "opt-level=3 lto=fat codegen-units=1 panic=abort target-cpu=native",
                          "java": "javac --release 21", "platform": "gcc -O3"},
        "binaries_sha256": {name: hashlib.sha256((BIN / name).read_bytes()).hexdigest()
                            for name in ("zigrupt", "ziggy", "rust", "libbenchplatform.so")},
        "java_classes_sha256": tree_hash(classes),
        "java_library_classes_sha256": tree_hash(library_classes),
    }
    (BIN / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
