# Private-first publication readiness

AgenticHomelab/talos-cluster was published from a reviewed, sanitized root
commit on 2026-11-21. The production Flux source switched separately after
operator approval. The original GitOps history and the independent
`homelab-secrets` source remain private.

## Maintain the publication boundary

- Keep credentials, generated Talos and Omni identities, kubeconfigs, age
  identities, OpenTofu state, live backup artifacts and sensitive host data
  outside Git. ExternalSecret declarations do not establish that a source tree is safe for publication.
- Make examples reusable without disclosing unnecessary internal addressing,
  DNS/Tailnet topology, account identifiers, service tokens, credential
  recovery paths or administrative endpoints. Review the exposure of
  operational metadata and threat-model details, not just plaintext secrets.
- Preserve the boundaries between Flux-managed Kubernetes state, Omni/Talos
  lifecycle and independently managed OCI/Hermes/identity systems.
- Prefer narrow PRs, exact-head validation, operator-only merges, least-privilege
  GitHub workflows and documentation that reflects the installed state.
- Separate reusable general guidance from private incident reports and recovery
  custody. Remove sensitive material only with an approved plan that preserves
  the operator's private recovery evidence.

## Publication go/no-go, only when explicitly requested

1. Inventory **every tracked file in the candidate export** and all copied
   documentation, scripts, workflow files, metadata and bundled artifacts for
   secrets and operational data. Do not copy any candidate secret value into a
   GitHub issue, CI log or PR. The existing private repository and its history
   remain private and are not part of the export.
2. Review independent OCI signing and Git deploy-key custody, historical recovery identities, bootstrap dependencies, recovery
   runbooks, Flux deploy-key identity, the Omni control plane and OCI/Hermes
   cross-repository links. Check whether any disclosed credentials or access
   endpoints need rotation or redesign before publication.
3. Review GitHub App installation permissions, deploy keys, workflows, token
   scopes, Renovate configuration, branch rules and fork/PR execution risks.
   Public main requires pull requests and a strict `desired-state` check
   from GitHub Actions. These protections apply to administrators. External
   fork workflows require approval.
4. Review all documentation, screenshots, manifests and files selected for
   the new repository for personal or infrastructure metadata. Choose a license
   and third-party notice policy explicitly; there is no automatic license choice.
5. Create a **new, history-free repository** from the independently reviewed,
   sanitized current source tree, only after explicit publication authorization.
   Do not make `antief/talos-homelab` public, transplant its branches or tags,
   copy its commit history, or rewrite that history. Keep the original private
   repository available for operational and historical reference.
6. Validate the new repository independently before enabling public access.
   Review its initial commit, copied files, GitHub configuration, workflows,
   permissions and any accidental links to private sources. Never assume that
   starting with an empty history makes the exported content safe.
7. Plan the **separate, explicitly approved Flux migration** only after the
   new public repository has passed its security review. Review the
   GitRepository URL, authentication/deploy credentials, reconciliation
   ownership, bootstrap dependencies, rollback and recovery path. Verify
   continuity of running workloads and reconciliation after switching the
   cluster's source. Do not switch the live source during cleanup.
8. Record the publication decision and obtain explicit operator approval
   before creating or exposing the new public repository or cutting over Flux.
   Continue keeping environment-specific private configuration and recovery
   secrets outside the public source.

None of these checks implies that the repository has passed a security audit.
Do not perform publication-related mutations during routine documentation
maintenance.
