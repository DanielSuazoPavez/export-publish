# export-publish

A reusable GitHub Actions workflow that publishes a trimmed export of a (typically private) source repo to a target repo. Each run builds the export, replaces the target's whole tree with it, commits and pushes when anything changed, and tags the target `v<version>` once. An existing tag is never moved. Only the source repo holds a credential: a deploy key with write access to the target. Nobody on the target side needs access to the source.

## Usage

```yaml
# .github/workflows/publish.yml in the source repo
on:
  push:
    branches: [main]

jobs:
  publish:
    uses: DanielSuazoPavez/export-publish/.github/workflows/publish-export.yml@<commit-sha>
    with:
      target-repo: example-org/example-export   # example target
      include: |
        README.md
        src
        docs/public -> docs
    secrets:
      deploy-key: ${{ secrets.EXPORT_DEPLOY_KEY }}
```

### Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `target-repo` | string | required | Target repository (`owner/name`) whose tree is replaced by the export. |
| `include` | string | `''` | Spec of paths to export (format below). Set exactly one of `include` / `build-command`. |
| `build-command` | string | `''` | Command run in the source checkout that fills `$EXPORT_DIR`. Set exactly one of `include` / `build-command`. |
| `version-command` | string | `python -c "import tomllib;print(tomllib.load(open('pyproject.toml','rb'))['project']['version'])"` | Command run in the source checkout that prints the version (`X.Y.Z`, optional `-pre`/`+build`, no leading `v`). |
| `ref` | string | `''` | Source ref to export. Empty means the `workflow_run` head SHA, else `github.sha`. |
| `python-version` | string | `'3.12'` | Python for `actions/setup-python`. |
| `dry-run` | boolean | `false` | Build the export and upload it as the `export` artifact; publish nothing, no key needed. |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `deploy-key` | unless `dry-run` | Private half of a **write** deploy key on `target-repo`. |

### Outputs

| Output | Description |
|--------|-------------|
| `version` | The published version. |
| `previous-version` | Newest `v*` tag on the target below `version`, without the `v`; empty when none. |
| `pushed` | `true` when the export changed the target tree and was pushed. |
| `tag-created` | `true` when this run created the `v<version>` tag. |

A run whose version is below the newest `v*` tag on the target fails without touching it, so a stale re-run or an out-of-order run cannot roll the target back. The outputs are empty on a `dry-run`. Use `tag-created == 'true'` to announce a release exactly once per version.

## Spec format

One entry per line:

```
# comments and blank lines are ignored

# a file, copied to the same path
README.md
# a directory, copied recursively
src
# src -> dest: copy under a different path
docs/public -> docs
```

Paths are relative to the repo root. Absolute paths, `..`, `.` and `.git` segments are rejected, as is a missing source. An export that contains a top-level `.git` (e.g. from a `build-command`) is refused at publish. A `#` comment must be on its own line.

## Deploy-key setup

1. Generate a key pair: `ssh-keygen -t ed25519 -N '' -C export-publish -f export-key`.
2. On the **target** repo: Settings → Deploy keys → add `export-key.pub` with **Allow write access**.
3. On the **source** repo: Settings → Secrets → Actions → add `export-key` (the private half) as `EXPORT_DEPLOY_KEY`.
4. Delete the local key files.

## Pin by commit SHA, never a branch

Reference the workflow as `@<commit-sha>`, never `@main` or a tag. The workflow receives your deploy key, so whatever code the reference resolves to can push to your target. A full SHA cannot be moved under you. The workflow checks out its own script at that same SHA (`job.workflow_sha`), so the script and the workflow always come from the same commit.

## Trying a spec

Run with `dry-run: true` and no secret. The job uploads the staged tree as the `export` artifact, so you can inspect it before creating a key.

## Local use and tests

`bin/export-publish stage <src-dir> <out-dir> <spec-file>` and `bin/export-publish publish <export-dir> <target-dir> <version> <source-label>` are the two steps the workflow runs. `bash tests/run.sh` tests them against a local bare repo.
