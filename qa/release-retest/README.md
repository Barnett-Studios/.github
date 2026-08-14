# release-retest

A clean-room consumer of the **published** crates, pinned to defects that are fixed on `main`
but not in the release. It is the executable half of `ghost-check.sh`'s currency check.

```bash
cd qa/release-retest && cargo test -- --nocapture
```

## Reading the result

**Passing is the alarm state.** Every assertion here documents *current published behaviour*,
and each one is a defect. A green run means the release still carries all of them.

A **failure is the trigger firing**: a release changed the behaviour, so go re-verify that
component's issues against the new artifact and update or delete the case.

That inversion is deliberate. A harness that goes red when things are broken tells you nothing
new here — the brokenness is already filed. What is worth an alert is the *transition*, and the
only way to catch a transition with a test is to assert the state you expect to end.

## What it covers

| Assertion | Issue | State on `main` |
|---|---|---|
| `filter_child_env` forwards `ANTHROPIC_BASE_URL` into the `claude -p` child | cascadr#9 | fixed, PR #20, unreleased |
| `is_java_test_file("ToolKIT.java")` is true | baseplate#5 | fixed, PR #14, unreleased |
| `framework_root()` ignores `$BASEPLATE_HOME` inside a git tree | baseplate#3 | unchanged — closed as resolved-by-the-fold (#4) |
| `framework_root()` resolution depends on the filesystem | baseplate#3 | unchanged, same reason |

The first two are release lag. The third and fourth are not: `main`'s `framework_root` is
byte-identical to the published one, so those two cases fail only if the fold lands or someone
patches `paths`. Keeping the distinction visible here is the point — "fixed but unreleased" and
"decided against" look identical in a green ghost check and need different follow-ups.

## Requires

Network (crates.io) and a Rust toolchain. Nothing else — no containers, no credentials, and no
Max20: the cascadr case calls the public `filter_child_env` directly and never spawns `claude`.
