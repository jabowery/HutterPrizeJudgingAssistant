# Hutter Prize Docker judge

`judge.sh` automates the reproducible technical part of judging a Hutter Prize
submission. The authoritative rules remain the
[Hutter Prize detailed rules](https://www.hutter1.net/prize/hrules.htm); this
repository records the artifacts, isolation boundaries, resource measurements,
hashes, and proposed score for human review.

Entrants should follow [ENTRANT_INSTRUCTIONS.md](ENTRANT_INSTRUCTIONS.md).

## Run a complete Linux judgment

From the repository root:

```bash
./judge.sh \
  --work-root /mnt/large-disk/HutterPrizeJudge \
  Entries/NAME ./enwik9
```

The work filesystem must have at least the configured 100 GB allowance. By
default, submitted-archive qualification and rebuilt compression may overlap
(`--jobs 2`). Use `--serial` when a disputed CPU timing must be repeated without
concurrent work. `--geekbench-score N` reuses a separately verified Geekbench 5
single-core score.

The current Docker worker executes Linux x86/x86-64 entries. The manifest also
defines Windows x86/x86-64 names so the same orchestration contract can be used
by a native Windows worker; this Linux worker rejects a Windows manifest rather
than running it under an unscored compatibility layer.

## Submission boundary

The entrant directory contains a strict, declarative `entry.env`, the artifacts
it names, and the named source package. No executable name is inferred. In
particular, the judge creates no program-name compatibility aliases.

For the normal self-extracting form, the roles are:

```text
declared source package -> build container -> COMPRESSOR
COMPRESSOR + enwik9      -> execution container -> ARCHIVE
ARCHIVE                  -> execution container -> DECOMPRESSED_OUTPUT
```

For the Relaxations form:

```text
declared source package -> build container -> COMPRESSOR + DECOMPRESSOR
COMPRESSOR + enwik9      -> execution container -> ARCHIVE data
DECOMPRESSOR + ARCHIVE   -> execution container -> DECOMPRESSED_OUTPUT
```

`entry.env` is beside the artifacts, not hidden inside the source package. It
is parsed as data and is never sourced as shell. Unknown keys, duplicate keys,
paths, and shell syntax are rejected.

## Artifact handoff and one-execution rule

Every judge-initiated contestant executable invocation gets a newly created
Docker container. The container receives only the evaluated executable, its
declared argument vector, and the declared input artifact. It has no network,
no reference corpus, no source/build tree, and no other build outputs.

Each output artifact is copied back to the host judging environment. The judge
checks that it is a regular file and records its size, SHA-256 digest, and type
before another container can receive it. A trusted `exec-once` monitor permits
the one declared executable transition and rejects later `execve`/`execveat`
calls by that program or its descendants. A wrapper therefore cannot launch an
uncharged helper. A genuine multi-executable workflow must expose the
intermediate artifact as a declared stage so it can be returned and evaluated.

Source tar/ZIP extraction, `install.sh`, and `build.sh` are separate containers.
The source build returns only the executable role(s) declared in `entry.env`.
Other build outputs never enter a scored runtime.

Executable normalization is also a separate container stage:

- `FORMAT=executable` copies and evaluates an ordinary executable.
- `FORMAT=upx` uses the repository-pinned UPX 5.1.1 to unpack a pure UPX file.
- `FORMAT=upx-overlay` unpacks a UPX executable prefix while preserving its
  appended data.

The normalized executable is returned to the host and evaluated before its
separate execution container is created. The original submitted/built bytes,
not the larger normalized copy, remain the scored and reproducibility-comparison
artifact. The pinned UPX archive has SHA-256
`1ff660454227861e00772f743f66b900072116b9dc24f6ee28b97cce88a7828a`.

## Privilege and network phases

The common judge image may use the network while it is built. For entrant code,
only `install.sh` runs as root with network access, while constructing a
dependency image. It receives no source tree. All later entrant stages are
offline. `build.sh` runs as UID/GID 65532 in its own container; normalization
uses trusted judge tools as UID/GID 65532; every compressor/decompressor runs
offline as UID/GID 65532 under the formal limits.

Docker shares the host kernel. Namespace and capability restrictions reduce
exposure but are not a security boundary equivalent to a virtual machine: a
kernel or container-runtime vulnerability could escape the container. Treat
adversarial submissions as hostile and run the whole judge on a disposable,
fully patched machine or VM with no credentials or unrelated data.

## Resource accounting

The default formal limits are 10 GiB peak RSS and 100,000,000,000 bytes of
temporary disk. A higher cgroup ceiling reserves room for the trusted monitor
and cache while GNU `time` measures the contestant process tree. CPU capacity,
wall time, disk allocation, container inspection, logs, hashes, and image IDs
are retained under `Results/`.

The proposed standard score is:

```text
S = bytes(COMPRESSOR) + bytes(generated ARCHIVE)
    + bytes(COMPRESSOR_ARGUMENTS)
```

For `ENTRY_FORMAT=separate-decompressor`:

```text
S = bytes(COMPRESSOR)
    + decompressor_multiplier * bytes(DECOMPRESSOR)
    + bytes(generated ARCHIVE)
    + declared argument bytes
```

The decompressor multiplier is 2, reduced to 1 when the rebuilt compressor and
decompressor are byte-identical, following the Relaxations. Command-line and
compilation-option accounting remains subject to human review; the automation
does not let an entrant declare its own score.

## Tests

```bash
./tests/test-qualify-archive.sh
./tests/test-judge.sh
```

The integration tests cover tar and ZIP source packages, both official entry
forms, parallel cancellation, memory/time/content failures, hidden build
helpers, unknown manifest fields, and rejection of a nested executable launch.

## Example fixture status

`Entries/Example` is a substantially modified procedural test fixture derived
from Vladimir Ivanov's fx2-cmix-transformer submission. It is not Vladimir's
actual entry and must not be presented as one. Its source package is deliberately
named `example-source.tar.gz` to keep that distinction explicit.

Each embedded auxiliary-data decode runs in a forked child of the declared
compressor. This gives the cmix model fresh process state without an additional
`execve`; no second contestant executable is launched. The stored `archive9`
was generated by the modified source inside the pinned Ubuntu 22.04 judge
environment.

The current rebuilt compressor and archive total 114,866,800 bytes. Including
the 22-byte compressor argument file gives a formal standard size of
114,866,822 bytes, which is not a competitive result. This fixture exists only
to develop and test the judging procedure.
