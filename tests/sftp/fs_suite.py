#!/usr/bin/env python3
"""Differential file system tests for sshocker's rooted SFTP server, through real sshfs.

    fs_suite.py <harness binary> <workdir> [case-substring...]

<harness binary> is a build.sh harness, or openssh_harness.sh as a control.
<workdir> must be on the VM's own disk. Each case runs once in <workdir>/mnt
(sshfs served by the harness from <workdir>/host) and once in <workdir>/ref (a
plain directory). Reported per case:
  CRASH   the server died during the case (in Lima: the hostagent and the vz VM)
  HANG    the case did not finish in time
  DIFF    results or the resulting tree differ from the plain directory
  FDLEAK  the server holds more fds after the case than before
  ok      same as the plain directory
SFTP v3 cannot express everything POSIX can: many DIFFs are expected, triage them.
"""
import ctypes
import errno
import fcntl
import hashlib
import mmap
import multiprocessing as mp
import os
import random
import shutil
import stat
import subprocess
import sys
import threading
import time

CASE_TIMEOUT = 60
CASES = []


def case(fn):
    CASES.append(fn)
    return fn


def op(f, *a, **kw):
    """('ok', value) or ('err', errno name), comparable between the two runs."""
    try:
        v = f(*a, **kw)
        if isinstance(v, os.stat_result):  # inode and device numbers differ between file systems
            return ("ok", ("stat", stat.filemode(v.st_mode), v.st_nlink, v.st_size))
        return ("ok", v if isinstance(v, (int, str, bytes, bool, type(None), tuple)) else type(v).__name__)
    except OSError as e:
        return ("err", errno.errorcode.get(e.errno, str(e.errno)))


def wfile(p, data, mode=0o644):
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def rfile(p):
    with open(p, "rb") as f:
        return f.read()


def mode_of(p):
    return oct(stat.S_IMODE(os.lstat(p).st_mode))


# ---------------------------------------------------------------- open flags and appends

@case
def append_existing_wronly(d):
    wfile(f"{d}/f", b"head\n")
    fd = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND)
    r = [op(os.write, fd, b"tail\n")]
    os.close(fd)
    return r + [rfile(f"{d}/f")]


@case
def append_new_file(d):
    fd = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    r = [op(os.write, fd, b"x")]
    os.close(fd)
    return r + [rfile(f"{d}/f"), mode_of(f"{d}/f")]


@case
def append_rdwr(d):
    wfile(f"{d}/f", b"abc")
    fd = os.open(f"{d}/f", os.O_RDWR | os.O_APPEND)
    r = [op(os.write, fd, b"def"), op(os.pread, fd, 6, 0)]
    os.close(fd)
    return r


@case
def append_after_seek(d):
    # O_APPEND must write at the end whatever the file position
    wfile(f"{d}/f", b"0123456789")
    fd = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND)
    os.lseek(fd, 0, os.SEEK_SET)
    r = [op(os.write, fd, b"X")]
    os.close(fd)
    return r + [rfile(f"{d}/f")]


@case
def append_two_fds_interleaved(d):
    wfile(f"{d}/f", b"")
    a = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND)
    b = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND)
    for i in range(20):
        os.write(a if i % 2 == 0 else b, b"%02d\n" % i)
    os.close(a)
    os.close(b)
    return [rfile(f"{d}/f")]


@case
def append_shell_redirect(d):
    wfile(f"{d}/f", b"header\n")
    r = subprocess.run(["bash", "-c", "printf 'a\\n' >> f && seq 1 500 >> f && echo z >> f"], cwd=d)
    return [r.returncode, hashlib.sha256(rfile(f"{d}/f")).hexdigest()]


@case
def append_after_host_change(d):
    # The host (here: the other side of the share) grows the file, then the guest appends.
    # Through sshfs's attribute cache the guest may append at the old end and overwrite.
    wfile(f"{d}/f", b"guest1\n")
    os.stat(f"{d}/f")
    host = HOST_OF(d)
    with open(f"{host}/f", "ab") as f:
        f.write(b"host-wrote-this-line\n")
    fd = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND)
    os.write(fd, b"guest2\n")
    os.close(fd)
    return [rfile(f"{host}/f")]


@case
def open_flag_matrix(d):
    out = []
    flags = {"RDONLY": os.O_RDONLY, "WRONLY": os.O_WRONLY, "RDWR": os.O_RDWR}
    extra = {"": 0, "CREAT": os.O_CREAT, "TRUNC": os.O_TRUNC, "CREAT|EXCL": os.O_CREAT | os.O_EXCL,
             "CREAT|TRUNC": os.O_CREAT | os.O_TRUNC, "APPEND": os.O_APPEND,
             "APPEND|TRUNC": os.O_APPEND | os.O_TRUNC, "CREAT|APPEND|EXCL": os.O_CREAT | os.O_APPEND | os.O_EXCL}
    for an, a in flags.items():
        for en, e in extra.items():
            for target in ["exists", "new"]:
                p = f"{d}/{an}_{en.replace('|', '_')}_{target}"
                if target == "exists":
                    wfile(p, b"orig")
                r = op(os.open, p, a | e, 0o600)
                if r[0] == "ok":
                    fd = r[1]
                    out.append((an, en, target, "open ok", op(os.write, fd, b"W"), op(os.pread, fd, 8, 0)))
                    os.close(fd)
                else:
                    out.append((an, en, target, r))
                if os.path.exists(p):
                    out.append((an, en, target, rfile(p), mode_of(p)))
    return out


@case
def create_modes(d):
    old = os.umask(0)
    try:
        out = []
        for m in [0o755, 0o700, 0o644, 0o600, 0o444, 0o000, 0o4755, 0o2755, 0o1777]:
            p = f"{d}/m{m:o}"
            out.append((oct(m), op(os.close, os.open(p, os.O_WRONLY | os.O_CREAT, m)), mode_of(p)))
        for m in [0o755, 0o700, 0o1777, 0o000]:
            p = f"{d}/d{m:o}"
            out.append(("dir", oct(m), op(os.mkdir, p, m), mode_of(p)))
            os.chmod(p, 0o755)
        return out
    finally:
        os.umask(old)


# ---------------------------------------------------------------- sizes, holes, big files

@case
def truncate_grow_shrink(d):
    wfile(f"{d}/f", b"0123456789")
    r = [op(os.truncate, f"{d}/f", 4), rfile(f"{d}/f"), op(os.truncate, f"{d}/f", 12), rfile(f"{d}/f")]
    fd = os.open(f"{d}/f", os.O_RDWR)
    r += [op(os.ftruncate, fd, 2), op(os.pread, fd, 20, 0)]
    os.close(fd)
    return r + [op(os.truncate, f"{d}/f", 0), rfile(f"{d}/f")]


@case
def truncate_after_chmod_readonly(d):
    wfile(f"{d}/f", b"0123456789")
    fd = os.open(f"{d}/f", os.O_RDWR)
    os.chmod(f"{d}/f", 0o444)
    r = [op(os.ftruncate, fd, 3), op(os.write, fd, b"ab")]
    os.close(fd)
    os.chmod(f"{d}/f", 0o644)
    return r + [rfile(f"{d}/f")]


@case
def sparse_write(d):
    fd = os.open(f"{d}/f", os.O_RDWR | os.O_CREAT, 0o644)
    r = [op(os.pwrite, fd, b"end", 1 << 30), op(os.pread, fd, 4, 100), os.fstat(fd).st_size,
         os.stat(f"{d}/f").st_size, op(os.pread, fd, 3, 1 << 30)]
    os.ftruncate(fd, 0)
    os.close(fd)
    return r


@case
def huge_offsets(d):
    fd = os.open(f"{d}/f", os.O_RDWR | os.O_CREAT, 0o644)
    r = []
    for off in [(1 << 40), (1 << 62), (1 << 63) - 2]:
        r.append((off, op(os.pwrite, fd, b"x", off)))
        r.append((off, op(os.pread, fd, 1, off)))
    r.append(op(os.ftruncate, fd, (1 << 62)))
    r.append(os.stat(f"{d}/f").st_size)
    os.ftruncate(fd, 0)
    os.close(fd)
    return r


@case
def big_file_roundtrip(d):
    data = random.Random(1).randbytes(1 << 20) * 64
    wfile(f"{d}/f", data)
    return [hashlib.sha256(rfile(f"{d}/f")).hexdigest() == hashlib.sha256(data).hexdigest()]


@case
def write_read_unaligned(d):
    fd = os.open(f"{d}/f", os.O_RDWR | os.O_CREAT, 0o644)
    blob = bytes(range(256)) * 1000
    for off in [0, 1, 4095, 4096, 65535, 131071, 200001]:
        os.pwrite(fd, blob[:off % 7919 + 1], off)
    os.close(fd)
    return [hashlib.sha256(rfile(f"{d}/f")).hexdigest()]


@case
def concurrent_region_writes(d):
    wfile(f"{d}/f", b"\0" * (64 * 65536))

    def w(i):
        fd = os.open(f"{d}/f", os.O_WRONLY)
        for k in range(16):
            os.pwrite(fd, bytes([i]) * 4096, i * 65536 + k * 4096)
        os.close(fd)
    ts = [threading.Thread(target=w, args=(i,)) for i in range(64)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    return [hashlib.sha256(rfile(f"{d}/f")).hexdigest()]


@case
def concurrent_appends(d):
    wfile(f"{d}/f", b"")

    def w(i):
        fd = os.open(f"{d}/f", os.O_WRONLY | os.O_APPEND)
        for k in range(50):
            os.write(fd, b"%03d-%03d\n" % (i, k))
        os.close(fd)
    ts = [threading.Thread(target=w, args=(i,)) for i in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    lines = rfile(f"{d}/f").splitlines()
    os.unlink(f"{d}/f")  # line order depends on thread scheduling
    return [len(lines), len(set(lines))]


# ---------------------------------------------------------------- request ordering
# pkg/sftp's RequestServer runs reads and writes on parallel workers, and everything
# else on another one: without WithRSSequential these come out wrong most of the time.

@case
def order_rewrite_same_block(d):
    bad = 0
    for i in range(100):
        fd = os.open(f"{d}/w{i}", os.O_RDWR | os.O_CREAT, 0o644)
        for k in range(8):
            os.pwrite(fd, bytes([65 + k]) * 4096, 0)
        os.close(fd)
        if rfile(f"{HOST_OF(d)}/w{i}") != b"H" * 4096:
            bad += 1
        os.unlink(f"{d}/w{i}")
    return [("host files with an older write last", bad)]


@case
def order_write_then_ftruncate(d):
    bad = 0
    for i in range(100):
        fd = os.open(f"{d}/t{i}", os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
        os.write(fd, b"hello world")
        os.ftruncate(fd, 2)
        os.close(fd)
        if rfile(f"{HOST_OF(d)}/t{i}") != b"he":
            bad += 1
        os.unlink(f"{d}/t{i}")
    return [("host files not truncated", bad)]


@case
def order_write_then_fstat_and_read(d):
    bad_size = bad_read = 0
    for i in range(100):
        fd = os.open(f"{d}/s{i}", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        os.write(fd, b"x" * 100)
        if os.fstat(fd).st_size != 100:
            bad_size += 1
        os.close(fd)
        if rfile(f"{d}/s{i}") != b"x" * 100:
            bad_read += 1
        os.unlink(f"{d}/s{i}")
    return [("fstat size wrong", bad_size), ("read back wrong", bad_read)]


# ---------------------------------------------------------------- metadata

@case
def chmod_matrix(d):
    wfile(f"{d}/f", b"x")
    out = []
    for m in [0o000, 0o200, 0o400, 0o755, 0o4755, 0o7777, 0o644]:
        out.append((oct(m), op(os.chmod, f"{d}/f", m), mode_of(f"{d}/f")))
    os.mkdir(f"{d}/dir")
    out.append(("dir 000", op(os.chmod, f"{d}/dir", 0)))
    out.append(("create in 000 dir", op(wfile, f"{d}/dir/x", b"")))
    out.append(("list 000 dir", op(os.listdir, f"{d}/dir")))
    os.chmod(f"{d}/dir", 0o755)
    return out


@case
def unreadable_file(d):
    wfile(f"{d}/f", b"secret")
    os.chmod(f"{d}/f", 0)
    r = [op(rfile, f"{d}/f"), op(wfile, f"{d}/f", b"x")]
    os.chmod(f"{d}/f", 0o644)
    return r


@case
def chown_ops(d):
    wfile(f"{d}/f", b"x")
    me = os.getuid(), os.getgid()
    return [op(os.chown, f"{d}/f", -1, -1), op(os.chown, f"{d}/f", 0, 0), op(os.chown, f"{d}/f", 12345, 12345)
            ] + [os.stat(f"{d}/f").st_uid == me[0]]


@case
def utimes_ranges(d):
    wfile(f"{d}/f", b"x")
    out = []
    for ns in [1_500_000_000_123_456_789, 0, -86400 * 10**9, 2**31 * 10**9, (2**32 + 5) * 10**9, 4_000_000_000 * 10**9]:
        r = op(os.utime, f"{d}/f", ns=(ns, ns))
        st = os.stat(f"{d}/f")
        out.append((ns, r, st.st_mtime_ns, st.st_atime_ns))
    return out


@case
def utime_now_and_touch(d):
    wfile(f"{d}/f", b"x")
    os.utime(f"{d}/f", (1, 1))
    r = [op(os.utime, f"{d}/f", None)]
    return r + [abs(os.stat(f"{d}/f").st_mtime - time.time()) < 5,
                subprocess.run(["touch", "-d", "1960-01-01", f"{d}/f"]).returncode, os.stat(f"{d}/f").st_mtime]


@case
def utime_symlink_nofollow(d):
    wfile(f"{d}/f", b"x")
    os.symlink("f", f"{d}/l")
    os.utime(f"{d}/f", (1000, 1000))
    r = [op(os.utime, f"{d}/l", (5000, 5000), follow_symlinks=False)]
    return r + [os.stat(f"{d}/f").st_mtime, os.lstat(f"{d}/l").st_mtime]


@case
def stat_while_writing(d):
    fd = os.open(f"{d}/f", os.O_WRONLY | os.O_CREAT, 0o644)
    os.write(fd, b"x" * 10000)
    r = [os.stat(f"{d}/f").st_size, os.fstat(fd).st_size]
    os.close(fd)
    return r + [os.stat(f"{d}/f").st_size]


@case
def statvfs_root(d):
    st = os.statvfs(d)
    return [st.f_bsize > 0, st.f_namemax]


# ---------------------------------------------------------------- names and directories

@case
def rename_matrix(d):
    out = []
    wfile(f"{d}/a", b"a")
    wfile(f"{d}/b", b"b")
    out.append(("file->new", op(os.rename, f"{d}/a", f"{d}/c")))
    out.append(("file->existing", op(os.rename, f"{d}/c", f"{d}/b")))
    out.append(("content", rfile(f"{d}/b")))
    out.append(("replace", op(os.replace, f"{d}/b", f"{d}/b2")))
    os.makedirs(f"{d}/d1/sub")
    os.makedirs(f"{d}/d2")
    os.makedirs(f"{d}/d3/x")
    out.append(("dir->empty dir", op(os.rename, f"{d}/d1", f"{d}/d2")))
    out.append(("dir->nonempty dir", op(os.rename, f"{d}/d2", f"{d}/d3")))
    out.append(("dir->own child", op(os.rename, f"{d}/d3", f"{d}/d3/x/y")))
    out.append(("file->dir", op(os.rename, f"{d}/b2", f"{d}/d3")))
    out.append(("dir->file", op(os.rename, f"{d}/d3", f"{d}/b2")))
    out.append(("missing", op(os.rename, f"{d}/nope", f"{d}/x")))
    out.append(("same", op(os.rename, f"{d}/b2", f"{d}/b2")))
    wfile(f"{d}/h1", b"h")
    os.link(f"{d}/h1", f"{d}/h2")
    out.append(("hardlinks same inode", op(os.rename, f"{d}/h1", f"{d}/h2"), sorted(os.listdir(d))))
    return out


@case
def renameat2_flags(d):
    libc = ctypes.CDLL(None, use_errno=True)
    out = []
    for name, flags in [("NOREPLACE", 1), ("EXCHANGE", 2)]:
        wfile(f"{d}/x", b"x")
        wfile(f"{d}/y", b"y")
        rc = libc.renameat2(-100, f"{d}/x".encode(), -100, f"{d}/y".encode(), flags)
        out.append((name, rc, errno.errorcode.get(ctypes.get_errno(), 0) if rc else "",
                    op(rfile, f"{d}/x"), op(rfile, f"{d}/y")))
    return out


@case
def links(d):
    wfile(f"{d}/f", b"x")
    out = [op(os.link, f"{d}/f", f"{d}/h"), os.stat(f"{d}/f").st_nlink,
           op(os.symlink, "f", f"{d}/rel"), op(os.symlink, f"{d}/f", f"{d}/abs"),
           op(os.symlink, "missing", f"{d}/dangling"), op(os.symlink, "a" * 4000, f"{d}/longtarget"),
           op(os.symlink, "f", f"{d}/rel"), op(os.readlink, f"{d}/rel"), op(rfile, f"{d}/rel"),
           op(rfile, f"{d}/dangling"), op(os.readlink, f"{d}/longtarget"),
           op(os.link, f"{d}/rel", f"{d}/hardlink_to_symlink"), op(os.link, d, f"{d}/dirlink")]
    os.mkdir(f"{d}/sub")
    out += [op(os.symlink, "../f", f"{d}/sub/up"), op(rfile, f"{d}/sub/up")]
    out += [op(os.symlink, "self", f"{d}/self"), op(rfile, f"{d}/self")]
    return out


@case
def dir_ops(d):
    os.mkdir(f"{d}/x")
    wfile(f"{d}/x/f", b"")
    wfile(f"{d}/file", b"")
    return [op(os.mkdir, f"{d}/x"), op(os.rmdir, f"{d}/x"), op(os.rmdir, f"{d}/file"),
            op(os.unlink, f"{d}/x"), op(os.mkdir, f"{d}/file/sub"), op(os.rmdir, f"{d}/x/."),
            op(os.mkdir, f"{d}/missing/sub"), op(os.listdir, f"{d}/file")]


@case
def names(d):
    out = []
    for n in ["café", "café", "😀", "a b", " lead", "trail ", "new\nline", "tab\t", "back\\slash",
              "co:lon", "q?uest", "star*", "pipe|", "lt<gt>", "dquote\"", "%25", "-dash", "~tilde",
              "x" * 255, "y" * 256, "\x01ctl", "\x7f", "\udcff".encode("utf-8", "surrogateescape").decode("utf-8", "surrogateescape")]:
        p = f"{d}/{n}"
        r = op(wfile, p, n.encode("utf-8", "surrogateescape"))
        out.append((repr(n)[:40], r, op(rfile, p) if r[0] == "ok" else None))
    raw = os.fsencode(d) + b"/\xff\xfe-invalid-utf8"
    r = op(wfile, raw, b"bin")
    out.append(("invalid utf8", r))
    out.append(sorted(os.listdir(d)))
    return out


@case
def deep_path(d):
    p = d
    out = []
    for i in range(60):
        p = f"{p}/{'d' * 60}"
        r = op(os.mkdir, p)
        if r[0] != "ok":
            out.append((i, len(p), r))
            break
    out.append(op(wfile, f"{p}/leaf", b"x"))
    return out


@case
def big_directory(d):
    for i in range(3000):
        wfile(f"{d}/f{i:05d}", b"")
    names = os.listdir(d)
    r = [len(names), len(set(names))]
    with os.scandir(d) as it:
        r.append(sum(1 for e in it if e.is_file()))
    for i in range(0, 3000, 2):
        os.unlink(f"{d}/f{i:05d}")
    return r + [len(os.listdir(d))]


@case
def readdir_while_modifying(d):
    for i in range(500):
        wfile(f"{d}/f{i}", b"")
    seen = []
    with os.scandir(d) as it:
        for k, e in enumerate(it):
            seen.append(e.name)
            if k == 10:
                for j in range(500, 600):
                    wfile(f"{d}/f{j}", b"")
                for j in range(0, 100):
                    os.unlink(f"{d}/f{j}")
    return [len(os.listdir(d)), len(seen) > 0]


# ---------------------------------------------------------------- lifecycle of open files

@case
def unlink_open_file(d):
    wfile(f"{d}/f", b"data")
    fd = os.open(f"{d}/f", os.O_RDWR)
    os.unlink(f"{d}/f")
    r = [op(os.pread, fd, 4, 0), op(os.pwrite, fd, b"more", 4), op(os.fstat, fd)]
    os.close(fd)
    return r + [sorted(os.listdir(d))]


@case
def rename_open_file(d):
    wfile(f"{d}/f", b"data")
    fd = os.open(f"{d}/f", os.O_RDWR)
    os.rename(f"{d}/f", f"{d}/g")
    r = [op(os.pwrite, fd, b"X", 0), op(os.fchmod, fd, 0o600), op(os.ftruncate, fd, 2)]
    wfile(f"{d}/f", b"new file at old path")
    r += [op(os.fchmod, fd, 0o640), op(os.ftruncate, fd, 1), op(os.fstat, fd)]
    os.close(fd)
    return r + [rfile(f"{d}/g"), rfile(f"{d}/f"), mode_of(f"{d}/f"), mode_of(f"{d}/g")]


@case
def replace_open_file_atomic_save(d):
    # editor-style atomic save while a reader holds the old file
    wfile(f"{d}/f", b"v1")
    fd = os.open(f"{d}/f", os.O_RDONLY)
    wfile(f"{d}/.f.tmp", b"v2-longer")
    os.replace(f"{d}/.f.tmp", f"{d}/f")
    r = [op(os.pread, fd, 20, 0)]
    os.close(fd)
    return r + [rfile(f"{d}/f")]


@case
def many_open_fds(d):
    fds = []
    for i in range(1500):
        fds.append(os.open(f"{d}/f{i}", os.O_RDWR | os.O_CREAT, 0o644))
    for fd in fds:
        os.write(fd, b"x")
    for fd in fds:
        os.close(fd)
    return [len(os.listdir(d))]


@case
def fsync_and_friends(d):
    fd = os.open(f"{d}/f", os.O_RDWR | os.O_CREAT, 0o644)
    os.write(fd, b"x" * 100)
    r = [op(os.fsync, fd), op(os.fdatasync, fd), op(os.posix_fallocate, fd, 0, 1 << 20),
         op(os.posix_fadvise, fd, 0, 0, os.POSIX_FADV_DONTNEED)]
    r.append(os.fstat(fd).st_size)
    os.close(fd)
    dfd = os.open(d, os.O_RDONLY)
    r.append(op(os.fsync, dfd))
    os.close(dfd)
    return r


@case
def locks(d):
    wfile(f"{d}/f", b"x")
    fd = os.open(f"{d}/f", os.O_RDWR)
    r = [op(fcntl.flock, fd, fcntl.LOCK_EX | fcntl.LOCK_NB), op(fcntl.lockf, fd, fcntl.LOCK_EX | fcntl.LOCK_NB)]
    os.close(fd)
    return r


@case
def mmap_write(d):
    wfile(f"{d}/f", b"\0" * 8192)
    fd = os.open(f"{d}/f", os.O_RDWR)
    try:
        m = mmap.mmap(fd, 8192)
        m[100:105] = b"hello"
        m.flush()
        m.close()
        r = ["mapped"]
    except OSError as e:
        r = [("err", errno.errorcode.get(e.errno))]
    os.close(fd)
    return r + [rfile(f"{d}/f")[100:105]]


@case
def special_files(d):
    return [op(os.mkfifo, f"{d}/fifo"), op(os.mknod, f"{d}/node", 0o600 | stat.S_IFREG),
            op(os.open, d, os.O_TMPFILE | os.O_RDWR, 0o600),
            op(os.setxattr, d, "user.k", b"v"), op(os.listxattr, d)]


@case
def copy_paths(d):
    data = random.Random(2).randbytes(300000)
    wfile(f"{d}/src", data)
    s = os.open(f"{d}/src", os.O_RDONLY)
    t = os.open(f"{d}/dst", os.O_WRONLY | os.O_CREAT, 0o644)
    r = [op(os.copy_file_range, s, t, len(data))]
    t2 = os.open(f"{d}/dst2", os.O_WRONLY | os.O_CREAT, 0o644)
    r.append(op(os.sendfile, t2, s, 0, len(data)))
    for fd in (s, t, t2):
        os.close(fd)
    return r + [rfile(f"{d}/dst") == data, rfile(f"{d}/dst2") == data]


# ---------------------------------------------------------------- tool workloads

@case
def tool_tar_roundtrip(d):
    src = f"{d}/src"
    os.makedirs(f"{src}/a/b")
    wfile(f"{src}/a/b/x.sh", b"#!/bin/sh\n", 0o755)
    wfile(f"{src}/a/y", b"y" * 5000)
    os.symlink("b/x.sh", f"{src}/a/link")
    os.utime(f"{src}/a/y", (1_000_000_000, 1_000_000_000))
    r = subprocess.run(f"tar -C {src} -cf - . | (mkdir {d}/out && tar -C {d}/out -xpf -)", shell=True,
                       capture_output=True)
    return [r.returncode, r.stderr[-300:]]


@case
def tool_cp_a_and_rm_rf(d):
    src = f"{d}/src"
    for i in range(30):
        os.makedirs(f"{src}/d{i}/e")
        wfile(f"{src}/d{i}/e/f", b"%d" % i, 0o640)
    r1 = subprocess.run(["cp", "-a", src, f"{d}/copy"], capture_output=True)
    r2 = subprocess.run(["rm", "-rf", src], capture_output=True)
    return [r1.returncode, r1.stderr[-300:], r2.returncode, r2.stderr[-300:]]


@case
def tool_patch_and_sed_inplace(d):
    wfile(f"{d}/f", b"one\ntwo\nthree\n")
    wfile(f"{d}/p", b"--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n")
    r1 = subprocess.run(["patch", "-p1", "-i", "p"], cwd=d, capture_output=True)
    r2 = subprocess.run(["sed", "-i", "s/one/ONE/", "f"], cwd=d, capture_output=True)
    return [r1.returncode, r2.returncode, r2.stderr[-200:]]


@case
def tool_git_worktree_outside_dotgit(d):
    # .git is read-only on the share by design: keep the repository elsewhere, work tree here
    gd = f"{SCRATCH}/gitdir-{os.path.basename(os.path.dirname(d))}-{os.getpid()}"
    shutil.rmtree(gd, ignore_errors=True)
    env = dict(os.environ, GIT_DIR=gd, GIT_WORK_TREE=d, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    for i in range(50):
        wfile(f"{d}/f{i}", b"%d\n" % i)
    cmds = ["git init -q", "git add -A", "git commit -qm one", "git rm -q f1", "git mv f2 g2",
            "git commit -qam two", "git checkout -q HEAD~1 -- .", "git status --porcelain"]
    out = []
    for c in cmds:
        r = subprocess.run(c, shell=True, cwd=d, env=env, capture_output=True)
        out.append((c, r.returncode, r.stderr[-200:]))
    shutil.rmtree(gd, ignore_errors=True)
    return out


@case
def tool_python_logging_append(d):
    code = ("import logging; logging.basicConfig(filename='app.log', filemode='a', level=10); "
            "[logging.info('line %d', i) for i in range(200)]")
    r = subprocess.run([sys.executable, "-c", code], cwd=d, capture_output=True)
    return [r.returncode, len(rfile(f"{d}/app.log").splitlines()) if os.path.exists(f"{d}/app.log") else None]


# ---------------------------------------------------------------- runner

def snapshot(base):
    snap = {}
    for dirpath, dirnames, filenames in os.walk(base):
        for n in sorted(dirnames + filenames):
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            entry = [stat.filemode(st.st_mode), st.st_nlink if stat.S_ISREG(st.st_mode) else 0]
            if stat.S_ISREG(st.st_mode):
                entry.append(st.st_size)
                if st.st_size > 256 << 20:
                    entry.append("not hashed")
                else:
                    try:
                        with open(p, "rb") as f:
                            entry.append(hashlib.sha256(f.read()).hexdigest()[:16])
                    except OSError as e:
                        entry.append(errno.errorcode.get(e.errno))
            elif stat.S_ISLNK(st.st_mode):
                entry.append(os.readlink(p))
            snap[os.path.relpath(p, base)] = entry
    return snap


def norm(v, d):
    """Replaces the case directory with <d> in reported values."""
    if isinstance(v, (list, tuple)):
        return type(v)(norm(x, d) for x in v)
    if isinstance(v, str):
        return v.replace(d, "<d>")
    if isinstance(v, bytes):
        return v.replace(os.fsencode(d), b"<d>")
    return v


def _child(fn, d, q):
    try:
        q.put(("done", norm(fn(d), d)))
    except Exception as e:  # noqa: BLE001
        q.put(("exception", f"{type(e).__name__}: {e}"))


def run_case(fn, d):
    q = mp.Queue()
    p = mp.Process(target=_child, args=(fn, d, q))
    p.start()
    p.join(CASE_TIMEOUT)
    if p.is_alive():
        p.kill()
        p.join()
        return ("hang", None)
    try:
        return q.get(timeout=5)
    except Exception:  # noqa: BLE001
        return ("no result", p.exitcode)


class Harness:
    def __init__(self, binary, host, mnt, log):
        self.binary, self.host, self.mnt, self.log = binary, host, mnt, log
        self.p = None

    def start(self):
        subprocess.run(["fusermount", "-u", "-z", self.mnt], capture_output=True)
        self.logf = open(self.log, "ab")
        self.p = subprocess.Popen([self.binary, "mount", self.host, self.mnt], stderr=self.logf, stdout=self.logf)
        for _ in range(100):
            if os.path.ismount(self.mnt):
                return
            time.sleep(0.05)
        raise RuntimeError("mount did not come up")

    def alive(self):
        return self.p.poll() is None and os.path.ismount(self.mnt)

    def fds(self):
        try:
            return len(os.listdir(f"/proc/{self.p.pid}/fd"))
        except OSError:
            return -1

    def stop(self):
        subprocess.run(["fusermount", "-u", "-z", self.mnt], capture_output=True)
        if self.p and self.p.poll() is None:
            self.p.kill()
        if self.p:
            self.p.wait()
        self.logf.close()


def main():
    global SCRATCH, HOST_OF
    binary, work = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    filters = sys.argv[3:]
    host, mnt, ref, SCRATCH = (os.path.join(work, x) for x in ("host", "mnt", "ref", "scratch"))
    log = os.path.join(work, "harness.log")
    subprocess.run(["fusermount", "-u", "-z", mnt], capture_output=True)
    for x in (host, ref, SCRATCH):
        shutil.rmtree(x, ignore_errors=True)
    for x in (host, mnt, ref, SCRATCH):
        os.makedirs(x, exist_ok=True)
    open(log, "wb").close()
    HOST_OF = lambda d: d.replace(mnt, host, 1) if d.startswith(mnt) else d  # noqa: E731
    h = Harness(binary, host, mnt, log)
    h.start()
    print(f"# {binary}\n")
    counts = {}
    for fn in CASES:
        name = fn.__name__
        if filters and not any(f in name for f in filters):
            continue
        for x in (f"{mnt}/{name}", f"{ref}/{name}"):
            os.makedirs(x)
        fds_before = h.fds()
        log_before = os.path.getsize(log)
        got = run_case(fn, f"{mnt}/{name}")
        crashed = not h.alive()
        want = run_case(fn, f"{ref}/{name}")
        status, detail = "ok", ""
        if crashed:
            status = "CRASH"
            with open(log, "rb") as f:
                f.seek(log_before)
                tail = f.read().decode(errors="replace")
            lines = tail.splitlines()
            at = next((lines[i + 1].strip() for i, l in enumerate(lines)
                       if "reversesshfs" in l and i + 1 < len(lines)), "")
            detail = (next((l for l in lines if l.startswith("panic") or "fatal error" in l), "server exited")
                      + f" at {at}")
            h.stop()
            h.start()
        elif got[0] == "hang":
            status = "HANG"
        else:
            snap_m, snap_r = snapshot(f"{host}/{name}"), snapshot(f"{ref}/{name}")
            if got != want or snap_m != snap_r:
                status = "DIFF"
                if got != want:
                    detail += f"\n    sshfs: {got}\n    local: {want}"
                for k in sorted(set(snap_m) | set(snap_r)):
                    if snap_m.get(k) != snap_r.get(k):
                        detail += f"\n    tree {k}: sshfs={snap_m.get(k)} local={snap_r.get(k)}"
            fds_after = h.fds()
            if fds_after > fds_before:
                status += f" FDLEAK({fds_before}->{fds_after})"
        counts[status.split()[0]] = counts.get(status.split()[0], 0) + 1
        print(f"{status:6} {name}{(': ' + detail) if detail else ''}", flush=True)
    h.stop()
    print(f"\n# {counts}")


if __name__ == "__main__":
    mp.set_start_method("fork")
    main()
