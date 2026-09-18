# Entrant instructions

These instructions define the mechanical submission contract used by
`judging_assistance.sh`. They use the illustrative filenames from the
[official detailed rules](https://www.hutter1.net/prize/hrules.htm), while
allowing different real filenames through explicit `entry.env` aliases.

## 1. Choose one official entry form

### Self-extracting form

The compressor consumes `enwik9` and produces an executable archive. Running
that archive with no arguments produces the declared output file.

Illustrative Linux directory:

```text
Entries/NAME/
├── entry.env
├── archive9
└── comp9.tar.gz       # .tar, .tgz, or .zip is also accepted
```

Illustrative Windows directory:

```text
Entries/NAME/
├── entry.env
├── archive9.exe
└── comp9.zip
```

Linux `entry.env` example:

```text
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=linux-x86_64
QUALIFICATION_OS=ubuntu-24.04
SOURCE_PACKAGE=comp9.tar.gz
COMPRESSOR=comp9
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=data9
```

Windows `entry.env` example:

```text
ENTRY_FORMAT=self-extracting
EXECUTION_PLATFORM=windows-x86_64
QUALIFICATION_OS=windows-11
SOURCE_PACKAGE=comp9.zip
COMPRESSOR=comp9.exe
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9.args
ARCHIVE=archive9.exe
ARCHIVE_FORMAT=executable
DECOMPRESSED_OUTPUT=data9
```

The current repository worker executes the Linux forms. A Windows manifest is
for the corresponding native Windows worker and is rejected by this Linux
worker.

### Separate-decompressor Relaxations form

The compressor produces nonexecutable archive data. A separate decompressor
consumes that data and produces the declared output.

Illustrative Linux directory:

```text
Entries/NAME/
├── entry.env
├── decomp9
├── archive9.bhm
└── comp9a.tar.gz
```

Illustrative Windows directory:

```text
Entries/NAME/
├── entry.env
├── decomp9.exe
├── archive9.bhm
└── comp9a.zip
```

Linux `entry.env` example:

```text
ENTRY_FORMAT=separate-decompressor
EXECUTION_PLATFORM=linux-x86_64
QUALIFICATION_OS=ubuntu-24.04
SOURCE_PACKAGE=comp9a.tar.gz
COMPRESSOR=comp9a
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9a.args
ARCHIVE=archive9.bhm
ARCHIVE_FORMAT=data
DECOMPRESSOR=decomp9
DECOMPRESSOR_FORMAT=executable
DECOMPRESSOR_ARGUMENTS=decomp9.args
DECOMPRESSED_OUTPUT=data9
```

Windows `entry.env` example:

```text
ENTRY_FORMAT=separate-decompressor
EXECUTION_PLATFORM=windows-x86_64
QUALIFICATION_OS=windows-11
SOURCE_PACKAGE=comp9a.zip
COMPRESSOR=comp9a.exe
COMPRESSOR_FORMAT=executable
COMPRESSOR_ARGUMENTS=comp9a.args
ARCHIVE=archive9.bhm
ARCHIVE_FORMAT=data
DECOMPRESSOR=decomp9.exe
DECOMPRESSOR_FORMAT=executable
DECOMPRESSOR_ARGUMENTS=decomp9.args
DECOMPRESSED_OUTPUT=data9
```

For either form, x86 uses `linux-x86` or `windows-x86`; x86-64 uses
`linux-x86_64` or `windows-x86_64`.

## 2. `entry.env` rules

`entry.env` must be an ordinary file beside the initially submitted artifacts.
It is never shell-evaluated. Each non-comment line is exactly `KEY=VALUE`.
Values naming files must be basenames made from letters, digits, `.`, `_`, and
`-`; paths, quoting, substitutions, and duplicate/unknown fields are rejected.

The aliases have precise roles:

- `QUALIFICATION_OS`: trusted catalog alias for the operating-system
  userspace used to build, calibrate, compress, and decompress the entry. The
  Linux worker currently accepts `ubuntu-20.04`, `ubuntu-22.04`, and
  `ubuntu-24.04`. Each alias maps to an official digest-pinned Docker image;
  registry references supplied by an entry are rejected.
- `SOURCE_PACKAGE`: the one contestant source tar/ZIP package.
- `COMPRESSOR`: exact regular executable that `build.sh` must create in its
  current working directory and the exact basename used during compression.
- `COMPRESSOR_ARGUMENTS`: argument-vector file inside the source package.
- `ARCHIVE`: exact compressor output and initially submitted archive basename.
- `DECOMPRESSOR`: exact rebuilt and initially submitted decompressor basename
  for the Relaxations form.
- `DECOMPRESSOR_ARGUMENTS`: decompressor argument-vector file in the package.
- `DECOMPRESSED_OUTPUT`: exact file whose contents must equal `enwik9`.

No alias, symlink, fallback name, PATH lookup, or executable inference is added
by the judging system.

The `*_FORMAT` values are:

- `executable`: ordinary executable bytes.
- `upx`: a pure UPX-packed executable.
- `upx-overlay`: a UPX-packed executable prefix followed by required data.
- `data`: permitted only for `ARCHIVE_FORMAT` in the separate-decompressor
  form.

UPX validation is performed by a trusted, pinned unpacker on a scratch copy in
its own offline container. The scratch copy is discarded. A byte-identical
copy of the original packed executable is returned to the host orchestrator,
hashed/sized/typed, and only then supplied to a new execution container. Thus
the exact packed bytes are both scored and executed; a program may read its own
executable image without seeing an orchestrator-rewritten version.

## 3. Source-package layout

The tar/ZIP must contain exactly one top-level directory. That directory must
contain:

```text
submission-source/
├── install.sh
├── build.sh
├── comp9.args          # or the basename declared for the compressor
├── decomp9.args        # separate-decompressor form only
└── complete source, license, documentation, and build inputs
```

Do not put `entry.env`, the initially submitted archive, or a compressor
launcher in this package. In particular, there is no `compress.sh` contract.
The trusted orchestrator reads the literal argument file and invokes the
declared executable directly.

## 4. `install.sh`

This is the only entrant-controlled root/network phase. It runs in the
isolated dependency-install stage. It receives no source tree and must not
build the entry. Use it only to install system dependencies, including every
shared library required by the submitted decompressor, rebuilt compressor, and
generated decompressor. It must be noninteractive and repeatable. After it
finishes, no entrant stage receives network access or root privileges.

`install.sh` starts from the complete userspace selected by
`QUALIFICATION_OS`. Select the OS on which the entry is intended to run rather
than attempting to replace the selected distribution's C library with files
from another release. The same selected userspace is used for Geekbench and
every contestant executable in that run.

The judging system retains the installed tools in an offline build image. It
also creates a sanitized runtime image by starting again from the trusted
common image and copying the installation's loader-visible shared libraries
from the standard `/lib`, `/lib64`, `/usr/lib`, and `/usr/local/lib` trees into
the entrant-only filesystem. Install required runtime libraries in one of
those system locations. Entrant-installed programs and worker scripts are not
copied into that runtime image. Consequently, a runtime helper that is itself
an executable must be contained in or generated by a counted artifact and
permitted by the selected runtime-executable policy; installing a helper
executable does not make it part of a scored execution.

## 5. `build.sh`

`build.sh` runs offline as UID/GID 65532 in a fresh container. The unpacked
source tree is mounted read-only at `/entry`; the current directory `/work` is
writable. It must write the executable basename(s) declared by `COMPRESSOR` and,
for the Relaxations form, `DECOMPRESSOR`, directly into `/work`.

Only those declared files are returned to the host orchestrator. A larger
helper left elsewhere in `/work` cannot be reached by the formal execution
container.

## 6. Argument vectors

An argument file contains one literal argument per LF-terminated line. An empty
file means no arguments. Empty arguments, CR bytes, whitespace, shell syntax,
and bytes outside the documented safe alphabet are rejected. The file is read
as data; there is no shell expansion.

Example `comp9.args` representing `./comp9 -e enwik9 archive9`:

```text
-e
enwik9
archive9
```

For the Relaxations example, `decomp9.args` would commonly be:

```text
archive9.bhm
data9
```

The judging system records the exact argument-file byte count and digest for
score review.

## 7. Runtime contract

Each declared executable invocation is a new Docker container with network
disabled. The working directory contains only that evaluated executable, its
argument vector, and its declared input. The reference `enwik9` is present only
for compression; it is never visible to a decompressor.

The default `strict` runtime policy permits forks and threads but rejects every
later `execve`/`execveat`. Under that policy, an additional independently
supplied executable must be expressed as a declared artifact stage so the
orchestrator can return it across a phase boundary before it runs.

The [runtime process-tree and packed-executable relaxation](RELAXATION.md) may
instead be selected with:

```text
--runtime-exec-policy process-tree
```

That policy permits the declared program and its descendants to execute
programs unpacked or generated from the already-counted phase inputs. The
entire descendant tree remains in the same container, one-core cgroup, time
allowance, aggregate memory accounting domain, disk allowance, and offline
security boundary. An independently staged helper is still outside information
and must be declared and counted; a runtime product is not scored a second
time. The results retain the root invocation, fork/clone/exec/exit events,
persistent runtime-executable hashes, and exact phase-input hashes for human
review.

For a self-extracting entry, the archive receives no arguments and must create
`DECOMPRESSED_OUTPUT`. For a separate-decompressor entry, the declared archive
data and arguments are staged beside `DECOMPRESSOR`.

## 8. Score and human review

The technical report proposes the official standard or Relaxations formula,
including argument bytes. It does not accept a contestant-provided byte total.
Human judges must still verify compilation options, command-line accounting,
licensing, attribution, algorithm disclosure, source correspondence, platform
eligibility, and the spirit of the Prize.

## 9. Entrant preflight checklist

- `entry.env` is at `Entries/NAME/entry.env` and names every submitted file.
- `QUALIFICATION_OS` names a supported catalog entry matching the intended
  build and runtime userspace.
- Every filename is a basename and every alias matches the actual program's
  expectations exactly.
- The source package has one top-level directory.
- `install.sh` only installs build dependencies and required runtime shared
  libraries, and is noninteractive.
- `build.sh` works offline and emits only the declared role names needed for
  judging.
- Argument files contain one literal argument per line.
- The compressor produces the declared `ARCHIVE`.
- The appropriate decompressor produces `DECOMPRESSED_OUTPUT` identical to
  `enwik9` without seeing the reference.
- Select `process-tree` explicitly if a counted program must unpack, generate,
  or invoke another executable; otherwise it must satisfy `strict`.
- UPX or other preparatory representation is declared rather than hidden.
- Every executable runs in the fixed 16 GiB, no-swap execution environment;
  peak RSS is at most 10 GiB, temporary disk at most 100 GB, and every
  invocation meets the calibrated time limit.
