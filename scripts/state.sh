#!/bin/bash
# Prints what the repository is built from: the release assets taken from
# each app (newest $KEEP stable releases) and a hash of this repository's own
# inputs. The workflow compares it with the published state.txt and only
# rebuilds when something changed.
set -euo pipefail
cd "$(dirname "$0")/.."
KEEP=${KEEP:-3}

jq -r '.[].repo' repos.json | while read -r repo; do
    gh api "repos/$repo/releases?per_page=30" --jq \
        "[.[] | select(.draft | not) | select(.prerelease | not)] | .[:$KEEP][]
         | .tag_name as \$tag | .assets[] | select(.name | endswith(\".deb\"))
         | \"$repo \(\$tag) \(.name) \(.updated_at)\""
done
echo "inputs $(cat repos.json keyring/* keys/* scripts/* | sha256sum | cut -d' ' -f1)"
