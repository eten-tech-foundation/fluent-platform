# Pin GitHub Actions to commit SHAs across all Fluent repos

**Date:** 2026-07-31
**Repos affected:** fluent-api, fluent-web, fluent-ai, fluent-mobile (~18 workflow files total across the four)
**Parent:** flagged by CodeRabbit on fluent-web#386 (`cut-release.yml`, `post-merge-deploy.yml`), generalized here to all repos
**Priority:** Non-blocking, security hardening — not specific to the CalVer work, surfaced because that PR touched workflow files

## Problem

GitHub Actions workflows across the Fluent repos reference third-party actions by mutable version tag (e.g. `actions/checkout@v7.0.0`, `azure/webapps-deploy@v3.0.8`) or branch, not by immutable commit SHA. Tags and branches can be retargeted by whoever controls the upstream action's repo — if any referenced action is compromised (a real, repeatedly-observed supply-chain attack pattern), the next workflow run silently pulls the malicious version. These workflows have real blast radius: they persist bot credentials (`BOT_TOKEN`), push tags/commits, and hold production deployment secrets (`AZUREAPPSERVICE_PUBLISHPROFILE_PROD`, database URLs, API keys).

CodeRabbit surfaced this concretely on fluent-web#386 for the two new CalVer workflows, but it applies to every existing workflow file in every repo, not just the new ones.

## Proposal

1. **Pin every `uses:` reference to a full 40-character commit SHA**, with the version tag kept as a trailing comment for readability:
   ```yaml
   - uses: actions/checkout@3df4ab11eba7bda6032a0b82a6bb43b11571feac # v7.0.0
   ```
2. **Add Dependabot (or Renovate) config for `github-actions` ecosystem** in each repo, so SHA pins get automated update PRs when a new version is released — pinning without automated updates just trades one maintenance burden (mutable-tag risk) for another (silently stale pins).
3. **Consider enabling the org/repo-level policy** (GitHub now supports enforcing SHA-pinning and blocking mutable-ref actions at the repo/org settings level) so this can't silently regress after the initial pass.

## How to resolve a tag to its commit SHA

Never hand-type or guess a SHA — resolve it from the actual upstream repo each time.

**Option A — `gh api` (works whether the tag is lightweight or annotated):**

```bash
gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object'
# {"sha":"11d5960a326750d5838078e36cf38b85af677262","type":"commit", ...}
```

If `"type"` comes back as `"commit"`, that `sha` **is** the commit SHA you want — use it directly. If it instead comes back as `"tag"` (an annotated tag points at a tag object, not a commit), resolve one more level:

```bash
gh api repos/<owner>/<repo>/git/tags/<sha-from-above> --jq '.object.sha'
```

**Option B — `git ls-remote` (no `gh` auth needed, same idea):**

```bash
git ls-remote --tags https://github.com/actions/checkout v4
# 11d5960a326750d5838078e36cf38b85af677262  refs/tags/v4
```

If the tag is annotated, `ls-remote` returns a *second* line for the same tag ending in `^{}` — that peeled line is the real commit SHA to use, not the first line (which points at the tag object). If only one line comes back (as with `actions/checkout@v4` above), it's a lightweight tag and that's already the commit SHA.

**Then pin it with the version kept as a comment for humans:**

```yaml
- uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
```

**Before trusting the SHA:** confirm `<owner>/<repo>` in the command is the actual official action repo, not a fork — pinning a SHA from the wrong repo pins you to someone else's code just as surely as a mutable tag would, it just does it once instead of on every retag.

**Automating this instead of doing it by hand:** [`pinact`](https://github.com/suzuki-shunsuke/pinact) is a CLI built specifically for this — it scans workflow files, resolves every `uses:` tag to its SHA, adds the version comment, and (with Dependabot/Renovate configured per item 2 above) can re-run on version-bump PRs to keep pins current. Worth adopting instead of doing the initial pass by hand across ~18 workflow files.

## Scope

Audit and update workflow files in:
- fluent-api (`.github/workflows/`)
- fluent-web (`.github/workflows/`)
- fluent-ai (`.github/workflows/`)
- fluent-mobile (`.github/workflows/`)

fluent-platform has no workflows today; add this as a standing requirement for any it gains later, rather than a one-time task.

## Notes

- Do this as its own PR per repo, separate from any feature work — it's a mechanical, repo-wide change and easier to review in isolation.
- `dependabot-workflow.md` already exists in fluent-api's repo root — check whether Dependabot is already configured for any ecosystem there and whether `github-actions` just needs to be added to the existing config, rather than set up from scratch.
