#!/bin/zsh
# Publishes site/ to the gh-pages branch of the repository in SFUpdateRepository. GitHub Pages serves that branch.
#   tools/publish-site.sh
# Publishes the site as it is in the public branch: run tools/publish-public.sh first.
set -euo pipefail
here=${0:A:h:h}
repo=$(sed -n 's/.*<key>SFUpdateRepository<\/key><string>\(.*\)<\/string>.*/\1/p' "$here/apps/mac/Info.plist.in")
cd "$here"
split=$(git subtree split --prefix=site public 2>/dev/null)
git push --force origin "${split}:refs/heads/gh-pages"
echo "published site/ ($split) to $repo gh-pages"
