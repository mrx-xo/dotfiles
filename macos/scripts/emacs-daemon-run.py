#!/usr/bin/env python3
"""Kill-free named-daemon launcher and bounded diagnostic supervisor.

Requires Python 3.7+ and POSIX.  No launch occurs on import.  The shell entry
point requires a server and init directory.  It returns when that exact run
answers on that named socket.  A detached supervisor remains for the foreground
daemon's lifetime; it owns a per-server flock, never signals any process, and
drains stderr independently of disk writes.  Startup timeout preserves the
still-running process and its evidence, and never retries launch automatically.
The explicit runtime startup action installs hooks and attaches its PID before
readiness succeeds.  Both entry points must share the
same runtime directory for per-server exclusion (the default ignores TMPDIR).

stderr-status.json is incomplete until a finished status explicitly says
complete=true.  Queue overflow, disk failure, or an absent terminal status means
missing evidence.  A hung disk writer is a daemon thread, with bounded memory;
it cannot block the pipe reader.  A forcibly killed supervisor is outside this
guarantee.  Integration must supervise its lifetime alongside Emacs.
queue_dropped_bytes counts only queue overflow, not unquantifiable partial
writes after a disk error.  Consumers must use complete, not that counter,
to decide whether any evidence is missing.
"""
import argparse
import codecs
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import select
import subprocess
import sys
import tempfile
import threading
import time


def ordinary(path):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("Not an ordinary diagnostic file: " + str(path))


def atomic(path, text):
    """Private same-directory replacement; never follow a destination link."""
    ordinary(path)
    fd, name = tempfile.mkstemp(prefix=".write-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def private_directory(path):
    if path.is_symlink():
        raise ValueError("Directory must not be a symlink: " + str(path))
    path.mkdir(mode=0o700, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise ValueError("Directory is not owned by this user")
    path.chmod(0o700)


def lisp_string(value):
    """Encode a Lisp string, including paths containing quotes or controls."""
    return '"' + ''.join(('\\' + c if c in '\\"' else
                          '\\%03o' % ord(c) if ord(c) < 32 or ord(c) == 127
                          else c) for c in str(value)) + '"'


def create_run(parent, server, init_directory):
    private_directory(parent)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=str(parent))).resolve()
    metadata = ("(:schema-version 1 :run-id %s :server %s :init-directory %s "
                ":started-at %.6f :pid nil :initialized-at nil "
                ':logs ("recent-messages.log" "command-errors.log" "daemon-stderr.log"))\n')
    atomic(run / "metadata.el", metadata % (lisp_string(run.name), lisp_string(server),
           lisp_string(str(init_directory.resolve()) + os.sep), time.time()))
    status = {"state": "starting", "complete": False}
    try:
        atomic(run / "daemon-stderr.log", "")
    except (OSError, ValueError) as error:
        status["open_error"] = str(error)
    atomic(run / "stderr-status.json", json.dumps(status))
    return run


class RotatingLog:
    """One writer, 2 MiB current plus one previous segment, UTF-8 boundaries.

    The current segment is appended in place, so the writer stays ahead of a
    daemon that writes stderr unbuffered.  Only rotation rewrites a file, and
    that is the bounded previous segment.  Memory holds at most one segment.
    """
    def __init__(self, directory, limit=2 * 1024 * 1024):
        if limit < 64:
            raise ValueError("Log limit too small")
        self.current = Path(directory) / "daemon-stderr.log"
        self.previous = Path(directory) / "daemon-stderr.log.1"
        ordinary(self.current)
        ordinary(self.previous)
        self.limit = limit
        self.data = bytearray()
        self.stream = None
        self._open()

    def _open(self):
        """Truncate the current segment privately and append to it in place."""
        if self.stream is not None:
            self.stream.close()
        atomic(self.current, "")
        fd = os.open(str(self.current), os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
        self.stream = os.fdopen(fd, "ab", buffering=0)
        self.data = bytearray()

    def write(self, text):
        pending = text.encode("utf-8")
        while pending:
            size = self.limit - len(self.data)
            part = pending[:size].decode("utf-8", errors="ignore").encode("utf-8")
            if not part:
                marker = b"[older stderr truncated]\n"
                tail = bytes(self.data[-(self.limit - len(marker)):]).decode("utf-8", errors="ignore")
                atomic(self.previous, marker.decode() + tail)
                self._open()
                continue
            self.stream.write(part)
            self.data += part
            pending = pending[len(part):]


def collect(source, writer, finish_timeout=1.0, queue_bytes=8 * 1024 * 1024):
    """Drain SOURCE despite failed/stalled WRITER or factory; report losses.

    Text waiting for the writer is bounded by QUEUE_BYTES of input, so a slow
    writer start or a stalled disk can neither grow memory nor block the pipe
    reader.  Input beyond that bound is dropped and counted.
    """
    chunks = queue.Queue()
    finished = threading.Event()
    lock = threading.Lock()
    queued = [0]
    result = {"complete": True, "queue_dropped_bytes": 0, "writer_error": None,
              "encoding": "UTF-8; invalid input replaced"}

    def write_chunks():
        try:
            sink = writer() if callable(writer) else writer
        except Exception as error:
            result["writer_error"] = str(error)
        while not finished.is_set() or not chunks.empty():
            try:
                size, text = chunks.get(timeout=0.05)
            except queue.Empty:
                continue
            # Coalesce everything already queued into one write, so many
            # small pipe reads cost one disk append rather than one each.
            parts = [text]
            while True:
                try:
                    more, text = chunks.get_nowait()
                except queue.Empty:
                    break
                parts.append(text)
                size += more
            with lock:
                queued[0] -= size
            if result["writer_error"] is None:
                try:
                    sink.write("".join(parts))
                except Exception as error:
                    result["writer_error"] = str(error)

    worker = threading.Thread(target=write_chunks, daemon=True)
    worker.start()
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def enqueue(text):
        if text:
            size = len(text.encode("utf-8"))
            with lock:
                if queued[0] + size > queue_bytes:
                    result["queue_dropped_bytes"] += size
                    return
                queued[0] += size
            chunks.put((size, text))

    try:
        while True:
            data = source.read(65536)
            if not data:
                break
            enqueue(decoder.decode(data))
        enqueue(decoder.decode(b"", final=True))
    finally:
        finished.set()
        worker.join(finish_timeout)
    result["complete"] = not (worker.is_alive() or result["queue_dropped_bytes"] or result["writer_error"])
    return dict(result)


class ChildStderr:
    """Bound draining after child exit even if a descendant inherited stderr."""
    def __init__(self, child):
        self.child = child
        self.deadline = None
        self.eof = False

    def read(self, size):
        while True:
            if self.child.poll() is not None and self.deadline is None:
                self.deadline = time.monotonic() + 0.25
            if self.deadline is not None and time.monotonic() >= self.deadline:
                return b""
            ready, _, _ = select.select([self.child.stderr], [], [], 0.05)
            if ready:
                data = os.read(self.child.stderr.fileno(), size)
                self.eof = not data
                return data


def supervise(run, lock_fd):
    """Own the lock and child lifetime.  Never kill the child, even on failure."""
    spec = json.loads((run / "launch.json").read_text())
    env = dict(os.environ, MR_X_EMACS_RUN_ID=run.name,
               MR_X_EMACS_RUN_DIRECTORY=str(run))
    try:
        library = Path(spec["init_directory"]) / "lisp"
        child = subprocess.Popen([spec["emacs"], "--fg-daemon=" + spec["server"],
                                  "--init-directory", spec["init_directory"],
                                  "--directory", str(library), "--load", "mr-x-crash-runtime",
                                  "--funcall", "mr-x/crash-runtime-arm"],
                                 env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                 bufsize=0)
    except OSError as error:
        atomic(run / "stderr-status.json", json.dumps({"state": "finished", "complete": False,
               "launch_error": str(error), "exit_code": None}))
        return
    # All disk writes during child lifetime belong to the writer thread.
    # The initial incomplete marker already exists before Popen.
    source = ChildStderr(child)
    result = collect(source, lambda: RotatingLog(run))
    if not source.eof:
        result.update(complete=False, pipe_error="stderr remained open after daemon exit")
    child.stderr.close()
    result.update(state="finished", exit_code=child.wait())
    atomic(run / "stderr-status.json", json.dumps(result))
    os.close(lock_fd)


def probe(client, server, expression, timeout):
    return subprocess.run([client, "--socket-name=" + server, "--eval", expression],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, timeout=timeout)


def start(args):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.server) or args.server in (".", ".."):
        raise ValueError("Server must be an explicit socket basename")
    if not 0 < args.timeout <= 300:
        raise ValueError("Timeout must be greater than zero and at most 300 seconds")
    init = Path(args.init_directory).expanduser().resolve(strict=True)
    if not init.is_dir():
        raise ValueError("Init directory must exist")
    locks = (Path(args.runtime_directory).expanduser() if args.runtime_directory else
             Path("/tmp") / ("emacs-diagnostic-start-%s" % os.getuid()))
    private_directory(locks)
    lock = locks / (hashlib.sha256(args.server.encode()).hexdigest() + ".lock")
    fd = os.open(str(lock), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if probe(args.emacsclient, args.server, "t", min(args.timeout, 2)).returncode == 0:
            raise ValueError("Named server already responds; refusing another launch")
        parent = init
        for name in ("var", "crash-recovery", "runs"):
            parent /= name
            private_directory(parent)
        run = create_run(parent, args.server, init)
        atomic(run / "launch.json", json.dumps({"emacs": args.emacs, "server": args.server,
                                                "init_directory": str(init)}))
        # The inherited flock prevents concurrent starts, including after a
        # readiness timeout.  It remains held until the foreground child exits.
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--supervise", str(run),
                          "--lock-fd", str(fd)], pass_fds=(fd,), start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        os.close(fd)
    expression = ('(if (and (equal (getenv "MR_X_EMACS_RUN_ID") %s) '
                  '(equal (getenv "MR_X_EMACS_RUN_DIRECTORY") %s) '
                  '(equal server-name %s) (equal (file-truename user-emacs-directory) %s) '
                  '(bound-and-true-p mr-x/crash-runtime--identity) '
                  '(equal (plist-get mr-x/crash-runtime--identity :run-id) (getenv "MR_X_EMACS_RUN_ID")) '
                  '(equal (plist-get mr-x/crash-runtime--identity :pid) (emacs-pid))) '
                  '(number-to-string (emacs-pid)) nil)') % (
                      lisp_string(run.name), lisp_string(run), lisp_string(args.server),
                      lisp_string(str(init) + os.sep))
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        try:
            response = probe(args.emacsclient, args.server, expression,
                             min(1, max(0.01, deadline - time.monotonic())))
            if response.returncode == 0:
                value = json.loads(response.stdout)
                if isinstance(value, str) and value.isdigit() and int(value) > 0:
                    print(json.dumps({"status": "ready", "pid": int(value), "run_directory": str(run)}))
                    return 0
        except (subprocess.TimeoutExpired, ValueError):
            pass
        status = json.loads((run / "stderr-status.json").read_text())
        if status["state"] == "finished":
            break
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    print(json.dumps({"status": "not-ready", "run_directory": str(run)}))
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server")
    parser.add_argument("--init-directory")
    parser.add_argument("--emacs", default="/opt/homebrew/opt/emacs-plus@30/bin/emacs")
    parser.add_argument("--emacsclient", default="/opt/homebrew/opt/emacs-plus@30/bin/emacsclient")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--runtime-directory", help="Shared private lock directory; all callers must agree")
    parser.add_argument("--supervise", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--lock-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.supervise:
        supervise(args.supervise, args.lock_fd)
        return 0
    if not args.server or not args.init_directory:
        parser.error("--server and --init-directory are required")
    try:
        return start(args)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("Daemon launch refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
