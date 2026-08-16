# Objective
Create a Docker-based system that, given an `Entries/` subdirectory, automates
the technical evaluation required for Hutter Prize judging to the greatest
degree practicable while minimizing the likelihood that an adversarial entry
can escape its container and compromise the host.

Treat every entrant-provided artifact and script as adversarial. Preserve
least-privilege, per-execution container isolation and explicit artifact
handoffs throughout the workflow. Docker shares the host kernel, so describe
these controls as reducing rather than eliminating container-escape risk.

For this objective, "practicable" is constrained to native Docker containers
sharing the host Linux kernel. Do not introduce a virtual machine, microVM,
hypervisor, guest kernel, or userspace kernel compatibility layer as the
execution environment or security boundary for entrant code.

In documentation, reserve "judge" for a human Hutter Prize official. Refer to
software as `judging_assistance.sh`, the judging system, the orchestrator, or a
worker.

The detailed judging rules are at:
http://prize.hutter1.net/hrules.htm

An example subdirectory is Entries/Example/

Note the files in that example directory:

- `archive9` is an executable archive of `enwik9` used to exercise the judging
  system.
- `example-source.tar.gz` contains the purpose-built source and entrant scripts.
- `entry.env` declares the artifact names and formats to the generic
  orchestrator.

This directory is a purpose-built procedural fixture with no derivation from a
Hutter Prize submission. It exists only to exercise the ordinary judging flow
quickly and must not be represented as a competitive Hutter Prize result.
