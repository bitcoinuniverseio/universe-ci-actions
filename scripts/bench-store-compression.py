#!/usr/bin/env python3
"""Benchmark zstd level x threads for the build and dependency stores.

Measures what a job actually pays: tar+zstd to an archive (save), and
zstd -d + tar extract into a fresh directory (restore), on a real payload.

  python3 scripts/bench-store-compression.py <dir> [<dir> ...]
  BENCH_LEVELS=1,3,6 BENCH_THREADS=1,2,4,0 BENCH_REPS=5 python3 ...
  BENCH_STREAM=1 python3 ...   # zstd alone on a pre-built tar stream

Stream mode isolates the compressor from filesystem walking and reports CPU
seconds (user+sys of the children), which is what competes for a shared host.

Prints one row per (payload, level, threads) with median and spread of each
phase, archive size and ratio. Run it on an idle host; it does not isolate
itself from other load.
"""
import os
import resource
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

levels = [int(x) for x in os.environ.get("BENCH_LEVELS", "1,3,6,9").split(",")]
threads = [int(x) for x in os.environ.get("BENCH_THREADS", "1,2,4,0").split(",")]
reps = int(os.environ.get("BENCH_REPS", "5"))


def du(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    return total


def timed(cmd, cwd):
    t = time.perf_counter()
    subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return time.perf_counter() - t


def fmt(samples):
    med = statistics.median(samples)
    spread = (max(samples) - min(samples)) if len(samples) > 1 else 0.0
    return f"{med * 1000:8.0f} ms ±{spread * 1000:5.0f}"


def cpu_timed(cmd, stdin, stdout):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    with open(stdin, "rb") as i, open(stdout, "wb") as o:
        subprocess.run(cmd, stdin=i, stdout=o, check=True)
    wall = time.perf_counter() - t
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return wall, (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)


if os.environ.get("BENCH_STREAM"):
    print(f"cpus={os.cpu_count()} reps={reps} mode=stream")
    print(f"{'payload':<14} {'lvl':>3} {'T':>2} {'save wall':>14} {'save cpu':>10} {'restore wall':>14} {'restore cpu':>11} {'ratio':>6}")
    for src in sys.argv[1:]:
        src = os.path.abspath(src)
        parent, name = os.path.split(src)
        work = tempfile.mkdtemp(prefix="bench-stream-")
        try:
            tarball = os.path.join(work, "in.tar")
            subprocess.run(["tar", "-cf", tarball, name], cwd=parent, check=True)
            raw = os.path.getsize(tarball)
            for level in levels:
                for t in threads:
                    zst, back = os.path.join(work, "o.zst"), os.path.join(work, "back.tar")
                    sw, sc, rw, rc = [], [], [], []
                    for _ in range(reps):
                        w, c = cpu_timed(["zstd", "-q", f"-{level}", f"-T{t}", "-c"], tarball, zst)
                        sw.append(w); sc.append(c)
                        w, c = cpu_timed(["zstd", "-q", "-d", "-c"], zst, back)
                        rw.append(w); rc.append(c)
                    med = statistics.median
                    print(f"{name[:14]:<14} {level:>3} {t:>2} {med(sw)*1000:9.0f} ms ±{(max(sw)-min(sw))*1000:3.0f} {med(sc):8.2f} s "
                          f"{med(rw)*1000:9.0f} ms ±{(max(rw)-min(rw))*1000:3.0f} {med(rc):9.2f} s {raw / os.path.getsize(zst):6.2f}", flush=True)
        finally:
            shutil.rmtree(work, ignore_errors=True)
    sys.exit(0)

print(f"cpus={os.cpu_count()} reps={reps}")
print(f"{'payload':<16} {'lvl':>3} {'T':>2} {'save (median ±range)':>22} {'restore':>22} {'bytes':>12} {'ratio':>6}")
for src in sys.argv[1:]:
    src = os.path.abspath(src)
    parent, name = os.path.split(src)
    raw = du(src)
    work = tempfile.mkdtemp(prefix="bench-store-")
    try:
        for level in levels:
            for t in threads:
                archive = os.path.join(work, "a.tar.zst")
                saves, restores = [], []
                for _ in range(reps):
                    if os.path.exists(archive):
                        os.remove(archive)
                    saves.append(timed(["tar", f"--use-compress-program=zstd -q -{level} -T{t}", "-cf", archive, name], parent))
                    out = os.path.join(work, "x")
                    shutil.rmtree(out, ignore_errors=True)
                    os.makedirs(out)
                    restores.append(timed(["tar", "--use-compress-program=zstd -d -q", "-C", out, "-xf", archive], work))
                size = os.path.getsize(archive)
                print(f"{name[:16]:<16} {level:>3} {t:>2} {fmt(saves):>22} {fmt(restores):>22} {size:>12} {raw / size:6.2f}", flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
