#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.socialforge.app.savedState
store=/tmp/SocialForge-self.store
rm -rf $store $store-shm $store-wal $store-library
APP_STORE=$store ~/Applications/SocialForge.app/Contents/MacOS/SocialForge --selftest
