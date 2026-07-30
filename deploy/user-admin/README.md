# Damsure user-admin rollout

This directory is inert source material. It does not grant access until an administrator installs the wrapper as `root:root` mode `0750`, creates a root-owned `0640` operator mapping at `/etc/damsure/user-admin-operators.json`, validates it with `visudo -c`, and installs a restricted sudoers rule for named Unix accounts with personal SSH keys.

Use `sudo /usr/local/sbin/damsure-user-admin create --franchisee-id UUID --email user@example.com --name 'Name' --reason TICKET --idempotency-key UUID`. Generated credentials are written only once to the caller's `/dev/tty`; capture them in an approved secret manager. To recover a terminal display failure, run `reset-password` with a new UUID key. Supply a credential only with `--password-stdin`, never an argument or environment variable.

Before rollout, verify the config is not a symlink, is root-owned and group/world non-writable, every named account maps to explicit UUIDs (or deliberate `*` platform scope), direct `node dist/cli/userAdmin.js` fails, and the production build is present after `npm prune --omit=dev`. Do not use this mechanism for deletion, tenant moves, roles, invitations, or bulk import. The non-destructive migration down only removes the normalized-email index; audit evidence is retained.
