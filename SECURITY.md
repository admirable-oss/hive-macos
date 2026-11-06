# Security policy

Please do not report security vulnerabilities in public issues.

Use GitHub's private vulnerability reporting in the [main Hive repository](https://github.com/admirable-oss/hive/security/advisories/new). If private reporting is unavailable, contact the maintainers through the security contact listed in the [main Hive repository](https://github.com/admirable-oss/hive).

Include the affected version, macOS version, steps to reproduce, and any relevant logs with secrets removed. Please allow maintainers time to investigate and coordinate a fix before public disclosure.

## Verifying releases

Every release of Hive Desktop is signed with Developer ID and notarized by Apple. Its `checksums.txt` is signed with the Hive release key; the README shows how to check a download. The app's own updater makes the same checks, plus the new app's code signature and Developer ID team, before installing anything. A release whose signature doesn't verify is never installed.
