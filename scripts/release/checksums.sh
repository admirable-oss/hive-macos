#!/usr/bin/env bash
# Writes checksums.txt for the release files and signs it with the release SSH key, the
# way Hive's own releases are signed, so the in-app updater and anyone else can check it:
#
#   ssh-keygen -Y verify -f allowed_signers -I hive-release -n hive-release \
#     -s checksums.txt.sshsig < checksums.txt
#
#   RELEASE_SSH_KEY=~/.ssh/hive-release scripts/release/checksums.sh build/release
set -euo pipefail

DIR="${1:?the release directory}"
cd "$DIR"
rm -f checksums.txt checksums.txt.sshsig
shasum -a 256 Hive-*.dmg Hive-*.zip > checksums.txt
cat checksums.txt

if [ -n "${RELEASE_SSH_KEY:-}" ]; then
  ssh-keygen -Y sign -f "$RELEASE_SSH_KEY" -n hive-release checksums.txt
  mv checksums.txt.sig checksums.txt.sshsig
  echo "Signed checksums.txt"
else
  echo "RELEASE_SSH_KEY is not set: checksums.txt is unsigned, and the in-app updater will refuse this release" >&2
fi
