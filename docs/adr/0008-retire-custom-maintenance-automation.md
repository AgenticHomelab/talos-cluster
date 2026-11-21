# Retire custom maintenance automation

Status: accepted 2026-10-12; repository source retirement completed. OCI host identity and recovery retirement are separate and NOT VERIFIED.

The bespoke Hermes maintenance project could issue reviews and merges through a
custom GitHub App runner. An ambiguous merge confirmation halted its lifecycle.
Independent GitHub evidence later confirmed the merge, but the original runtime
confirmation failure remains unproven. Disabled scheduling did not revoke App
permissions, and retaining an executable shadow implementation prolonged that
maintenance and privilege burden.

The repository removed the custom classifier, orchestrators, runner,
lifecycle mutation/recovery interfaces, publication workflow and full
reactivation designs. Keep ordinary
Renovate discovery with automerge disabled, exact-head CI, Flux reconciliation
and independently useful read-only health/security verification. Operators
manually review and merge dependency PRs.

The live saved halt and recovery evidence remain under OCI ownership. Private
incident metadata is retained outside this prospective public repository. Host
wrappers needed by disabled-job recovery remain intact; App grants and historical
images require an explicit owner decommission approval. Source removal is not
credential revocation or a claim that every external runtime is absent.
