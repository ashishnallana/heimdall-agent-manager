#!/usr/bin/env python3
"""Emit the shared build/storeless matrix; Intel macOS requires explicit opt-in."""

import json
import os


def release_matrix(include_darwin_x64=False):
    targets = [
        {"target": "linux-amd64", "runner": "ubuntu-24.04", "nix_system": "x86_64-linux"},
        {"target": "linux-arm64", "runner": "ubuntu-24.04-arm", "nix_system": "aarch64-linux"},
        {"target": "darwin-arm64", "runner": "macos-15", "nix_system": "aarch64-darwin"},
    ]
    # termux-arm64 stays disabled until the release-musl backtrace link issue is fixed.
    if include_darwin_x64:
        targets.append({"target": "darwin-amd64", "runner": "macos-15-intel", "nix_system": "x86_64-darwin"})
    return {"include": targets}


if __name__ == "__main__":
    print(json.dumps(release_matrix(os.environ.get("BUILD_DARWIN_X64", "false") == "true"), separators=(",", ":")))
