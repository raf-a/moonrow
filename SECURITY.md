# Security policy

## Supported versions

Only the latest release gets security fixes. Moonrow updates itself, so a fix ships as a new release and reaches everyone through the update window.

## Reporting a vulnerability

Report it privately through GitHub: on the [Security tab](https://github.com/raf-a/moonrow/security), choose **Report a vulnerability**. Please don’t open a public issue or pull request for it.

A useful report says which version you ran, which database and connection settings were involved, and the steps that show the problem.

## What to expect

Moonrow is maintained by one person, so these are best-effort times, not promises:

- An acknowledgement within a week.
- An assessment, and a plan or a reason for declining, within a month.
- For a confirmed problem, a fixed release, then a published advisory that credits you unless you’d rather not be named.

## Scope

In scope, in Moonrow itself and the releases published here:

- **Saved secrets.** Database passwords, SSH passwords and SSH key passphrases are kept in the login Keychain, never in the connections file. A secret that ends up anywhere else (on disk, in logs, in an export or a backup file, in another connection) is a vulnerability.
- **TLS.** A Postgres, MySQL or MariaDB connection set to verify the server’s certificate (VERIFY-CA or VERIFY-FULL, VERIFY_CA or VERIFY_IDENTITY on MySQL) that accepts a certificate it should reject, or that falls back to plain text. The lower modes, PREFER and REQUIRE (PREFERRED and REQUIRED on MySQL), encrypt without checking the certificate, as the vendors’ own clients do; that is how they’re meant to work.
- **SSH tunnels.** Moonrow runs the system’s `/usr/bin/ssh` and relays its prompts to the app. Anything that lets another process read those prompts or answers, skips host-key checking, or leaves a tunnel open after the app quits is in scope.
- **Updates.** Releases are signed with a Developer ID, notarized, and offered through a Sparkle feed whose archives are checked against an EdDSA key built into the app. A way to make Moonrow install something that isn’t a signed release is in scope.
- **SQL that Moonrow writes.** When the app builds SQL from what you type (cell edits, filters, structure changes, imports), names and values are quoted for the database’s dialect. A name or value that escapes its quoting and runs as SQL is a vulnerability.

Out of scope:

- Bugs in the database servers, OpenSSH, macOS or the libraries Moonrow uses. Please report those to their maintainers; if Moonrow needs to change because of one, tell us too.
- SQL you write and run yourself in the query editor. It runs with the permissions of the account you connected as.
- Attacks that need someone already in control of your Mac account, or a build you made or changed yourself.
