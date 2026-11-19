#!/bin/zsh
# Publishes the current commit to the public GitHub repository as one new commit
# on top of the public history. Local history stays private: only the current
# tree is sent, without the paths in EXCLUDE (planning files and design sources
# the code does not need).
#   tools/publish-public.sh "Message for the public commit"
set -euo pipefail
here=${0:A:h:h}
cd "$here"
message=${1:?give a commit message}
EXCLUDE=(.forgedeck design docs/PROJECT_BRIEF.md tools/step.py)
[[ -z "$(git status --porcelain)" ]] || { echo "commit your changes first"; exit 1; }
index=$(mktemp); rm -f "$index"
GIT_INDEX_FILE=$index git read-tree HEAD
for excluded in $EXCLUDE; do GIT_INDEX_FILE=$index git rm -r --cached -q --ignore-unmatch "$excluded"; done
tree=$(GIT_INDEX_FILE=$index git write-tree); rm -f "$index"
id="1417707+rmclain@users.noreply.github.com"
export GIT_AUTHOR_NAME=rmclain GIT_AUTHOR_EMAIL=$id GIT_COMMITTER_NAME=rmclain GIT_COMMITTER_EMAIL=$id
if git ls-remote --exit-code origin main >/dev/null 2>&1; then
  git fetch -q origin main
  parent=$(git rev-parse origin/main)
  [[ "$(git rev-parse "$parent^{tree}")" != "$tree" ]] || { echo "nothing new to publish"; exit 0; }
  commit=$(git commit-tree "$tree" -p "$parent" -m "$message")
else
  commit=$(git commit-tree "$tree" -m "$message")
fi
git branch -f public "$commit"
git push -q origin public:main
echo "published $commit"
