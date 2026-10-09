#!/usr/bin/env bash
# Runs the macOS CI job (.github/workflows/ci.yml, "App build, tests and e2e") on this Mac: build, unit +
# integration tests, package the .app, then the real-app end-to-end self-test. No GitHub Actions minutes needed.
#
# Usage: scripts/ci-local.sh [--no-e2e] [--shots] [--yes]
#   --no-e2e  stop after packaging (the e2e step opens real windows and sends real clicks, so it takes over the screen)
#   --shots   copy the e2e screenshots, snapshots and reports into docs/screenshots and docs/ci, like CI's [shots] commits
#   --yes     don't pause before the e2e step
# Results: artifacts/summary.txt (paste it to Claude), plus build.log, test.log and artifacts/e2e/*.
set -u
cd "$(dirname "$0")/.."
[ "$(uname)" = Darwin ] || { echo "scripts/ci-local.sh needs macOS (the app target cannot build elsewhere)."; exit 2; }

E2E=1; SHOTS=0; YES=0
for a in "$@"; do
  case "$a" in
    --no-e2e) E2E=0 ;;
    --shots) SHOTS=1 ;;
    --yes) YES=1 ;;
    -h|--help) sed -n 2,11p "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

export SNAPSHOT_DIR="$PWD/artifacts/snapshots"
rm -rf artifacts build.log test.log
mkdir -p artifacts/snapshots artifacts/e2e
FAILED=()

# run_limited <seconds> <logfile> <command...>: like `timeout`, which macOS does not ship. Exit status 124 = timed out.
run_limited() {
  local secs=$1 out=$2; shift 2
  "$@" > "$out" 2>&1 &
  local pid=$!
  for ((i = 0; i < secs; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

echo "== Toolchain"
sw_vers -productVersion; xcodebuild -version | head -1; swift --version 2>&1 | head -1

echo "== Build"
if swift build > build.log 2>&1; then tail -2 build.log; else
  echo "BUILD FAILED"; grep -E "error:" build.log | sort -u | head -40; FAILED+=("build")
fi

if [ ${#FAILED[@]} -eq 0 ]; then
  echo "== Unit and integration tests (10 minute limit)"
  run_limited 600 test.log swift test; STATUS=$?
  grep -E "Executed [0-9]+ tests" test.log | tail -1
  if [ $STATUS -eq 124 ]; then echo "TESTS TIMED OUT (a test is stuck)"; tail -4 test.log; FAILED+=("tests timed out")
  elif [ $STATUS -ne 0 ]; then
    grep -E "error:|Fatal|Segmentation|Crash" test.log | sort -u | head -40; FAILED+=("tests")
  fi
fi

if [ ${#FAILED[@]} -eq 0 ]; then
  echo "== Package app bundle"
  if scripts/build-app.sh > artifacts/package.log 2>&1; then
    tail -3 artifacts/package.log
    for f in LICENSE THIRD-PARTY-NOTICES.md swift-markdown-LICENSE.txt cmark-gfm-COPYING.txt mermaid-LICENSE.txt; do
      [ -s "dist/Downwrite.app/Contents/Resources/Legal/$f" ] || { echo "MISSING legal file: $f"; FAILED+=("package: $f"); }
    done
  else
    tail -30 artifacts/package.log; FAILED+=("package")
  fi
fi

if [ ${#FAILED[@]} -eq 0 ] && [ "$E2E" = 1 ]; then
  echo "== End-to-end self-test (real app, real window)"
  if [ "$YES" = 0 ]; then
    echo "   This opens Downwrite windows and sends real mouse/keyboard events for about a minute."
    echo "   Leave the Mac alone until it finishes. Starting in 5 seconds (Ctrl-C to cancel)..."
    sleep 5
  fi
  # -ApplePersistenceIgnoreState YES: do not reopen the windows of an earlier session (a real or earlier test run's `work.md`, a document you
  # had open) for this launch, nothing is saved either. Otherwise the self-test can pick up a stale window of the same name.
  run_limited 240 artifacts/e2e/stdout.txt dist/Downwrite.app/Contents/MacOS/Downwrite -ApplePersistenceIgnoreState YES \
    --selftest-out="$PWD/artifacts/e2e" --selftest-input="$PWD/Sources/Downwrite/Resources/Welcome.md" --selftest-extra="$PWD/README.md" \
    --selftest-fold="$PWD/Tests/Fixtures/fold-demo.md"
  CODE=$?
  echo "app exit status: $CODE (124 = timed out, 128+N = killed by signal N: 11 SIGSEGV, 6 SIGABRT)" | tee artifacts/e2e/exit.txt
  if [ $CODE -ge 128 ] && [ $CODE -ne 124 ]; then echo "crash reports: ~/Library/Logs/DiagnosticReports/Downwrite*.ips"; fi
  if grep -q "ALL CHECKS PASSED" artifacts/e2e/selftest-report.txt 2>/dev/null; then echo "e2e: ALL CHECKS PASSED"
  else echo "e2e FAILED"; FAILED+=("e2e"); fi
fi

if [ "$SHOTS" = 1 ]; then
  echo "== Copying screenshots and reports into docs/"
  mkdir -p docs/screenshots docs/ci
  rm -f docs/ci/selftest-report.txt docs/ci/crash.txt docs/ci/e2e-stdout.txt docs/ci/exit.txt
  cp artifacts/e2e/selftest-report.txt artifacts/e2e/menus.txt artifacts/e2e/exit.txt artifacts/package.log docs/ci/ 2>/dev/null
  tail -40 artifacts/e2e/stdout.txt > docs/ci/e2e-stdout.txt 2>/dev/null
  { grep -E "Executed [0-9]+ tests" test.log | tail -1; grep -E "error:" test.log | sort -u | head -40; } > docs/ci/test-summary.txt 2>/dev/null
  cp artifacts/e2e/window-*.png docs/screenshots/ 2>/dev/null
  cp artifacts/snapshots/*.png docs/screenshots/ 2>/dev/null
  echo "   Commit them with: git add docs/screenshots docs/ci && git commit -m 'local CI: update screenshots' && git push"
fi

{
  echo "################ SUMMARY ($(date '+%Y-%m-%d %H:%M'), $(git rev-parse --short HEAD), macOS $(sw_vers -productVersion)) ################"
  echo "--- build errors ---"; grep -E "error:" build.log 2>/dev/null | sort -u | head -25
  echo "--- test result ---"; grep -E "Executed [0-9]+ tests" test.log 2>/dev/null | tail -1
  echo "--- test failures ---"; grep -E "error:|Fatal|Crash" test.log 2>/dev/null | sort -u | head -40
  echo "--- test log tail ---"; tail -4 test.log 2>/dev/null
  echo "--- e2e report ---"; head -80 artifacts/e2e/selftest-report.txt 2>/dev/null
  echo "--- e2e app output (tail) ---"; tail -15 artifacts/e2e/stdout.txt 2>/dev/null
  if [ ${#FAILED[@]} -eq 0 ]; then echo "RESULT: ALL GREEN"; else echo "RESULT: FAILED -> ${FAILED[*]}"; fi
} > artifacts/summary.txt
echo
echo "Summary saved to artifacts/summary.txt"
[ ${#FAILED[@]} -eq 0 ] && echo "RESULT: ALL GREEN" || { echo "RESULT: FAILED -> ${FAILED[*]}"; exit 1; }
