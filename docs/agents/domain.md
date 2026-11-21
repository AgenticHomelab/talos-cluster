# Domain documentation for agents

This is a **single-context** repository. The vocabulary in
[`CONTEXT.md`](../../CONTEXT.md) is the canonical glossary. The
[agent operating model](operating-model.md) adds task/approval boundaries.

## Read before architectural changes

1. Read `AGENTS.md` and `CONTEXT.md`.
2. Read relevant ADRs in `docs/adr/`, especially:
   - `0001-app-local-flux-reconciliation.md` for independently reconciled
     platform and workload units;
   - `0002-git-owns-talos-configuration.md` for the Flux/Omni boundary;
   - `0008-retire-custom-maintenance-automation.md` for retired
     unattended runner/merge behavior.
3. Read the current target directory, its manifests and its runbook. An
   ADR defines a decision, while dated reports document observations.

## Actual repository structure

```text
/
├── AGENTS.md
├── CONTEXT.md
├── README.md
├── docs/
│   ├── adr/
│   └── agents/
├── kubernetes/
│   ├── clusters/talos-home/
│   ├── flux/repositories/
│   ├── kustomization.yaml
│   ├── applications/
│   ├── infrastructure/
│   └── observability/
└── scripts/
    ├── cluster-template.yaml.in
    └── patches/
```

The glossary distinguishes **Reconciliation Units**, **Platform Units**,
**Workload Units**, **Talos Source Configuration**, **Omni API Access Path**,
**Service Audience** and recovery/availability classes. Use these terms
consistently in PRs, documentation, issues and tests. Do not replace them
with ambiguous synonyms that `CONTEXT.md` specifically discourages.

## Changes to the model

If a proposal contradicts an accepted ADR, make the conflict explicit.
An agent may propose a revised ADR and related manifests in a reviewed PR;
it must not silently reinterpret an architectural decision or expand its
own permissions. Create a new ADR only when a meaningful architectural
decision actually changes, not as generic process overhead.
