# Objective
Create a docker script that automates Hutter Prize judging given an Entries/ subdirectory.

In documentation, reserve "judge" for a human Hutter Prize official. Refer to
software as `judging_assistance.sh`, the judging system, the orchestrator, or a
worker.

The detailed judging rules are at:
http://prize.hutter1.net/hrules.htm

An example subdirectory is Entries/Example/

Note the files in that example directory:

- `archive9` is an executable archive of `enwik9` used to exercise the judging
  system.
- `example-source.tar.gz` contains the modified source and entrant scripts.
- `entry.env` declares the artifact names and formats to the generic
  orchestrator.

This directory is a substantially modified testing fixture derived from an
earlier submission. It is not Vladimir Ivanov's actual entry and must not be
represented as such or as a competitive Hutter Prize result.
