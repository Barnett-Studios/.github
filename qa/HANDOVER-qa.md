# QA Loop Handover — drive the published components, file what you find

**Cold start: assume no prior context.** Everything is in this file, the rotation log, or `main`.

**This file is re-issuable.** Sessions die of context bloat. When yours does, a fresh session gets
this file and loses nothing — because findings live in **issues**, not in your context. That is also
the entire output of this role.

Adapted from the Scriptorium three-loop pattern
(`lyubomir-bozhinov/scriptorium:docs/handovers/`). The shape is the same; the subject is not.
There is no deployed web app here — the product is **nine published components**, and the user is a
developer in *any* agent harness who has never cloned the repo.

---

## Scope

Nine public repos, the AI-SDLC component family:

| repo | shipped as | what it is |
|---|---|---|
| `baseplate` | crates.io + ghcr | shared substrate |
| `attestr` | crates.io + ghcr | Verifier |
| `cascadr` | crates.io + ghcr | provider cascade / Router |
| `cxpak` | crates.io + ghcr | Context Engine |
| `commitward` | crates.io + ghcr | HITL policy gate |
| `abproof` | crates.io + ghcr | A/B proving ground |
| `cordon` | ghcr + release assets | sandbox |
| `slicr` | ghcr | planner producer |
| `corpus` | git tags | RED-baseline eval set |

Explicitly **out of scope**: `PixCrunch`, `mfx-starter`, `mticky`, `homebrew-tap`, and the private
`dotclaude` assembly except as the integration target in §Assembly pass.

## Shape

- **Opens no PRs. Touches no code.** The entire output is well-classified issues.
- Never merges. Never re-classifies someone else's issue — comment instead; the Reviewer adjudicates.
- Costs no CI, which is what makes running it continuously affordable.

---

## The ghost check — before every single pass

```sh
qa/ghost-check.sh --boot      # in a clone of Barnett-Studios/.github
```

**Four halves, in increasing order of strength.**

1. **Provenance** — `:latest`'s `org.opencontainers.image.revision` is exactly the commit its own
   version tag points at, and that commit is an ancestor of `main`.
2. **Reach** — `latest` resolves to the same *digest* as the newest semver tag, anonymously.
3. **Crate** — for the six crates.io members, the published max version equals the newest tag and
   nothing in the line is yanked.
4. **Boot** — (`--boot`) the image actually executes.

**Halves 2–4 all compare one published thing to another published thing.** They can be green
together while the image was built from the wrong source; only half 1 can see that. This is not
theoretical — mutating the recorded revision turns half 1 red on all eight components while halves
2–4 stay green throughout.

Half 2 exists because a consumer runs `docker pull`, which resolves `latest`. If it lags they
silently receive old code while every version *string* still agrees, which is why the comparison is
on **digests**, not names.

**Scriptorium's anchor does not port, and this is the trap worth naming.** There, half 1 compares
the deployed SHA against `git ls-remote origin main`, because Scriptorium continuously deploys
`main`. This family ships **releases**, so `main` running ahead of the newest tag is the normal
state *between* releases — measured 2026-08-14, it is +2 to +15 commits on all nine repos. Gating
on it would fire everywhere, every pass, forever, and the loop would learn to ignore its own red.
The reference here is the **tag**; `main`-lag is advisory context only. Do not "fix" this by
re-adding a main-vs-published gate.

The check runs **anonymously on purpose**. A token with `read:packages` would exercise a path no
consumer walks, and would go green against an image that had silently become private.

**If it goes RED, stop and report.** A QA loop filing against a stale or unreachable artifact
generates confident, wasteful, wrong tickets that survive triage and cost a real implementation
attempt against behaviour that no longer exists. A missed bug costs one pass; a ghost bug costs a
whole ticket lifecycle and teaches everyone to distrust this loop.

`corpus` drift reports **WARN, not FAIL**, deliberately. A red ghost check means *"your findings
this pass are untrustworthy"*. Corpus tag drift does not make a finding about `cascadr` wrong, so
gating every pass on it would train the loop to ignore its own red.

---

## Each pass

1. **Ghost check.** Above. Both halves.
2. **Re-test any silent-failure fix that reached a release since your last pass** — verbatim repro,
   assert the consequence and not the indicator. This is the one thing nothing else in the factory
   can do: CI cannot catch a wrong fix to a silent defect, because a green suite is what the defect
   produced in the first place.
3. **Pick a component and a surface — prefer one nobody has driven.** An unexercised surface
   outranks re-testing an exercised one. A clean pass on a driven surface is data; silence from a
   never-driven one is *absence of evidence*, and reading it as evidence of absence is how defects
   sit for months. End every pass with the `never driven:` line so the next session picks without
   re-deriving the list.
4. **Drive the documented path, as an outsider, from a scratch directory.** Not a clone with the
   repo's own fixtures — the README's install instructions, run verbatim, in a fresh dir. If the
   README says `curl` the release asset and verify the checksum, do exactly that.
5. **Then check the promise, not just the smoke.** Every repo has a `CONTRACT.md`. It states
   guarantees in testable language (`exit 0 ⇔ solved`, `--network none`, `absent ⇒ SKIPPED, never
   failed`). Drive those directly. A component that boots and violates its contract is the
   higher-value finding.
6. **File what you find.** Below.
7. **Log the pass.** Below — whether or not you found anything, especially if you did not.

### Assembly pass

Once per cycle, after the per-component passes: run `dotclaude` against the **published** components
via `LLM_COMPONENT_MODE` / `ComponentInvoker` rather than the in-tree originals, and check that each
fail-open path actually fails open. The seam between a component and its consumer is where two green
CIs can both be right while the pair is broken. Findings here get filed against the **component**
whose contract was violated, since `dotclaude` is private.

---

## Classification

The class lives in the **`class-*` label** and nowhere else. Not a title prefix, not a sentence in
the body — those read as classified to a human and are invisible to every query. Exactly one, on
every issue you file. Labels exist in all nine repos.

| class | for a published component | 
|---|---|
| **A** | consumer work lost or silently corrupted; **success reported while failing** |
| **B** | broken flow — a documented surface does not work for an outside consumer |
| **C** | broken promise — it runs, but violates a `CONTRACT.md` guarantee |
| **D** | rough edge — DX friction, confusing output. **Left open deliberately** |
| **E** | enablement — blocks shipping safely, *including the machinery that proves we can*: publish pipelines, release gates, CI |
| **N** | changes nothing about whether we can ship — dead code, docs drift, a misleading log line |

The working test: **a gate with a hole is `class-E`; a gate with a confusing message is `class-N`.**

`class-E` reads as user-facing and is not — its population is *"the factory works"*. The distinction
matters because a Coder queue excludes `class-D` and `class-N` outright, so a mislabelled `class-N`
is not merely miscounted, it is **unreachable**.

**The class is the only axis.** Do not add "or any `p0`" as a second one. The single exception is
`incident`, below, which is a carve-out rather than a second ordering.

---

## Provenance — every issue says when it broke

Establish **when the defect was introduced** before filing, and record the verdict verbatim in the
issue body. It changes what the right fix is, and it is the only way to tell discovery from
regression. Use the cheapest rung that answers it; do not start at the bottom.

1. **Bound it by what you already know** — your own rotation log, a release date, `git log` on the
   `VERSION` file or `Cargo.toml`. Usually enough, costs nothing.
2. **Read the history of the code** — `git log -S'<distinctive string>' --oneline` (pickaxe) finds
   exactly when a line appeared or vanished; far better than `git blame`, which reformatting resets.
3. **Bisect** only if 1–2 failed and the introducing commit changes the decision. Dedicated
   worktree, never the root.

| verdict | meaning |
|---|---|
| `Provenance: regression — <sha> (<date>, PR #N)` | working code was broken by an identified change |
| `Provenance: pre-existing — <sha or "predates <tag>">` | wrong since it was written |
| `Provenance: never-worked — <sha> (<date>, PR #N)` | shipped broken; never been correct |
| `Provenance: environmental` | no code change caused it |
| `Provenance: no-defect — <what this changes instead>` | nothing was broken |
| `Provenance: unknown — tried <X, Y>` | honest failure |

**`unknown` is legitimate and must stay legitimate.** A forced verdict is a fabricated one, and a
fabricated provenance is worse than none because it will be trusted.

**A `regression` verdict carries an obligation**: something should have caught it and did not. Name
the missing test in the issue.

---

## Filing discipline — this is where a QA loop goes wrong

A loop that files freely fills the queue with noise faster than it can be drained, and the first
thing discarded is the loop itself.

- **Search before filing.** `gh issue list -R Barnett-Studios/<repo> --state all --search "<symptom>"`.
  A duplicate is worse than a miss: it splits the discussion and spends a pick on work in flight.
- **One issue per symptom** — but **one issue per root cause** when several symptoms share one fix.
  Filing the symptoms separately splits a single fix across threads.
- **Exact reproduction**, runnable by someone else from a scratch directory. That is the entire
  value of the ticket.
- **Never file a bug you cannot reproduce twice** — and prefer reproducing by a *second, independent
  mechanism* (API and a fresh `git clone`; registry and `docker`). One mechanism reproducing twice
  mostly re-confirms your own bug.
- **Never file against a red ghost check.**
- **Quote the contract.** For a `class-C`, paste the `CONTRACT.md` sentence that is false. It turns
  an opinion into a verdict.
- **Classify at filing. Never leave it blank.** An unclassified issue is invisible to the queue
  query, which makes filing it and not filing it the same act.

**Regression triage beats breadth.** When a pass finds a regression, finish characterising it before
exploring further. A precisely-dated regression with a commit range is worth more than three vague
new bugs.

---

## Traps this loop has actually hit

Every one of these produced a *confident wrong conclusion* that survived until something else
contradicted it. They are here because each cost real time on the first pass (2026-08-13).

- **zsh's `:l` modifier eats your image tags.** `"ghcr.io/barnett-studios/$r:latest"` expands to
  `abproofatest:latest` — zsh applies `:l` (lowercase) to `$r`. The registry answers `denied`,
  which is **indistinguishable from a private image**, and the obvious reading is "the images are
  not public". Always `${r}:latest`. This one produced an entire false theory about stale docker
  credentials, complete with a `docker logout` "fix" that appeared to work.
- **A check that cannot fail is not a check.** `git show $t:VERSION | tr -d '\n' || echo absent` —
  the `||` never fires, because `tr` succeeds on empty input. Likewise a network-isolation probe
  using `curl` in an image with no `curl` reports `net-blocked` and proves nothing. Verify the
  probe can produce the failing answer before trusting the passing one.
- **crates.io names are not yours.** `cordon` and `corpus` on crates.io are unrelated third-party
  crates (`wgoodall01/cordon`, `DanCardin/corpus`). Comparing their versions to this org's `VERSION`
  manufactures a mismatch out of nothing. Check `.crate.repository` before believing a version.
- **`gh <cmd> --json` returns empty here** under the rtk hook. Verify through `gh api`. An empty
  result read as "no labels exist" is a silent false negative.
- **macOS ships bash 3.2.** No associative arrays — `declare -A` fails with `invalid option`,
  and under `set -u` the next line dies with `unbound variable`. The supported platform is macOS,
  so anything in `qa/` has to run on 3.2.
- **`echo "exit=$?"` after a pipe reads the last command in the pipe**, not your script. Redirect
  to a file and check the exit code on its own line, or you will report a passing run of `tail`.
- **Read the README before calling it broken.** `docker run cordon:latest --help` fails with
  rc=127, and cordon's README explicitly documents that image as *not* the sandbox — the swappable
  `<runtime>` argument, no entrypoint by design. The disclaimer was three paragraphs above the
  thing that looked like a bug.

---

## A broken substrate is an incident, not a ticket

If the publish pipeline, ghcr, or crates.io is the broken thing, it preempts the queue. Label it
**`class-N` + `p0` + `incident`**: `class-N` because the product's code is fine, `p0` + `incident`
because it preempts anyway. `incident` overrides the Coder queue's "never `class-N`" rule — that
rule exists so a session does not spend itself on deferred work, and an incident is the opposite of
deferred.

State: what is broken, the check's output **verbatim**, whether you remediated, whether it is fixed.
**Filing is necessary and not sufficient** — an un-actioned incident ticket is what a ten-hour
outage looks like.

Search before filing one. Two reports of the same outage five hours apart split the evidence and
make it look newer than it is.

---

## The rotation log — your passes ARE the bisection

One pinned `[qa-rotation-log]` issue in **`Barnett-Studios/.github`**. One log, one continuous
series, across all nine components.

**There must be exactly one.** The log bounds a regression to `<last-green>..<current>` *only if
every pass is one series*. Split across two issues and the last-green entry and the current entry
live in different logs, so the window cannot be computed — and it fails silently. If you find two,
consolidate before logging anything: keep the one holding the earlier passes, close the other as a
duplicate, unpin it.

One comment per pass. Terse, tabular, no prose:

```
pass 2026-08-13T00:00Z · ghost: agreement ✓ boot ✓ · corpus WARN (corpus#30)

component   surface driven                        result
cordon      release install + checksum            ok
cordon      CONTRACT: exit passthrough/net/124    ok
attestr     —                                     not driven

re-tested (silent-failure fixes): none pending
never driven: attestr verify · cascadr routing · cxpak context · baseplate ops ·
              commitward gate · abproof run · slicr plan · corpus loader · assembly
```

- **Record passes, not just failures.** A green result is the boundary that dates the next
  regression. A log of only failures cannot bound anything.
- **Always record the ghost-check verdict**, so a future reader can tell a product regression from
  a broken substrate.
- **End every entry with `never driven:`.** It is the working list the next session picks from, and
  the only place it exists.

---

## Stop list — the only reasons to stop

- **Ghost check red across two consecutive passes.** One is a publish in flight; two is a broken
  pipeline, and every finding after it is suspect.
- **A credential, token, or private key visible in any published artifact.** Stop immediately. Do
  not explore further, do not screenshot it, do not characterise the extent — that is the founder's
  call and further probing risks turning an observation into a disclosure.
- **Anything suggesting a published image can reach a private network or a real account.**
- **A sandbox escape in `cordon` that reaches the host.** File nothing publicly until the founder
  has seen it; a public repro is a published exploit.

Everything else is proceed — file it and take the next surface.

## Session hygiene

- **Findings belong in issues, not your context.** Once filed, forget it.
- **Do not accumulate artifacts locally.** Attach them to the issue.
- **Heartbeat once per pass**: one line — what you drove, what you filed, what you are blocked on.
- **When you notice yourself slowing, stop and ask for a fresh session.** This file is the handover;
  nothing is lost.
