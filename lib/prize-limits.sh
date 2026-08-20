#!/usr/bin/env bash

# Established Hutter Prize execution environment: a 16 GiB system with the
# contestant command tree limited to 10 GiB maximum resident set size.
readonly HP_EXECUTION_RAM_BYTES=17179869184
readonly HP_PEAK_RSS_LIMIT_BYTES=10737418240
