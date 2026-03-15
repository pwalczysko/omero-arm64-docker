#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Build ARM64-native OMERO Docker images for Apple Silicon.

Steps:
  1. Clone or update upstream Docker repos into _build/
  2. Build images using our Dockerfiles (in dockerfiles/) against the upstream
     repo as build context (so upstream entrypoint scripts, playbooks, etc. resolve)
  3. Optionally push to a registry

Usage:
  python3 build.py                         # build both images (arm64)
  python3 build.py --platform linux/amd64  # build for a different platform
  python3 build.py --omero-version 5.6.17  # override OMERO version
  python3 build.py --push                  # build and push to registry
  python3 build.py --registry ghcr.io/myorg --tag v1.2.0
  python3 build.py --server-only
  python3 build.py --web-only
"""

import argparse
import subprocess
import sys
from pathlib import Path

UPSTREAM_REPOS = {
    "omero-server-docker": "https://github.com/ome/omero-server-docker.git",
    "omero-web-docker": "https://github.com/ome/omero-web-docker.git",
}

DEFAULT_REGISTRY = "ghcr.io/simonhard"
DEFAULT_OMERO_VERSION = "5.6.17"
DEFAULT_PLATFORM = "linux/arm64"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build ARM64-native OMERO Docker images")
    parser.add_argument(
        "--platform",
        default=DEFAULT_PLATFORM,
        help=f"Docker target platform (default: {DEFAULT_PLATFORM})",
    )
    parser.add_argument(
        "--omero-version",
        default=DEFAULT_OMERO_VERSION,
        help=f"OMERO version to install (default: {DEFAULT_OMERO_VERSION})",
    )
    parser.add_argument(
        "--registry",
        default=DEFAULT_REGISTRY,
        help=f"Registry prefix for image tags (default: {DEFAULT_REGISTRY})",
    )
    parser.add_argument(
        "--tag",
        default="latest",
        help="Image tag (default: latest)",
    )
    parser.add_argument(
        "--push",
        action="store_true",
        help="Push images to registry after building",
    )
    parser.add_argument(
        "--server-only",
        action="store_true",
        help="Build only omero-server",
    )
    parser.add_argument(
        "--web-only",
        action="store_true",
        help="Build only omero-web",
    )
    parser.add_argument(
        "--no-cache",
        action="store_true",
        help="Pass --no-cache to docker buildx build",
    )
    return parser.parse_args()


def run(cmd: list[str], **kwargs) -> None:
    """Run a command, streaming output, and raise on failure."""
    print(f"\n$ {' '.join(cmd)}")
    result = subprocess.run(cmd, **kwargs)
    if result.returncode != 0:
        sys.exit(result.returncode)


def clone_or_update(name: str, url: str, build_dir: Path) -> Path:
    repo_dir = build_dir / name
    if (repo_dir / ".git").exists():
        print(f"[{name}] Repository exists, pulling latest...")
        run(["git", "-C", str(repo_dir), "pull", "--ff-only"])
    else:
        print(f"[{name}] Cloning {url}...")
        run(["git", "clone", url, str(repo_dir)])
    return repo_dir


def image_tag(registry: str, name: str, tag: str) -> str:
    return f"{registry}/{name}:{tag}"


def build_image(
    *,
    dockerfile: Path,
    context: Path,
    tags: list[str],
    platform: str,
    build_args: dict[str, str],
    push: bool,
    no_cache: bool,
) -> None:
    cmd = [
        "docker", "buildx", "build",
        "--platform", platform,
        "-f", str(dockerfile),
    ]
    for tag in tags:
        cmd += ["--tag", tag]
    for key, value in build_args.items():
        cmd += ["--build-arg", f"{key}={value}"]
    if push:
        cmd.append("--push")
    else:
        cmd.append("--load")
    if no_cache:
        cmd.append("--no-cache")
    cmd.append(str(context))
    run(cmd)


def main() -> None:
    args = parse_args()

    base_dir = Path(__file__).parent.resolve()
    build_dir = base_dir / "_build"
    build_dir.mkdir(exist_ok=True)
    dockerfiles_dir = base_dir / "dockerfiles"

    build_server = not args.web_only
    build_web = not args.server_only

    images = []
    if build_server:
        images.append({
            "upstream_repo": "omero-server-docker",
            "dockerfile": dockerfiles_dir / "omero-server.Dockerfile",
            "image_name": "omero-server-arm64",
            "build_args": {"OMERO_VERSION": args.omero_version},
        })
    if build_web:
        images.append({
            "upstream_repo": "omero-web-docker",
            "dockerfile": dockerfiles_dir / "omero-web.Dockerfile",
            "image_name": "omero-web-arm64",
            "build_args": {},
        })

    print("=" * 60)
    print("OMERO ARM64 Image Builder")
    print(f"  platform      : {args.platform}")
    print(f"  omero_version : {args.omero_version}")
    print(f"  registry      : {args.registry}")
    print(f"  tag           : {args.tag}")
    print(f"  push          : {args.push}")
    print("=" * 60)

    # Step 1: Clone / update upstream repos
    print("\n--- Step 1: Clone / update upstream repositories ---")
    repos_needed = {img["upstream_repo"] for img in images}
    for name in repos_needed:
        clone_or_update(name, UPSTREAM_REPOS[name], build_dir)

    # Step 2: Build images
    print("\n--- Step 2: Build images ---")
    for img in images:
        context = build_dir / img["upstream_repo"]
        primary_tag = image_tag(args.registry, img["image_name"], args.tag)
        tags = [primary_tag]
        if args.tag != "latest":
            tags.append(image_tag(args.registry, img["image_name"], "latest"))

        print(f"\nBuilding {primary_tag} ...")
        build_image(
            dockerfile=img["dockerfile"],
            context=context,
            tags=tags,
            platform=args.platform,
            build_args=img["build_args"],
            push=args.push,
            no_cache=args.no_cache,
        )
        print(f"  Done: {primary_tag}")

    print("\n" + "=" * 60)
    print("Build complete!")
    print("=" * 60)
    if not args.push:
        print("\nImages available locally:")
        for img in images:
            print(f"  {image_tag(args.registry, img['image_name'], args.tag)}")
        print("\nTo start the OMERO stack:")
        print(f"  cd {base_dir}")
        print("  cp .env.example .env   # edit credentials first")
        print("  docker compose up -d")
        print("\nOMERO.web will be available at http://localhost:8094")
        print("First startup may take several minutes while OMERO initialises.")


if __name__ == "__main__":
    main()
