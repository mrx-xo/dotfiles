#!/usr/bin/env python3
"""Copy configuration and package artifacts, excluding daemon runtime and IPC.

Existing destinations require --replace and are preserved beside the new copy.
External, dangling, and runtime-targeting symlinks are skipped; internal package
links are rebased to the sandbox.  Special files are never copied or opened.
Loading is inert.  The caller must first verify that its sandbox has stopped.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import time
import uuid

RUNTIME = {"var", "server", "crash-state", "session-state.el", "yabai-state.json",
           "clean-exit", "auto-save-list", "tmp", "temp", ".tmp", "search-output",
           ".search-output"}
IPC = {"SingletonLock", "SingletonCookie", "SingletonSocket", "S.gpg-agent",
       "S.gpg-agent.extra", "S.gpg-agent.browser", "S.gpg-agent.ssh",
       "fsmonitor--daemon.ipc", ".DS_Store"}


def excluded(relative):
    return relative.parts[0] in RUNTIME or any(part in IPC for part in relative.parts)


def provision(source, destination, replace=False):
    source = Path(source).resolve(strict=True)
    destination = Path(destination).absolute()
    if destination.is_symlink():
        raise ValueError("Sandbox destination must not be a symlink")
    destination = destination.parent.resolve(strict=True) / destination.name
    if (source == destination or source in destination.parents or destination in source.parents):
        raise ValueError("Source and sandbox destination must not overlap")
    if not source.is_dir() or (destination.exists() and not destination.is_dir()):
        raise ValueError("Source and destination must be directories")
    if destination.exists() and not replace:
        raise ValueError("Existing sandbox requires explicit --replace")
    stage = Path(tempfile.mkdtemp(prefix=".sandbox-copy-", dir=str(destination.parent)))
    skipped = []
    backup = None

    def visit(directory, relative=Path()):
        for entry in directory.iterdir():
            rel = relative / entry.name
            output = stage / rel
            try:
                mode = entry.lstat().st_mode
                if excluded(rel):
                    skipped.append(str(rel))
                elif stat.S_ISLNK(mode):
                    try:
                        target = entry.resolve(strict=True).relative_to(source)
                    except (ValueError, FileNotFoundError, RuntimeError):
                        skipped.append(str(rel))
                        continue
                    if not target.parts or excluded(target):
                        skipped.append(str(rel))
                        continue
                    output.symlink_to(os.path.relpath(str(destination / target),
                                                     str(destination / rel.parent)))
                elif stat.S_ISDIR(mode):
                    output.mkdir(mode=0o700)
                    visit(entry, rel)
                elif stat.S_ISREG(mode):
                    shutil.copyfile(str(entry), str(output))
                    output.chmod(0o600 | (mode & 0o100))
                    # Keep .elc newer than .el, or load-prefer-newer loads
                    # the sandbox's packages as slow interpreted source.
                    times = entry.stat()
                    os.utime(str(output), ns=(times.st_atime_ns, times.st_mtime_ns))
                else:
                    skipped.append(str(rel))
            except FileNotFoundError:
                # Live temporary files can disappear between listing and stat.
                skipped.append(str(rel))

    try:
        visit(source)
        if not (stage / "init.el").is_file():
            raise ValueError("Copy has no usable init.el; existing sandbox retained")
        if destination.exists():
            backup = destination.with_name(destination.name + ".previous-" + uuid.uuid4().hex)
            os.rename(str(destination), str(backup))
        try:
            os.rename(str(stage), str(destination))
        except OSError:
            if backup is not None and not destination.exists():
                os.rename(str(backup), str(destination))
            raise
        return {"destination": str(destination), "backup": str(backup) if backup else None,
                "skipped": skipped}
    finally:
        if stage.exists():
            shutil.rmtree(str(stage))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--runtime-directory", type=Path)
    args = parser.parse_args()
    runtime = args.runtime_directory or Path("/tmp") / ("emacs-diagnostic-start-%s" % os.getuid())
    if runtime.is_symlink():
        raise ValueError("Runtime directory must not be a symlink")
    runtime.mkdir(mode=0o700, exist_ok=True)
    if runtime.stat().st_uid != os.getuid():
        raise ValueError("Runtime directory must belong to this user")
    runtime.chmod(0o700)
    lock = runtime / (hashlib.sha256(b"sandbox").hexdigest() + ".lock")
    fd = os.open(str(lock), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("Sandbox launch/run still owns the lock; copy refused")
                time.sleep(0.05)
        result = provision(args.source, args.destination, args.replace)
    finally:
        os.close(fd)
    print(json.dumps({"destination": result["destination"], "backup": result["backup"],
                      "skipped_count": len(result["skipped"])}))


if __name__ == "__main__":
    main()
