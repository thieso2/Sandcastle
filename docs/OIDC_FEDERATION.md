# Sandcastle as an OIDC Identity Provider

Sandcastle can issue short-lived OIDC tokens that identify a specific sandbox. External cloud providers (GCP, AWS, Azure, HashiCorp Vault, …) that support **Workload Identity Federation** can verify these tokens and hand back cloud credentials — **no long-lived cloud keys ever live in a sandbox**.

This is the same pattern GitHub Actions uses: the CI runner gets an OIDC token from GitHub, exchanges it at `sts.amazonaws.com` (or GCP's STS), and proceeds with scoped, time-bound access.

## Why

The alternatives all have sharp edges:

- **Paste an AWS key / GCP service-account JSON into the sandbox** — a compromised sandbox leaks a long-lived credential. Rotation is manual and easy to forget.
- **Run a per-user vault agent in every sandbox** — heavy, stateful, and hard to reason about across 100 sandboxes.
- **Use the user's own workstation credentials via SSH forwarding** — the user has to be present, CI can't use it, and laptop creds are broader than what the sandbox should have.

OIDC federation sidesteps all of that:
- A sandbox compromise leaks a token that expires in 15 minutes and is scoped to one cloud role.
- Rotation is automatic — Sandcastle just mints a fresh token every few minutes.
- The token's claims (`user`, `sandbox`, `email`, `image`) are verifiable on the cloud side, so trust policies can scope down to "only Alice's `web` sandbox can touch this bucket."

## How it works

```
┌─────────────────── SANDBOX ──────────────────┐
│                                              │
│  $ sandcastle-token --audience=gcp  ─────────┼──►  POST /oauth/token (per-sandbox secret)
│                                              │                │
│                                              │                ▼
│                                              │       Rails signs an RS256 JWT
│                                              │                │
│                                              │    ◄───────────┘ returns to sandbox
│  $ gcloud storage ls                         │
│    └─ reads cred-config JSON                 │
│       └─ reads /run/sandcastle/gcp-token  ◄──┼── JWT written by helper
└──────────────────────────────────────────────┘
                    │
                    │ POST sts.googleapis.com/v1/token
                    │   subject_token = <Sandcastle JWT>
                    ▼
            ┌──────────────┐   GET /.well-known/openid-configuration
            │   GCP STS    │   GET /oauth/jwks
            │              │──►  (back to Sandcastle, public, unauth'd)
            └──────┬───────┘   verifies JWT signature + claims
                   │
                   ▼
         federated access token
                   │
                   ▼  POST iamcredentials.googleapis.com/.../:generateAccessToken
         service account access token
                   │
                   ▼
         `gcloud storage ls gs://bucket`
```

The boundary is clean:
- **Sandcastle** mints and signs tokens. It doesn't know or care which clouds the user trusts.
- **The user** configures their own cloud account to trust the Sandcastle issuer URL. One-time setup per cloud, per GCP project / AWS account.
- **The cloud** decides what the sandbox gets — via normal IAM trust policies keyed on JWT claims.

## What exists today

| Piece | Status | Where |
|---|---|---|
| RS256 keypair loaded from `OIDC_PRIVATE_KEY_PEM` env (raw PEM or base64) | ✅ | `app/services/oidc_signer.rb` |
| `GET /.well-known/openid-configuration` (public) | ✅ | `app/controllers/oidc_controller.rb` |
| `GET /oauth/jwks` (public, cached 1h) | ✅ | `app/controllers/oidc_controller.rb` |
| JWT minting with full claim shape | ✅ | `OidcSigner.mint` |
| Rake tasks: `oidc:gen_key`, `oidc:mint`, `oidc:inspect`, `oidc:discovery`, `oidc:jwks` | ✅ | `lib/tasks/oidc.rake` |
| Unit + controller tests | ✅ | `test/services/oidc_signer_test.rb`, `test/controllers/oidc_controller_test.rb` |
| **In-sandbox CLI helper** (`sandcastle token --audience=...`) | ⏳ Next | `vendor/sandcastle-cli` |
| **Sandbox env injection** (per-sandbox secret + issuer URL) | ⏳ Next | `SandboxManager#container_env` |
| **Authenticated `/oauth/token` endpoint** | ⏳ Next | New `OidcTokenController` |
| **Pre-baked cloud cred-configs** in sandbox image | ⏳ Next | `images/sandbox/` |
| **User-facing guide + UI to generate cloud setup commands** | ⏳ Next | `guide.html.erb`, new settings page |
| **Key rotation** (multiple keys in JWKS during rollover) | ⏳ Later | `OidcSigner` |
| **Audit log** for token issuance | ⏳ Later | New table |
| **AWS, Azure, Vault** support (same IdP, different cred-configs) | ⏳ Later | docs + helper |

This PR is the **de-risking slice** — it proves Sandcastle's tokens are accepted by real GCP STS end-to-end, including service-account impersonation and a real `bq ls` call. The rest is plumbing.

## JWT claim shape

The `sub` format and attribute names are load-bearing — once users write cloud trust policies against them, changes are breaking. They're locked in:

```
iss          https://{SANDCASTLE_HOST}
sub          sandcastle:user:{username}:sandbox:{sandbox_name}     # ≤ 127 chars (GCP limit)
aud          (passed in per cloud — e.g. the GCP provider URI)
iat          now - 30s                                             # clock skew buffer
nbf          now - 30s
exp          now + 15 min
jti          UUID v7
user         {username}
sandbox      {sandbox_name}
sandbox_id   {sandbox.id}
email        {user.email_address}
image        {sandbox.image}
```

Signed **RS256**, `kid` = first 8 hex chars of `SHA256(public_key_der)`.

### Picking claims for trust policies

| Cloud | Good pin | Use when |
|---|---|---|
| Single user, all their sandboxes | `attribute.user == 'alice'` | User has many sandboxes, all should access the same cloud resources |
| Single sandbox only | `attribute.user == 'alice' && attribute.sandbox == 'web'` | CI/prod-like sandbox isolated from experimental ones |
| Any user in an org | *(drop the condition; rely on principalSet)* | Multi-tenant Sandcastle hosts |

## Trying it (GCP)

The full runbook lives in `/docs/OIDC_FEDERATION_GCP.md` (TODO: written alongside the sandbox-side slice). Quick preview:

```bash
export PROJECT_NUMBER=$(gcloud projects describe $GCP_PROJECT --format='value(projectNumber)')
export ISSUER="https://$SANDCASTLE_HOST"

# 1. Pool + OIDC provider
gcloud iam workload-identity-pools create sandcastle --location=global
gcloud iam workload-identity-pools providers create-oidc sandcastle-prov \
    --location=global --workload-identity-pool=sandcastle \
    --issuer-uri="$ISSUER" \
    --attribute-mapping="google.subject=assertion.sub,attribute.user=assertion.user,attribute.sandbox=assertion.sandbox,attribute.email=assertion.email"

# 2. Bind permissions — directly on a resource, or via SA impersonation
#    (direct is what Google now recommends; impersonation is easier to migrate to)
gcloud iam service-accounts add-iam-policy-binding my-sa@$GCP_PROJECT.iam.gserviceaccount.com \
    --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/attribute.user/alice"
```

Once the sandbox-side slice lands, the sandbox will automatically write a fresh JWT to `/run/sandcastle/gcp-token`, and `gcloud storage ls` / `bq ls` / etc. Just Work™.

## Security model

### What the issuer exposes publicly

- Discovery document at `/.well-known/openid-configuration` — public URL is fine, contents are metadata.
- JWKS at `/oauth/jwks` — only the **public** half of the signing key. Safe.
- No endpoints leak user identity or sandbox existence.

### What the issuer keeps secret

- Private signing key (`OIDC_PRIVATE_KEY_PEM`).
- *(future)* Per-sandbox shared secrets used to authenticate the `/oauth/token` endpoint.

### What the cloud provider enforces

- JWT signature matches JWKS from the issuer's discovery doc.
- `iss` / `aud` / `exp` / `iat` / `sub` all pass standard OIDC checks.
- Trust policy conditions — e.g. `attribute.user` must equal something the cloud owner set.

### Blast radius of a compromise

- **Sandbox container compromise**: leaks a token valid for ≤ 15 min, scoped to exactly the cloud permissions the trust policy grants. The token is not reusable to mint other tokens.
- **Sandcastle web compromise**: an attacker with full Rails code execution can mint tokens for any user/sandbox combination and impersonate them in cloud APIs the user has set up. Same blast radius as gaining write access to the image-build pipeline of GitHub Actions. Mitigation: limit who can access Sandcastle admin, audit-log all `/oauth/token` calls once that lands.
- **Signing key leak**: attacker can mint tokens indefinitely until rotation. Mitigation: store the PEM the same way production stores `SECRET_KEY_BASE`. Rotation flow will publish two keys in the JWKS during rollover so cloud validators can accept both.

## Design decisions locked in

| Decision | Choice | Why |
|---|---|---|
| Algorithm | RS256 | Ubiquitous, GCP/AWS/Azure-supported, matches AIP-4117 |
| Key storage | `OIDC_PRIVATE_KEY_PEM` env var (PEM or base64) | Matches existing `SECRET_KEY_BASE` pattern. Base64 form sidesteps multi-line `.env` issues in foreman/docker-compose |
| `sub` shape | `sandcastle:user:{u}:sandbox:{s}` | Readable in cloud IAM policies. User+sandbox name caps keep length ≤ 127 chars |
| Token TTL | 15 min | Short enough to limit blast radius, long enough for most CLI commands |
| Clock skew buffer | `iat = now - 30s` | Absorbs drift without triggering "issued in future" errors |
| Validation depth (PoC) | End-to-end `bq ls` via SA impersonation | Catches bugs in impersonation URL + attribute mapping |

## Open questions for the next slice

- **How does the sandbox authenticate to `/oauth/token`?** Per-sandbox secret injected at container create (GH Actions style) is the leading candidate. Alternative: source-IP-based on the `sandcastle-web` bridge + reverse DNS of container ID.
- **Do we refresh the token file from a daemon or on demand?** Daemon is safer (always fresh); on-demand is simpler (fewer moving parts in the sandbox).
- **Opt-in per sandbox, or always-on?** Always-on means every sandbox can mint tokens (cheap — just signing a JWT). Opt-in adds a DB flag but lets users audit exposure.
- **Audit log schema**: issued_at, user_id, sandbox_id, audience, jti. Query surface for "show me every token minted for my sandbox last week."

## References

- [AIP-4117: External Account Credentials (Workload Identity Federation)](https://google.aip.dev/auth/4117) — canonical spec for the cred-config file format
- [GCP Workload Identity Federation with OIDC providers](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-providers)
- [RFC 8693 OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [OpenID Connect Discovery 1.0](https://openid.net/specs/openid-connect-discovery-1_0.html)
- GitHub Actions [`ACTIONS_ID_TOKEN_REQUEST_*`](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect) env vars — prior art for the sandbox-side env injection
