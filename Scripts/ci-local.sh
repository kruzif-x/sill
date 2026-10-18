#!/bin/bash
# The CI run, locally: what .github/workflows/ci.yml does, in one command. GitHub disables a
# fork's workflows until someone enables them in the repository's Actions tab, so this is the
# check that always works — and the one to run before pushing to this fork.
#
#   Scripts/ci-local.sh              build, the pure checks, the iOS simulator build
#   Scripts/ci-local.sh --mutants    also each check's mutants (an hour and more)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mutants=0
[ "${1:-}" = "--mutants" ] && mutants=1
fail=0

step() { printf '\n== %s\n' "$1"; }

step "swift build -c release (Mac host, CLI, probes)"
swift build -c release || fail=1

step "pure checks (Tests/checks/run-all.sh)"
if [ "$mutants" -eq 1 ]; then Tests/checks/run-all.sh --mutants || fail=1; else Tests/checks/run-all.sh || fail=1; fi

step "iOS app for the simulator (Debug, arm64, unsigned)"
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build >/dev/null || fail=1

if [ "$fail" -ne 0 ]; then echo; echo "CI-LOCAL: FAILED"; exit 1; fi
echo; echo "CI-LOCAL: all steps passed"
