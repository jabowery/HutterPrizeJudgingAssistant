# Hutter Prize Judging Assistance

This repository minimizes the manual work required to evaluate a Hutter Prize
submission. `judging_assistance.sh` rebuilds and runs the submitted software,
enforces the technical resource limits, verifies the result, and records the
evidence and proposed score for human review. 

Entrant-provided processes run within Docker containers to minimize the risk of
an adversarial entry. The security model is conditioned on the Linux kernel
confining those containers being hardened against
[container escape](https://docs.docker.com/engine/security/#linux-kernel-capabilities).
The judging system neither requires nor provisions a virtual machine. The
underlying host environment may provide an additional virtualization boundary,
but that boundary does not replace the required container-kernel hardening.

The authoritative rules remain the
[Hutter Prize detailed rules](https://www.hutter1.net/prize/hrules.htm).
Entrants should follow [ENTRANT_INSTRUCTIONS.md](ENTRANT_INSTRUCTIONS.md).

Each entry declares a `QUALIFICATION_OS` catalog alias in `entry.env`. The
Linux worker currently provides `ubuntu-20.04`, `ubuntu-22.04`, and
`ubuntu-24.04`; trusted code maps each alias to a digest-pinned official Docker
image. The selected image supplies one coherent userspace for the common
worker, Geekbench calibration, dependency installation, compilation,
compression, and decompression. Entrant-controlled registry references are not
accepted.

## Run

From the repository root:

```bash
./judging_assistance.sh \
  --cold-cache --serial \
  --work-root /mnt/large-disk/HutterPrizeJudging \
  Entries/NAME ./enwik9
```

The work filesystem must have at least the configured 100 GB allowance. A
formal one-billion-byte `enwik9` run requires `--cold-cache` and serial
execution. Diagnostic runs over smaller fixtures may still use the default
`--jobs 2`; the orchestrator refuses to combine cache eviction with parallel
execution. `--geekbench-score N` reuses a separately verified Geekbench 5
single-core score. Entries that need to unpack, generate, or invoke descendant
executables use `--runtime-exec-policy process-tree` under the rules in
[RELAXATION.md](RELAXATION.md); the default is the strict diagnostic policy.

The current Docker worker executes Linux x86/x86-64 entries. The manifest also
defines Windows x86/x86-64 names so the same orchestration contract can be used
by a native Windows worker; this Linux worker rejects a Windows manifest rather
than running it under an unscored compatibility layer.

## Automatic host initialization

Invoke `judging_assistance.sh` as an ordinary user. When necessary, it installs
Git LFS through the separate `install-host-dependencies.sh` helper, materializes
the required repository objects, and re-executes the trusted host orchestrator
through `sudo` to access Docker. The customary password prompt is the only
required interaction. Results created by the elevated process are returned to
the invoking user's ownership.

The qualification-only `benchmark.sh` and `qualify-archive.sh` wrappers use
the same Docker-access behavior: invoke them as an ordinary user and they
request `sudo` themselves only when access to the local Docker daemon requires
it. Benchmarking builds only the common, entry-independent judging image; it
does not require or inspect an entry source package.

Before an execution run, `qualify-archive.sh` automatically runs that
containerized Geekbench calibration when neither `--geekbench-score` nor
`--time-limit-seconds` is supplied. `--geekbench-score N` reuses a separately
verified result, while `--time-limit-seconds N` is a mutually exclusive
diagnostic override.
For archive-only qualification, `--qualification-os NAME` selects the same
trusted catalog explicitly; its default is `ubuntu-22.04`.
Automatic calibration evidence is retained within the qualification results
tree. `--preflight-only` remains non-executing and records the time limit as
uncalibrated when no score is supplied.

The Docker socket must not be made world-writable; access to it is
root-equivalent. Contestant executables do not receive that access and run as
UID 65532 in their execution containers.

Cold-cache control requests `sudo` for the narrow
`cold-cache-host-helper.sh`, even when the invoking user can already access
Docker. The helper invokes `sync` and writes `3` to
`/proc/sys/vm/drop_caches`; the residency verifier then runs without that
elevation. Root permission is never granted to an entrant container.

Before any entrant-provided code is unpacked, built, or executed, the
orchestrator runs a host-security preflight. It rejects a non-Linux daemon, a
nonlocal Docker endpoint, inactive seccomp filtering, failure to apply
`no-new-privileges`, or the absence of a verifiably enforcing AppArmor or
SELinux container profile. It records the orchestration environment's reported
kernel and the Docker daemon's reported kernel without requiring them to be the
same. Thus virtualization supplied by the underlying environment is neither a
prerequisite nor a reason for rejection. The checks follow Docker's documented
[capability and kernel-isolation model](https://docs.docker.com/engine/security/#linux-kernel-capabilities)
and verify the resulting test container rather than relying only on daemon
configuration.

The preflight records whether rootless Docker or user-namespace remapping maps
container UID 0 away from host UID 0. Their absence currently produces a
warning: entrant executables still run as UID 65532, but that is not a separate
user-namespace boundary. The preflight also warns that local inspection cannot
prove the absence of an unpatched Docker-kernel or Docker Engine vulnerability.
Its complete findings are retained as `host-security.env` in the results tree.

## Formal cold-cache boundary

Filesystem cache is part of the fixed 16 GiB execution environment. A formal
run therefore starts each timed container with its large input absent from the
Linux page cache. For each compression or decompression invocation the
orchestrator performs this sequence:

1. Build, validate, hash, and stage every phase input.
2. Create, but do not start, the timed Docker container.
3. Run `sync` and write `3` to `/proc/sys/vm/drop_caches` on the host Linux
   kernel.
4. Use `mincore(2)` to require zero resident pages for the exact input inode.
5. Start the already-created container.

For compression the checked inode is the `enwik9` bind mount. For a
self-extracting archive it is the exact copy staged for execution; for the
separate-decompressor form it is the staged archive payload. Files created
afresh by the running program do not require pre-run eviction because they
have new inodes. Hashing is completed before eviction so evidence collection
does not re-read the target afterward.

The Linux kernel defines value `3` as dropping clean page cache and reclaimable
dentries and inodes, and explains that `sync` first makes dirty objects eligible
for eviction. It also warns that this operation can cause performance problems,
which is why it is confined to controlled formal testing. See the
[Linux kernel `drop_caches` documentation](https://docs.kernel.org/admin-guide/sysctl/vm.html#drop-caches).

A host-wide lock is held for the complete cache-controlled run. A second
cache-controlled run is refused, and `--cold-cache` rejects `--jobs 2`, so no
orchestrator eviction can occur while another formal timed process is running.
Each timed phase records its target size and SHA-256, inode identity, eviction
timestamps, page count, resident-page count, and verifier digest in
`cold-cache.env`. The host conditions are recorded in `cold-cache-host.env`.

### WSL 2

The judging system may run inside a WSL 2 Linux guest; it does not prohibit an
underlying virtualization boundary. On a 32 GiB Windows machine, configure the
guest in `%UserProfile%\.wslconfig`, then run `wsl --shutdown` before starting
it again:

```ini
[wsl2]
memory=16GB
swap=0

[experimental]
autoMemoryReclaim=disabled
```

Keep the work directory and `enwik9` on the guest's Linux filesystem, not a
Windows drive exposed under `/mnt/c`, and retain the fixed 16 GiB Docker cgroup
limit. The prelaunch check rejects WSL timed-input/work storage on `drvfs`/`9p`
and rejects nonzero guest swap. WSL does not expose a dependable way for the
script to verify `autoMemoryReclaim=disabled`, so that setting is reported as
an external condition rather than silently assumed.

Linux `drop_caches` cannot evict cache below the guest kernel. Consequently, a
formal WSL result must either use a physical SSD attached directly with
`wsl --mount` or be accompanied by an empirical check on the actual machine
showing that a reread after guest cache eviction causes physical-disk reads
rather than Windows/Hyper-V cache hits. This is a limitation of the underlying
storage path, not a requirement that the judging system provision a VM.

## Terminology

In this documentation, a **judge** is a human Hutter Prize official. Automated
components are called `judging_assistance.sh`, the judging system, the
orchestrator, or a worker. The documentation does not assign human decisions or
obligations to software.

## Submission boundary

The entrant directory contains a strict, declarative `entry.env`, the artifacts
it names, and the named source package. No executable name is inferred. In
particular, the orchestrator creates no program-name compatibility aliases.

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

## Artifact handoff and runtime execution policy

Every system-initiated contestant executable invocation gets a newly created
Docker container. The container receives only the evaluated executable, its
declared argument vector, and the declared input artifact. It has no network,
no reference corpus, no source/build tree, and no other build outputs.

Each output artifact is copied back to the host judging environment. The
orchestrator checks that it is a regular file and records its size, SHA-256
digest, and type before another container can receive it. The trusted execution
monitor always traces the complete descendant tree. Under the default `strict`
policy it permits the one declared executable transition and rejects later
`execve`/`execveat` calls.

The explicitly selected `process-tree` relaxation permits later executable
transitions without creating new size or resource allowances. This accommodates
packed and multi-stage programs whose helpers are decoded or generated from
already-counted phase inputs. It does not make independently staged entrant
files free: those remain outside information and must be declared and counted.
All descendants remain in the original container and cgroup. The report records
phase-input sizes and hashes, execution events, and hashes of persistent
runtime executables. Failure only under `strict` is not a failure under the
selected relaxation.

Source tar/ZIP extraction, `install.sh`, and `build.sh` are separate containers.
`install.sh` supplies both build dependencies and any shared libraries needed
when the submitted or rebuilt executables run. The orchestrator derives two
images from that one installation: an offline build image retaining the
installed tools, and a runtime image that starts again from the trusted common
image and adds only loader-visible files from the standard system library
trees to the entrant's chroot. The collection itself occurs in a fresh trusted
stage, not through utilities that `install.sh` could have replaced. Thus an
installation cannot replace the trusted worker scripts or execution monitor.
The monitor is statically linked so entrant-installed C libraries cannot alter
it. The same runtime image is used for submitted decompression, rebuilt
compression, and any required generated-archive decompression.

The source build returns only the executable role(s) declared in `entry.env`.
Other build outputs never enter a scored runtime.

Executable validation and staging is also a separate container stage:

- `FORMAT=executable` stages an ordinary executable unchanged.
- `FORMAT=upx` uses the repository-pinned UPX 5.1.1 to test and unpack a
  scratch copy of a pure UPX file.
- `FORMAT=upx-overlay` finds, tests, and unpacks a scratch copy of the UPX
  executable prefix without interpreting its appended data.

The scratch copy is discarded. A byte-identical copy of the original artifact
is returned to the host and evaluated before its separate execution container
is created. The exact submitted/built bytes are therefore both scored and
executed. This is required for self-extracting compressors that read their own
executable image when constructing an archive. The pinned UPX archive has SHA-256
`1ff660454227861e00772f743f66b900072116b9dc24f6ee28b97cce88a7828a`.

## Privilege and network phases

The common judging image may use the network while it is built. For entrant
code, only `install.sh` runs as root with network access, while constructing
the build and sanitized runtime dependency images described above. It receives
no source tree. All later entrant stages are offline. `build.sh` runs as
UID/GID 65532 in its own container; executable validation uses trusted
orchestration tools as UID/GID 65532; every compressor/decompressor runs
offline as UID/GID 65532 under the formal limits.

Entrant containers share the Docker daemon host's Linux kernel. Namespace and
capability restrictions therefore do not replace the hardened-kernel condition
stated at the beginning of this document.

## Resource accounting

The established execution environment has 16 GiB total RAM with no swap. The
10 GiB limit is evaluated against the greater of GNU `time`'s per-process peak
and a trusted monitor's sampled aggregate RSS across concurrent descendant
processes. The monitor terminates the complete tracked tree when its aggregate
sample exceeds the limit. The execution cgroup's broader memory peak is also
retained as evidence; because that value includes filesystem cache, it is not
misreported as RSS. Temporary disk is limited to 100 GB. These are fixed
judging conditions; execution-environment RAM is not configurable. Human-readable
reports use byte-significant GiB for RAM, byte-significant decimal GB for
disk, and `HH:MM:SS` for durations. Insignificant trailing zeroes are omitted;
machine-readable evidence retains exact integer bytes and seconds. CPU
capacity, wall time, disk allocation, container inspection, logs, hashes, and
image IDs are retained under `Results/`.

Crossing the wall-time allowance immediately records `FAIL_TIME` and prints a
notice to the operator, but does not terminate the compressor or decompressor.
The isolated process tree continues to completion so its behavior and resource
use remain observable. The operator may press Ctrl-C to terminate it; the
orchestrator then force-removes the active container and cleans its work area.
Memory and disk violations remain terminating conditions.

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
./tests/test-terminology.sh
./tests/test-host-security-preflight.sh
./tests/test-validate-executable.sh
./tests/test-example-entry.sh
./tests/test-qualification-os.sh
./tests/test-resource-units.sh
./tests/test-cold-cache.sh
./tests/test-docker-elevation.sh
./tests/test-dependency-runtime.sh
./tests/test-qualify-archive.sh
./tests/test-judging-assistance.sh
```

The qualification-OS test verifies the allow-listed aliases, pinned image
references, manifest rejection, and parameterized Dockerfile stages. The
terminology test enforces the human/software distinction above. The
security-preflight test covers required confinement failures, local-daemon
enforcement, and remapped and unremapped UID behavior. The executable-validation
test checks that pure and overlay UPX artifacts are inspected and then executed
byte-for-byte unchanged. The Example test checks that the successful fixture
remains purpose-built and uses portable baseline x86-64 compilation. The
resource-unit test enforces byte-significant GiB for RAM, byte-significant
decimal GB for disk, and `HH:MM:SS` durations in human-readable output. The
cold-cache test builds and exercises the trusted `mincore(2)` verifier and
checks the formal-run CLI invariants without evicting the development host's
cache. The Docker-elevation test verifies automatic qualification calibration,
re-execution through `sudo` when local Docker access requires it, and ownership
restoration. The dependency-runtime test verifies that an
`install.sh`-provided shared library is available to an entrant executable
while the trusted worker remains unchanged and its execution monitor remains
statically linked. The integration tests generate their own small entries and
alternate `entry.env` manifests under a temporary directory.
Those synthetic entries cover tar and ZIP source packages, both official entry
forms, parallel cancellation, memory/time/content failures, hidden build
helpers, unknown manifest fields, strict rejection of a nested executable
launch, and permitted descendant execution under the process-tree relaxation.
In particular, the CPU-bound failure crosses a one-second limit, receives the
non-terminating `FAIL_TIME` notification, and then exits on its own so the test
can verify that the worker allowed completion.

## Example fixture status

`Entries/Example` is a purpose-built procedural fixture with no code or design
derived from a Hutter Prize submission. It exists only to fill every ordinary
artifact slot and exercise the successful judging flow quickly.

The fixture consists of one statically linked, single-threaded, baseline
x86-64 executable. In compression mode it copies itself, appends a Zstandard
level-1 frame containing `enwik9`, and writes a fixed trailer. Running the
resulting `archive9` extracts that frame to `data9`. It launches no helper
executable. The build uses `-march=x86-64 -mtune=generic`, so the artifact does
not depend on build-host-specific Intel or AMD instructions.

The pinned Ubuntu 22.04 build produces a 1,618,304-byte compressor and a
359,695,801-byte archive. Including its 19-byte argument file gives a formal
standard size of 361,314,124 bytes, which is deliberately noncompetitive. In a
direct reference run over the full one-billion-byte `enwik9`, compression took
3.06 seconds and decompression took 1.18 seconds, with less than 0.004 GiB peak
RSS in either direction. Timings vary by host; their purpose here is to
establish that this fixture completes in seconds rather than days.
