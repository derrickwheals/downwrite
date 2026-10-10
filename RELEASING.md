# Releasing Downwrite

How to cut a new version and get its DMG onto the [GitHub Releases](https://github.com/derrickwheals/downwrite/releases) page. Pushing a tag that starts with `v` is the whole trigger: `.github/workflows/release.yml` then tests, builds, packages, signs and notarizes (when credentials exist) and publishes the release.

## Quick version

```bash
git checkout main && git pull --ff-only          # the commit you tag is the commit that ships
git tag -a v0.9.3 -m "Downwrite 0.9.3"           # use the next version number
git push origin v0.9.3                           # starts the Release workflow
gh run watch                                     # optional: follow it (about 4–5 minutes)
gh release view v0.9.3 --web                     # check the result
```

## 1. Before you tag

1. Everything you want to ship is merged to `main` and your working tree is clean. The workflow builds exactly the tagged commit, so tag after the PR has merged, not before.
2. Pick the next version (semver, `MAJOR.MINOR.PATCH`). The latest so far is shown by `git tag --list 'v*' --sort=-v:refname | head -1`.
3. There is no version number to edit in the repo. The version comes from the tag (the leading `v` is stripped) and `scripts/build-app.sh` writes it into `Packaging/Info.plist` in place of `__VERSION__`; the build number (`__BUILD__`) is the workflow's run number. The `0.9.0` defaults inside `build-app.sh`, `make-dmg.sh` and the README examples only matter for local builds.
4. Make sure the tests pass: `scripts/linux-test.sh` (Core, anywhere Docker runs) and, on a Mac, `swift test` or `scripts/ci-local.sh`. The workflow runs `swift test` itself and publishes nothing if it fails, but it is quicker to find out locally.
5. Optional rehearsal on your own Mac: `VERSION=0.9.3 BUILD=1 scripts/build-app.sh && VERSION=0.9.3 scripts/make-dmg.sh` produces `dist/Downwrite-0.9.3.dmg` (ad-hoc signed unless you set `SIGN_IDENTITY`).

## 2. Tag and push

Use an annotated tag (`-a`) like the previous releases, and name it `v<version>`. Pushing the tag starts the workflow; nothing else needs to be pushed.

```bash
git tag -a v0.9.3 -m "Downwrite 0.9.3"
git push origin v0.9.3
```

## 3. What the workflow does

It runs on a `macos-26` runner:

1. Reads the version from the tag name (`v0.9.3` → `0.9.3`).
2. Runs `swift test` with a 10-minute timeout and fails the job if any test fails.
3. If the `DEVELOPER_ID_P12_BASE64` secret is set, imports the Developer ID certificate into a temporary keychain.
4. Runs `scripts/build-app.sh` with `VERSION` from the tag and `BUILD` from the run number, signing with `DEVELOPER_ID_NAME` when it is set and ad-hoc otherwise.
5. Runs `scripts/make-dmg.sh`, producing `dist/Downwrite-<version>.dmg`.
6. If `NOTARY_APPLE_ID` is set, submits the DMG to Apple with `notarytool --wait` and staples the ticket.
7. Uploads the DMG as a workflow artifact named `Downwrite-<version>`.
8. On a tag push only, runs `gh release create` with the title `Downwrite <version>`, auto-generated release notes and the DMG attached.

The signing and notarization secrets are set under the repository's Settings ▸ Secrets and variables ▸ Actions: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `DEVELOPER_ID_NAME`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` (an app-specific password). Without them the workflow still succeeds and publishes an ad-hoc signed, un-notarized DMG, and the signing and notarize steps show as skipped in the log.

## 4. Watch it

```bash
gh run list --workflow=release.yml --limit 3
gh run watch <run-id>
```

## 5. Check the release

1. The release page shows `Downwrite <version>` with `Downwrite-<version>.dmg` attached, not marked draft or pre-release, and carrying the Latest badge.
2. Download the DMG and, for a signed and notarized build, confirm Gatekeeper accepts it:
   ```bash
   spctl --assess --type open --context context:primary-signature -v Downwrite-<version>.dmg
   xcrun stapler validate Downwrite-<version>.dmg
   ```
   An ad-hoc build fails both, and on first launch macOS asks you to right-click ▸ Open.
3. Mount it, drag Downwrite to Applications, launch it and confirm Settings ▸ General shows the new version.

## Release notes

`--generate-notes` fills the notes from the pull requests and commits merged since the previous release. To tidy them afterwards, edit the release on GitHub or run `gh release edit v<version> --notes-file notes.md`.

## Dry run without publishing

Actions ▸ Release ▸ Run workflow, enter the version without the `v` (or `gh workflow run release.yml -f version=0.9.3`). That runs the same build, test and packaging steps and uploads the DMG as a workflow artifact, but creates no tag and no release because the publish step only runs for tag pushes.

## When something goes wrong

- **Tests or the build fail:** no release is created. If the cause is on `main`, fix it through a normal PR, then move the tag to the fixed commit: `git tag -d v0.9.3 && git push origin --delete v0.9.3`, then tag and push again. If it was a transient runner problem, `gh run rerun <run-id> --failed` is enough.
- **The release exists but the DMG is wrong:** `gh release delete v0.9.3 --cleanup-tag --yes` removes the release and its tag, then tag again. If anyone could already have downloaded it, ship the next patch version instead of reusing the number.
- **Re-running after the publish step succeeded** fails because the release already exists; delete it first as above.
- **No GitHub Actions minutes:** build, sign, notarize and staple on your own Mac following the README's *Deployment* section, then publish with `gh release create v<version> dist/Downwrite-<version>.dmg --title "Downwrite <version>" --generate-notes`.
