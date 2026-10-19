#!/usr/bin/env bash
# TLS matrix against the running stack (sub-project 10). Sections are added by the tasks that turn TLS on per hop.
# Helpers: tests/lib/tls-probe.sh (self-tested by tests/tls-probe-self.test.sh).
cd "$(dirname "$0")/.."
source tests/lib/tls-probe.sh

# (sections follow)

tls_probe_exit
