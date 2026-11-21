# Service exposure

Every exposed service declares its Service Audience on the owning resource with `network-exposure`. The unqualified key is independent of the private DNS zone. The annotation is policy metadata: DNS publication still requires an explicit ExternalDNS annotation, and network reachability still depends on ingress, MetalLB and firewall configuration.

Web ingress has two independent network planes backed by the same Traefik Deployment:

- the **internal plane** uses `websecure` through `${TRAEFIK_LAN_IP}` and is reachable only from the LAN/Tailnet boundary;
- the **public plane** uses `websecure-pub` through `${TRAEFIK_PUBLIC_IP}` and is the only Traefik HTTPS target of the WAN destination-NAT rule.

A web route must belong to exactly one of these planes. Public routes must not bind the internal HTTPS entrypoint, and `internal` routes must not bind the public HTTPS entrypoint. The internal Service also owns BorgWarehouse TCP/2222; that port is not exposed by the public Service.

## Current audiences

| Service | Audience | Exposure |
| --- | --- | --- |
| AIostreams | `internal` | Internal HTTPS ingress; legacy public ExternalDNS publication remains intentionally out of scope for this hardening iteration and does not create a WAN route |
| books | `internal` | Internal HTTPS ingress; legacy public ExternalDNS publication remains intentionally out of scope for this hardening iteration and does not create a WAN route |
| Immich | `internal` | Git enables both Flux Kustomizations (`suspend: false`) and configures internal HTTPS `immich.${BASE_DOMAIN}` on `websecure` only; ExternalDNS target `traefik.${BASE_DOMAIN}`, Cloudflare proxy disabled, TLS issuer `letsencrypt-prod`. Read-only checks on 2026-10-30 confirmed reconciled resources, but current live ingress and application acceptance are not verified. DB/ML/Valkey are namespace-internal with ingress isolation, not separately published; see [Immich operations](immich.md) |
| Matrix Synapse | `public` | Public HTTPS ingress at `matrix.${BASE_DOMAIN}` |
| Matrix discovery | `public` | Public HTTPS ingress for the `${BASE_DOMAIN}` Matrix well-known paths |
| Matrix Authentication Service | `public` | Public HTTPS ingress at `matrix-auth.${BASE_DOMAIN}` |
| Matrix Element | `internal` | Internal HTTPS ingress at `chat.${BASE_DOMAIN}` |
| Hermes | `internal` | Tailscale-only HTTPS on the OCI control server; legacy cluster ingress retired |
| Mumble | `public` | Dedicated TCP/UDP MetalLB address and public ExternalDNS |
| Valheim | `public` | Dedicated UDP MetalLB address and public ExternalDNS |
| Authentik | `internal` | Internal HTTPS ingress and Cloudflare DNS to the internal Traefik address |
| BorgWarehouse | `internal` | Internal HTTPS plus TCP/2222 on the internal Traefik Service |
| TrueNAS | `internal` | Internal HTTPS ingress and Cloudflare DNS to the internal Traefik address |
| Vaultwarden | `internal` | Internal HTTPS ingress and Cloudflare DNS to the internal Traefik address |
| whoami | `internal` | Internal HTTPS ingress and Cloudflare DNS to the internal Traefik address |
| Traefik internal | `internal` | `${TRAEFIK_LAN_IP}`; HTTP/HTTPS and BorgWarehouse TCP/2222 |
| Traefik public | `public` | `${TRAEFIK_PUBLIC_IP}`; HTTP/HTTPS only |

Cloudflare is authoritative for `${BASE_DOMAIN}`. Private web names resolve to the internal Traefik address, while public names resolve through the home public endpoint and OPNsense forwards HTTPS to the public Traefik plane. This keeps the same route boundary on LAN and WAN instead of relying on DNS secrecy.

New services default to `internal`. Making a service public requires its own authentication and threat-model decision; adding a DNS record alone is not such a decision.

Validate the source manifests without contacting the live cluster:

```bash
./scripts/validate-service-audiences.sh
```

The validator rejects exposed sources whose audience is missing or outside the canonical vocabulary. It also rejects public web routes on the internal HTTPS entrypoint, internal web routes on the public HTTPS entrypoint, and exposed resources labelled `port-forward`. `scripts/tests/public-ingress-boundary-test.sh` additionally locks the Traefik Service port split, public-route allowlist and MetalLB VIPs.
