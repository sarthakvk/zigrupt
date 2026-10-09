#!/usr/bin/env python3
"""Build main and every documented release tag into one Pages artifact."""

import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / ".docs-site"
CONTENT = SITE / "src/content/docs"
ASSETS = SITE / "src/assets"
DIST = SITE / "dist"


def run(*command, env=None):
    return subprocess.run(command, cwd=ROOT, env=env, check=True)


def tags_with_docs():
    tags = subprocess.check_output(
        ["git", "tag", "--sort=-version:refname", "--list", "v*"], cwd=ROOT, text=True
    ).splitlines()
    available = []
    for tag in tags:
        if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[-.][0-9A-Za-z.-]+)?", tag):
            continue
        if docs_layout(tag):
            available.append(tag)
    return available


def has_path(tag, path):
    return subprocess.run(
        ["git", "cat-file", "-e", f"{tag}:{path}"],
        cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0


def docs_layout(tag):
    if has_path(tag, "docs/index.md"):
        return "docs", "docs/assets"
    if has_path(tag, "docs/src/content/docs/index.md"):
        return "docs/src/content/docs", "docs/src/assets"
    return None


def build(version, tags):
    env = os.environ.copy()
    env["DOCS_VERSION"] = version
    env["DOCS_VERSIONS"] = json.dumps(tags)
    env["DOCS_BASE"] = "/zigrupt" if version == "main" else f"/zigrupt/{version}"
    shutil.rmtree(SITE / ".astro", ignore_errors=True)
    run("npm", "--prefix", ".docs-site", "run", "build", env=env)


def source_at_tag(tag, directory):
    content_path, assets_path = docs_layout(tag)
    paths = [content_path]
    if assets_path != content_path and has_path(tag, assets_path):
        paths.append(assets_path)
    archive = subprocess.check_output(
        ["git", "archive", tag, *paths], cwd=ROOT
    )
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(directory, filter="data")
    content = directory / content_path
    for page in content.rglob("*.md"):
        text = page.read_text()
        page.write_text(text.replace("(/zigrupt/", f"(/zigrupt/{tag}/"))
    assets = directory / assets_path
    assets.mkdir(parents=True, exist_ok=True)
    return content, assets


def link(path, target):
    path.unlink()
    path.symlink_to(target, target_is_directory=True)


def main():
    tags = tags_with_docs()
    print(f"Building main and {len(tags)} documented release tag(s)", flush=True)
    original_content = os.readlink(CONTENT)
    original_assets = os.readlink(ASSETS)
    with tempfile.TemporaryDirectory(prefix="zigrupt-docs-") as temp:
        work = Path(temp)
        combined = work / "combined"
        try:
            build("main", tags)
            shutil.move(DIST, combined)
            for tag in tags:
                source = work / tag
                content, assets = source_at_tag(tag, source)
                link(CONTENT, content)
                link(ASSETS, assets)
                build(tag, tags)
                shutil.move(DIST, combined / tag)
        finally:
            link(CONTENT, original_content)
            link(ASSETS, original_assets)
            if combined.exists():
                shutil.rmtree(DIST, ignore_errors=True)
                shutil.move(combined, DIST)
    run("npm", "--prefix", ".docs-site", "run", "check:links")


if __name__ == "__main__":
    main()
