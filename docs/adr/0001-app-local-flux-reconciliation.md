# Use app-local Flux reconciliation units

Platform capabilities and user workloads are kept together under `kubernetes/` as independently owned reconciliation units. Explicit `dependsOn` relationships express hard prerequisites instead of broad infrastructure phases, preserving local ownership and making the real dependency graph reviewable.

Since 2026-11 the units are grouped into `applications/`, `infrastructure/` and `observability/` category directories. This is filesystem organization only: the categories are not Flux phases, ownership boundaries or dependency tiers, and the decision against broad infrastructure phases is unchanged.
