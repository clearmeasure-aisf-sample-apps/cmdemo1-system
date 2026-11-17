# Decision: Reshape tdd gate (smoke on merged main only)

**Issue:** [clearmeasure-aisf-sample-apps/cmdemo1-system#658](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-system/issues/658)  
**Related:** PR environments plan item 18 (required pre-merge check), item 19 (this decision), item 22 (pool slots)  
**Date:** 2026-11-16  
**Status:** Approved — decision record only; tdd is not thinned yet.

---

## Context

PR environments are becoming the required pre-merge gate (workorders #1672 / plan item 18). Once that gate is in place, the tdd environment no longer needs to carry a full acceptance-test suite on every pull request. The tdd gate should become a thin smoke gate that runs only on merged main, after the PR environment check has passed.

## Decision

**tdd becomes a smoke gate on merged main only.** The real AI model stays on tdd. Pool slots keep the stub.

### What changes

| Aspect | Before | After |
|---|---|---|
| **tdd gate timing** | Runs on every PR to main (full suite) | Runs only on merged main (smoke only) |
| **Pre-merge gate** | None (tdd was the gate) | "PR environment" (workorders #1672 / plan item 18) |
| **AI model on tdd** | Real model | Real model (unchanged) |
| **Pool slots** | Keep the stub | Keep the stub (unchanged) |

### What does NOT change

| Aspect | Status |
|---|---|
| **uat** | Sign-off by the pipeline team, auto-promote (unchanged) |
| **prod** | Sign-off by the pipeline team, auto-promote, prod restore point (unchanged) |
| **Pipeline files** | No changes to `.github/workflows/` (not thinned yet) |
| **Workflow files** | No changes to workflow definitions |
| **Infrastructure** | No changes to `infra/` |
| **Octopus config** | No changes to `octopus/` |

## Rationale

1. **No gates are loosened.** The PR environment becomes the required pre-merge check (item 18), so every PR still has a gate before merge.
2. **tdd is not thinned out.** The real AI model stays on tdd; pool slots keep the stub. Only the gate timing changes — from PR-time to post-merge.
3. **This is a decision record only.** No pipeline, workflow, infra, or Octopus files are changed. The actual thinning of tdd happens after item 18 makes "PR environment" required.

## Done when

- The decision record is in the repo.
- tdd is documented as smoke on merged master only, after the required-check change in item 18.
- uat and prod stay as they are: Sign-off by the pipeline team, auto-promote, and the prod restore point.

## Notes

- This decision does not modify any `.github/workflows/`, `.github/rulesets/`, Qodana config, or baselines.
- The real thinning of tdd (removing the full suite from PR-time) is a separate change that happens after item 18 is complete.
- Pool slots keep the stub (item 22).
