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

UPX normalization is performed by a trusted, pinned unpacker in its own
offline container. The normalized executable is returned to the host
orchestrator, hashed/sized/typed, and only then supplied to a new execution
container. The original packed bytes remain the scored artifact.

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

This is the only entrant-controlled root/network phase. It runs while an
isolated dependency image is built. It receives no source tree and must not
build the entry. Use it only to install system dependencies. It must be
noninteractive and repeatable. After it finishes, no entrant stage receives
network access or root privileges.

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

An executable may create temporary data, but it may not execute itself, a
wrapper target, a shell command, or an extracted helper. A trusted monitor
rejects any later `execve`/`execveat`. If your algorithm genuinely requires a
second executable, it must be expressed as a distinct declared artifact stage;
the orchestrator must be able to copy that artifact out, evaluate it, and start
a new container before it runs.

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
- Every filename is a basename and every alias matches the actual program's
  expectations exactly.
- The source package has one top-level directory.
- `install.sh` only installs dependencies and is noninteractive.
- `build.sh` works offline and emits only the declared role names needed for
  judging.
- Argument files contain one literal argument per line.
- The compressor produces the declared `ARCHIVE`.
- The appropriate decompressor produces `DECOMPRESSED_OUTPUT` identical to
  `enwik9` without seeing the reference.
- No runtime program invokes another executable.
- UPX or other preparatory representation is declared rather than hidden.
- Peak RSS is at most 10 GiB, temporary disk at most 100 GB, and every
  executable invocation meets the calibrated time limit.
