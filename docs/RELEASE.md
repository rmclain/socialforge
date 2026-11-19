# Releasing SocialForge

SocialForge ships as a signed, notarized zip on GitHub Releases, and installed
copies update themselves from those releases, the same way ForgeDeck does.

## Requirements

| Need | For |
|---|---|
| A **Developer ID Application** identity in the login Keychain | Signing for download (team S572Y4JKKT) |
| A `notarytool` keychain profile, named in `NOTARY_PROFILE` | Notarization: `xcrun notarytool store-credentials <name> --apple-id <Apple ID> --team-id S572Y4JKKT` (asks for an app-specific password) |
| `gh`, signed in | Creating the repository, releases, and Pages |

## Publishing a release

1. Raise `CFBundleShortVersionString` in `apps/mac/Info.plist.in`. Commit.
2. `tools/publish-public.sh "SocialForge <version>"`: the public repository gets one commit with the current tree. Local history stays private, and `.forgedeck/`, `design/`, `docs/PROJECT_BRIEF.md`, and `tools/step.py` are left out.
3. `NOTARY_PROFILE=<profile> tools/release.sh`: runs `tools/package.sh` (one binary for Apple silicon and Intel, hardened runtime, Developer ID signature, notarization, stapling, a Gatekeeper check) and publishes `v<version>` with `SocialForge-<version>.zip` to the repository in `SFUpdateRepository`, with notes from the commits since the previous release. `--notes file` uses your own notes; `--draft` makes a draft.
4. If `site/` changed: `tools/publish-site.sh` pushes it to the `gh-pages` branch, which GitHub Pages serves at https://rmclain.github.io/socialforge/.

`tools/package.sh` never claims a notarization it did not do: without a Developer ID identity and `NOTARY_PROFILE` it prints `notarized: no`.

## How updates work

- At launch, at most once a day (Settings › General › Updates turns this off), the app asks `api.github.com/repos/rmclain/socialforge/releases/latest` without credentials. It ignores drafts and pre-releases and takes the first asset named `SocialForge*.zip` on github.com.
- A newer version shows an **Update** button in the sidebar. SocialForge › Check for Updates… or Settings › Check Now checks at once.
- **Install and Relaunch** downloads over https (redirects only to GitHub's download hosts), unzips with `ditto`, runs `codesign --verify --deep --strict`, and installs only when the new app's TeamIdentifier equals the running app's. The old app goes to the Trash, the new one takes its place, and the app relaunches.
- The library, the database, settings, and Keychain items are not touched. A copy without a team signature does not update itself.
- Builds made with `apps/mac/build.sh` (Apple Development) are signed by the same team, so they accept Developer ID releases too.
