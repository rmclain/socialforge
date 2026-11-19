#!/bin/zsh
# Packages the app and publishes it as a GitHub release, which the in-app updater reads (like ForgeDeck).
#   NOTARY_PROFILE=<profile> tools/release.sh                 package, then publish v<version> with notes from git log
#   NOTARY_PROFILE=<profile> tools/release.sh --notes file    use these release notes
#   tools/release.sh --draft                                  make a draft release (the updater ignores drafts)
# The repository is SFUpdateRepository in apps/mac/Info.plist.in. Needs gh, signed in.
# Raise CFBundleShortVersionString first, then run tools/publish-public.sh, then this.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
plist="apps/mac/Info.plist.in"
version=$(sed -n 's/.*<key>CFBundleShortVersionString<\/key><string>\(.*\)<\/string>.*/\1/p' "$plist")
repo=$(sed -n 's/.*<key>SFUpdateRepository<\/key><string>\(.*\)<\/string>.*/\1/p' "$plist")
tag="v$version"
notes="" draft=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) notes="$2"; shift 2 ;;
    --draft) draft=(--draft); shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
[[ -n "$repo" ]] || { echo "SFUpdateRepository is not set in $plist"; exit 1; }
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then echo "$tag is already released on $repo"; exit 1; fi

tools/package.sh
zip="dist/SocialForge-$version.zip"
[[ -f "$zip" ]] || { echo "no $zip"; exit 1; }
build=$(unzip -p "$zip" SocialForge.app/Contents/Info.plist | plutil -extract CFBundleVersion raw -)
# The fingerprint ForgeDeck's Version URL reads from the GitHub Page (no secrets).
printf '{"commit_sha":"%s","version":"%s","build_id":"%s","built_at":"%s"}\n' \
  "$(git rev-parse HEAD)" "$tag" "$build" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > dist/forgedeck-release.json

notes_file=$(mktemp)
if [[ -n "$notes" ]]; then
  cp "$notes" "$notes_file"
else
  previous=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)
  {
    echo "## SocialForge $version"
    echo
    if [[ -n "$previous" ]]; then git log --format='- %s' "$previous"..HEAD 2>/dev/null | head -40 || true; fi
    echo
    echo "Unzip, drag SocialForge.app to Applications, and open it. Copies that are already installed offer the update themselves."
  } > "$notes_file"
fi
gh release create "$tag" "$zip" --repo "$repo" --target main --title "SocialForge $version" --notes-file "$notes_file" "${draft[@]}"
git tag -f "$tag" HEAD >/dev/null
tools/publish-site.sh
echo "released $tag on $repo"
