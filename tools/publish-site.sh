#!/bin/zsh
# Publishes site/ to the gh-pages branch of the repository in SFUpdateRepository. GitHub Pages serves that branch.
#   tools/publish-site.sh
# Publishes the site as it is in the public branch: run tools/publish-public.sh first.
# When dist/forgedeck-release.json exists (tools/release.sh writes it), it is published next to
# index.html, so ForgeDeck's Version URL check reports the release that is live. It holds no secrets.
set -euo pipefail
here=${0:A:h:h}
cd "$here"
split=$(git subtree split --prefix=site public 2>/dev/null)
commit=$split
if [[ -f dist/forgedeck-release.json ]]; then
  index=$(mktemp -u)
  GIT_INDEX_FILE=$index git read-tree "$split"
  blob=$(git hash-object -w dist/forgedeck-release.json)
  GIT_INDEX_FILE=$index git update-index --add --cacheinfo 100644 "$blob" forgedeck-release.json
  tree=$(GIT_INDEX_FILE=$index git write-tree)
  rm -f "$index"
  commit=$(GIT_AUTHOR_NAME=rmclain GIT_AUTHOR_EMAIL=1417707+rmclain@users.noreply.github.com \
    GIT_COMMITTER_NAME=rmclain GIT_COMMITTER_EMAIL=1417707+rmclain@users.noreply.github.com \
    git commit-tree "$tree" -p "$split" -m "Site with release fingerprint")
fi
git push -q --force origin "${commit}:refs/heads/gh-pages"
echo "published site/ ($commit) to gh-pages"
