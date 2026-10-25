#!/usr/bin/env bash
# GitHub Actions is canonical. Run its workflow locally with act when available.
set -euo pipefail
cd "$(dirname "$0")/.."
exec act -W .github/workflows/image.yml -j test "$@"
