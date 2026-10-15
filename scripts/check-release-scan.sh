#!/bin/sh
# Checks that a commit's code has been scanned by CodeQL and has no serious alerts, before it's
# released. The Swift scan runs on main (codeql-swift.yml), not on the release, so this finds
# main's latest Swift scan and checks that it covered the same code: nothing under the paths
# below changed between the scanned commit and this one. A commit that only adds release notes
# passes on the scan of the code before it. Then main must have no open CodeQL alert that's an
# error, or a security alert rated high or critical.
# Usage: scripts/check-release-scan.sh [<commit>]   (default HEAD)
#
# Needs gh signed in to the repository, and permission to read its code scanning results.
set -u
commit="$(git rev-parse --verify "${1:-HEAD}^{commit}")" || exit 1
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# The paths codeql-swift.yml scans on push. Change them together.
code_paths="Sources Package.swift Package.resolved"

scanned="$(gh api "repos/{owner}/{repo}/code-scanning/analyses?ref=refs/heads/main&tool_name=CodeQL&sort=created&direction=desc&per_page=100" \
  --jq '[.[] | select(.category == "/language:swift" and .error == "")][0].commit_sha // empty')" || exit 1
if [ -z "$scanned" ]; then
  echo "error: main has no Swift code scanning results yet; run the CodeQL Swift workflow" >&2
  exit 1
fi
git cat-file -e "$scanned^{commit}" 2>/dev/null || git fetch -q origin main
echo "Latest Swift scan of main: $(git log -1 --format='%h %s' "$scanned")"

# shellcheck disable=SC2086
if ! git diff --quiet "$scanned" "$commit" -- $code_paths; then
  # shellcheck disable=SC2086
  echo "error: the code at $(git rev-parse --short "$commit") hasn't been scanned yet; since the scan:$(git diff --shortstat "$scanned" "$commit" -- $code_paths)" >&2
  running="$(gh run list --workflow codeql-swift.yml --branch main --status in_progress --json url --jq '.[0].url // empty' 2>/dev/null)"
  if [ -n "$running" ]; then
    echo "A scan is running: $running. Check again when it's done." >&2
  else
    echo "Push the code to main, or run the CodeQL Swift workflow, then check again." >&2
  fi
  exit 1
fi
echo "ok    the scan covers $(git rev-parse --short "$commit")"

alerts="$(gh api --paginate "repos/{owner}/{repo}/code-scanning/alerts?ref=refs/heads/main&state=open&tool_name=CodeQL&per_page=100" \
  --jq '.[] | select(.rule.severity == "error" or .rule.security_severity_level == "high" or .rule.security_severity_level == "critical")
        | "\(.rule.security_severity_level // .rule.severity)  \(.rule.id)  \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)  \(.html_url)"')" || exit 1
if [ -n "$alerts" ]; then
  echo "error: main has open code scanning alerts that block a release:" >&2
  echo "$alerts" >&2
  exit 1
fi
echo "ok    no open errors or high or critical security alerts"
