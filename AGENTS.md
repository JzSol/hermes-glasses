# Repository Delivery Policy

This checkout is the user's maintained fork of Hermes Glasses.

- Work directly on `main`; do not create managed feature branches or pull requests for the user's own changes.
- Keep the writable user fork as `origin` and the original project as read-only `upstream`.
- At the end of each completed task, run the relevant tests/builds, review and stage only task-owned paths, create a Conventional Commit, fetch and safely integrate remote `main`, then push `main` without asking again.
- Verify the remote `main` SHA after every push. Never force-push, overwrite unrelated work, or resolve an ownership conflict by discarding local or remote changes.
- Never commit credentials, signing material, personal endpoints, local `.env` files, or generated agent state.
- "Automatic push" means after a verified task, not after every file save. If verification fails or `main` has conflicting/unowned changes, stop and report the blocker instead of publishing a broken tree.
