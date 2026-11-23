---
name: "release-automation"
description: "Use when triggering or discussing Iroru GitHub Actions releases: all-platform stable releases from main with change-based version selection, and Android Beta releases from other branches."
metadata:
  short-description: "Iroru GitHub Actions 发布流程与版本平台选择。"
---

# Release automation

All concrete version numbers in this skill are illustrative examples. Compute
each release version from the latest published stable release and the rules below;
examples such as `4.5.3`, `4.8.x`, `4.9.0`, and `5.x.x` are not fixed targets.

Resolve the release branch from the current local branch's upstream remote and
branch. If no upstream exists, use `origin` and the same branch name, establishing
that upstream when pushing. If HEAD is detached, ask which branch to use before
pushing or dispatching. Use this remote branch for both repository sync and release
workflow dispatch.

When a release is requested through a GitHub Actions workflow selected below,
and the user explicitly requests the full repository sync:

1. Inspect the working tree and include all current tracked and untracked changes in the requested commit.
2. Commit the changes with a Conventional Commit message matching the changes (`fix`, `feat`, or a breaking marker when appropriate). Include Beta branch context in the body, for example `Branch: feature/player`. The commit type determines whether the push starts a release.
3. Push only the current local branch to its resolved remote branch using an explicit refspec (`HEAD:refs/heads/<remote-branch>`).
4. Confirm that the remote branch points to the local release commit.
5. For the default channel, confirm the push-triggered `release_on_push.yml` run for that exact commit and capture its URL. Its planner parses Conventional Commit messages and computes the version; do not also dispatch a manual release for the same push.
6. Report the commit, remote branch, push result, and workflow URL, then finish the local release task. If the workflow is absent from the pushed branch, report the setup requirement using `docs/agents/push-release.md`.

For an explicit version, platform override, or manual-only release, use the selected
workflow's `workflow_dispatch` with the resolved branch, version, release notes
and exact `commit_sha` against an already-synced commit. When repository sync is
also requested, resolve the automatic default channel/version versus the explicit
manual override before pushing. Use one release entry point for the same change.
The selected commit must contain the current release configuration and Android
native/Gradle interface. Release workflows reject incompatible commits before
starting native builds.

Do not commit or push merely because a release workflow is being discussed;
those repository mutations require the user's explicit request. Keep the release
on the resolved branch; do not merge into or push `main` unless it is that branch.

GitHub Actions runs asynchronously after a push or dispatch. Treat the accepted push-triggered run or manual dispatch as the completion boundary for the local task. Do not wait for, poll, watch, or inspect the workflow's later build and release result unless the user explicitly asks for monitoring or verification.

When reporting an accepted push-triggered run or dispatch, state that the workflow was started and link to the run; for Beta releases, include the resolved remote branch name. Do not state that the release was published until a later verification is explicitly requested and completed.

## Release channel and platform selection

- When the resolved remote branch is `main`, use **Build and Release** (`build.yml`) for a stable release on all supported platforms, including PATCH updates. Select its version using the comparison below.
- Other branches default to Android Beta releases using **Build Android Beta and Pre-release** (`build_android_beta.yml`). An explicitly requested channel or platform overrides these defaults; explicit Beta requests also use this workflow.
- Before choosing or validating a Beta version, query the latest published stable release and list existing tags and releases for its next PATCH base, including drafts. Apply the Beta rule in [Commit-based version selection](../../../docs/agents/push-release.md#commit-based-version-selection) and report any mismatch before dispatching.
- Beta releases publish the Android arm64-v8a APK as a GitHub **Pre-release**, with `latest=false`. Follow the shared package, signing, and rollout rules in [Publication and queue](../../../docs/agents/push-release.md#publication-and-queue).
- Use **Build Android and Release** (`build_android.yml`) for an Android-only stable patch release only when the user explicitly requests that stable release.

## Stable version selection from main

Query the latest published stable release, excluding drafts and pre-releases, and
resolve its tag to the actual commit. Read full commit messages from that commit
to the intended main release commit. Apply [Commit-based version selection](../../../docs/agents/push-release.md#commit-based-version-selection).

Report the baseline, matching commits and selected level. For an explicit manual
version, validate the channel and tag availability before dispatching. If the
stable baseline cannot be resolved, request a baseline or version.

Before dispatching the selected workflow, verify that its tag and release do not
already exist. Dispatch against the resolved remote branch with the selected
version, release notes and exact commit SHA.
