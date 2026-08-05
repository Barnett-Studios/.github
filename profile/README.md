# Barnett Studios

**Interface-bounded components for agentic coding harnesses.**

Each one is a standalone tool with its own contract, usable in any harness — not a plugin for a
framework you have to adopt first. Together they are an architecture: context goes in, integrity is
checked, evidence is kept, work is planned, and work is executed under isolation.

| Plane | Component | Status | What it is |
|---|---|---|---|
| **Context** | [cxpak](https://github.com/Barnett-Studios/cxpak) | Active | Indexes a repo with tree-sitter across 43 languages and emits token-budgeted context bundles — a briefing packet instead of a flashlight in a dark room. |
| **Memory** | *(persistence — not yet published)* | — | Durable cross-session state. No repo yet; the row is here because the gap is deliberate, not overlooked. |
| **Integrity** | [attestr](https://github.com/Barnett-Studios/attestr) | Active | Promise-Theory verification. Assesses a turn's output against the promises its agent declared and emits findings plus a per-agent trust delta — telemetry, never a signal fed back into the live loop. |
| **Integrity** | [commitward](https://github.com/Barnett-Studios/commitward) | Active | A deterministic, fail-open human-sign-off gate. Blocks a high-stakes commit only when a guarded change fires and nobody acknowledged it; anything else lets the commit through. |
| **Oracle / evidence** | [corpus](https://github.com/Barnett-Studios/corpus) | Stable | 250 RED-baseline seed projects across 6 languages — and the per-node validity census establishing which 230 of them function as a measurement instrument at all. |
| **Oracle / evidence** | [abproof](https://github.com/Barnett-Studios/abproof) | Stable | Offline A/B change-validation for a whole harness. Seed-blocked pairing, statistical gating, and an `UNDERPOWERED` verdict for a battery that could not have detected an effect — rather than borrowing a PASS from it. |
| **plan → execute seam** | [slicr](https://github.com/Barnett-Studios/slicr) | Stable | Decomposes a task into a granular execution manifest — single-region nodes, each with a discriminating acceptance test authored up front. The producer half of the seam, and the schema is the contract. |
| **Executor: routing** | [cascadr](https://github.com/Barnett-Studios/cascadr) | Stable | A cost-ordered, fail-open provider cascade. It exists because a subscription cockpit's hop cannot be routed through a proxy without breaking prompt-cache integrity — so that rung must stay a direct call, and no general-purpose proxy can serve it. |
| **Executor: isolation** | [cordon](https://github.com/Barnett-Studios/cordon) | Stable | Runs one command in a hardened, ephemeral, network-isolated container, so a runaway generated process becomes a bounded, classified failure instead of a hang. |
| — | [baseplate](https://github.com/Barnett-Studios/baseplate) | Folding | A shared-substrate crate that never earned an architectural position. Its contents are moving to the components that actually use them, in the open. Nothing is archived and no published version is yanked. |

### What the statuses mean

- **Active** — under development; the surface still moves.
- **Stable** — feature-complete, maintenance only. The scope is *finished*, not abandoned. Quiet
  commit activity here means the thing is done.
- **Folding** — being dissolved into its consumers on purpose. A repo that explains its own
  dissolution is a better signal than one that goes quiet.

### Reading the estate

Small is not the same as thin on substance. `cascadr` and `cordon` are each a few hundred lines,
because each exists to hold exactly one constraint that a general-purpose alternative cannot hold.
Their READMEs lead with that constraint rather than a feature list — if the constraint doesn't
apply to you, you don't need the component, and that is the honest answer.

---

The org also hosts work unrelated to this toolkit —
[PixCrunch](https://github.com/Barnett-Studios/PixCrunch),
[mfx-starter](https://github.com/Barnett-Studios/mfx-starter),
[mticky](https://github.com/Barnett-Studios/mticky) — plus
[homebrew-tap](https://github.com/Barnett-Studios/homebrew-tap), which is distribution
infrastructure for the components above.
