#!/bin/sh
# Checks a ref's CodeQL results before a release: both scans (Swift and the workflows) must have
# analysed the expected commit, and there must be no open alert that's an error, or a security
# alert rated high or critical. The Release workflow runs it on the tag, after scanning it; the
# release skill runs it on main before tagging, as an early warning.
# Usage: scripts/check-release-scan.sh [<ref> [<commit>]]
#   ref     a full ref, refs/heads/main (the default) or refs/tags/v1.2.0
#   commit  the commit its scans must have analysed; by default the newest one scanned
#
# Needs gh signed in to the repository, and permission to read its code scanning results.
set -u
ref="${1:-refs/heads/main}"
commit="${2:-}"
categories="/language:swift /language:actions"
failures=0

analyses="$(gh api "repos/{owner}/{repo}/code-scanning/analyses?ref=$ref&tool_name=CodeQL&sort=created&direction=desc&per_page=100" \
  --jq '.[] | select(.error == "") | "\(.category) \(.commit_sha) \(.created_at)"')" || exit 1
for category in $categories; do
  latest="$(echo "$analyses" | awk -v c="$category" '$1 == c { print $2, $3; exit }')"
  if [ -z "$latest" ]; then
    echo "FAIL  no $category scan of $ref" >&2
    failures=$((failures + 1))
  elif [ -n "$commit" ] && [ "${latest%% *}" != "$commit" ]; then
    echo "FAIL  the latest $category scan of $ref is of ${latest%% *}, not $commit" >&2
    failures=$((failures + 1))
  else
    echo "ok    $category scanned ${latest%% *} at ${latest#* }"
  fi
done
[ "$failures" -eq 0 ] || exit 1

alerts="$(gh api --paginate "repos/{owner}/{repo}/code-scanning/alerts?ref=$ref&state=open&tool_name=CodeQL&per_page=100" \
  --jq '.[] | select(.rule.severity == "error" or .rule.security_severity_level == "high" or .rule.security_severity_level == "critical")
        | "\(.rule.security_severity_level // .rule.severity)  \(.rule.id)  \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)  \(.html_url)"')" || exit 1
if [ -n "$alerts" ]; then
  echo "FAIL  open code scanning alerts on $ref block a release:" >&2
  echo "$alerts" >&2
  exit 1
fi
echo "ok    no open errors or high or critical security alerts on $ref"
