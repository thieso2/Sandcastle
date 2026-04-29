# Sandcastle as an OIDC Identity Provider

Sandcastle can issue short-lived OIDC tokens that identify a specific sandbox. External cloud providers (GCP, AWS, Azure, HashiCorp Vault, …) that support **Workload Identity Federation** can verify these tokens and hand back cloud credentials — **no long-lived cloud keys ever live in a sandbox**.

For the operational GCP setup guide, see [GCP_OIDC_SETUP.md](GCP_OIDC_SETUP.md). This document is the architecture and security reference.

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
│  $ sandcastle-oidc token --audience=gcp  ────┼──►  POST /internal/oidc/token
│                                              │                │
│                                              │                ▼
│                                              │       Rails signs an RS256 JWT
│                                              │                │
│                                              │    ◄───────────┘ returns to sandbox
│  $ gcloud storage ls                         │
│    └─ reads cred-config JSON                 │
│       └─ invokes sandcastle-oidc executable ─┼──► fresh JWT on demand
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
| **In-sandbox Go helper** (`sandcastle-oidc token --audience=...`) | ✅ | `images/sandbox/oidc-helper` |
| **Sandbox runtime secret injection** (per-sandbox secret + issuer URL) | ✅ | `SandboxManager#setup_oidc_runtime` |
| **Authenticated internal token endpoint** (`POST /internal/oidc/token`) | ✅ | `Internal::OidcTokensController` |
| **GCP executable cred-config writer + file refresher** | ✅ | `sandcastle-oidc gcp ...` |
| **GCP setup generation in UI/API/CLI** | ✅ | `GcpOidcSetup`, `sandcastle gcp ...` |
| **Transparent GCP credential injection** | ✅ | `/etc/sandcastle/gcp-credentials.json` |
| **Key rotation** (multiple keys in JWKS during rollover) | ⏳ Later | `OidcSigner` |
| **Audit log** for token issuance | ⏳ Later | New table |
| **AWS, Azure, Vault** support (same IdP, different cred-configs) | ⏳ Later | docs + helper |

The first slice proved Sandcastle's tokens are accepted by real GCP STS end-to-end, including service-account impersonation and a real `bq ls` call. The current slice adds sandbox-side runtime plumbing, setup generation, and transparent GCP credential injection.

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
| Single user, all their sandboxes | `attribute.user == 'alice'` | Default Sandcastle path; avoids per-sandbox IAM changes and propagation delays |
| Single sandbox only | `attribute.sandbox_id == '123'` | CI/prod-like sandbox isolated from experimental ones |
| Any user in an org | *(drop the condition; rely on principalSet)* | Multi-tenant Sandcastle hosts |

## GCP Integration

Sandcastle now generates the GCP setup data from the web UI and CLI. Create reusable Workload Identity configs in **Settings → GCP**. Each config represents one GCP project/pool/provider and one default read-only service account named `sandcastle-reader@PROJECT_ID.iam.gserviceaccount.com`. Sandboxes select a config and use that default service account automatically unless they explicitly set a custom service account override.

GCP Workload Identity pools use the fixed resource location `global`; Sandcastle does not expose this as a user-editable setting.

CLI config:

```bash
sandcastle gcp config create prod \
  --project-id "$GCP_PROJECT" \
  --project-number "$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')" \
  --pool sandcastle \
  --provider sandcastle

sandcastle gcp config setup prod
```

Per-sandbox identity:

```bash
sandcastle gcp configure devbox \
  --config prod \
  --scope user

sandcastle gcp setup devbox
```

The generated setup is equivalent to:

```bash
export PROJECT_NUMBER=$(gcloud projects describe $GCP_PROJECT --format='value(projectNumber)')
export ISSUER="https://$SANDCASTLE_HOST"
export AUDIENCE="//iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle"

# 1. Pool + OIDC provider
gcloud iam workload-identity-pools create sandcastle --location=global
gcloud iam workload-identity-pools providers create-oidc sandcastle \
    --location=global --workload-identity-pool=sandcastle \
    --issuer-uri="$ISSUER" \
    --allowed-audiences="$AUDIENCE" \
    --attribute-mapping="google.subject=assertion.sub,attribute.user=assertion.user,attribute.sandbox=assertion.sandbox,attribute.sandbox_id=string(assertion.sandbox_id)"

# 2. Allow the Sandcastle user principal to impersonate the service account
gcloud iam service-accounts add-iam-policy-binding my-sa@$GCP_PROJECT.iam.gserviceaccount.com \
    --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/attribute.user/$SANDCASTLE_USER"
```

Once the setup commands have been run in GCP, Sandcastle writes `/etc/sandcastle/gcp-credentials.json` and exports `GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`, `CLOUDSDK_CORE_PROJECT`, `GOOGLE_CLOUD_PROJECT`, and `GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1` when the sandbox starts. `gcloud storage ls` / `bq ls` / client libraries can then use the configured service account without any manual setup inside the sandbox.

### Inside an OIDC-enabled sandbox

OIDC is controlled by a user default plus a per-sandbox override, like VNC/SMB/Docker. When enabled, Sandcastle injects a sandbox-scoped runtime token into `/run/sandcastle/oidc-token` and non-secret metadata into `/etc/sandcastle/oidc.env`.

Mint a raw OIDC token:

```bash
sandcastle-oidc token --audience "$AUDIENCE"
```

For manual GCP executable-sourced Workload Identity Federation:

```bash
export AUDIENCE="//iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle"

sandcastle-oidc gcp write-config \
  --audience "$AUDIENCE" \
  --output ~/.config/gcloud/sandcastle-cred-config.json \
  --service-account "my-sa@$GCP_PROJECT.iam.gserviceaccount.com"

gcloud auth login --cred-file ~/.config/gcloud/sandcastle-cred-config.json
```

Sandcastle sets `GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1` in OIDC-enabled sandboxes so Google auth libraries can invoke `sandcastle-oidc gcp executable` when they need a fresh subject token. For tooling that only supports file-sourced credentials, keep a token file refreshed explicitly:

```bash
export AUDIENCE="//iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle"

sandcastle-oidc gcp refresh \
  --audience "$AUDIENCE" \
  --output-token-file /run/sandcastle/oidc/gcp.jwt

sandcastle-oidc gcp write-config \
  --audience "$AUDIENCE" \
  --mode file \
  --token-file /run/sandcastle/oidc/gcp.jwt \
  --output ~/.config/gcloud/sandcastle-cred-config.json \
  --service-account "my-sa@$GCP_PROJECT.iam.gserviceaccount.com"

gcloud auth login --cred-file ~/.config/gcloud/sandcastle-cred-config.json
```

## Security model

### What the issuer exposes publicly

- Discovery document at `/.well-known/openid-configuration` — public URL is fine, contents are metadata.
- JWKS at `/oauth/jwks` — only the **public** half of the signing key. Safe.
- No endpoints leak user identity or sandbox existence.

### What the issuer keeps secret

- Private signing key (`OIDC_PRIVATE_KEY_PEM`).
- Per-sandbox runtime secrets used to authenticate the internal `/internal/oidc/token` endpoint. Only bcrypt digests are stored in the database.

### What the cloud provider enforces

- JWT signature matches JWKS from the issuer's discovery doc.
- `iss` / `aud` / `exp` / `iat` / `sub` all pass standard OIDC checks.
- Trust policy conditions — e.g. `attribute.user` must equal something the cloud owner set.

### Blast radius of a compromise

- **Sandbox container compromise**: leaks the current OIDC token and the sandbox runtime secret. The current token is valid for ≤ 15 min; the runtime secret can mint more tokens for that sandbox until the sandbox is restarted/rebuilt or OIDC is disabled.
- **Sandcastle web compromise**: an attacker with full Rails code execution can mint tokens for any user/sandbox combination and impersonate them in cloud APIs the user has set up. Same blast radius as gaining write access to the image-build pipeline of GitHub Actions. Mitigation: limit who can access Sandcastle admin, audit-log all `/internal/oidc/token` calls once that lands.
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

## Remaining work

- Background refresh daemon or systemd user service for file-sourced provider token files.
- Audit log schema: issued_at, user_id, sandbox_id, audience, jti.
- Key rotation with multiple active JWKS keys during rollover.
- AWS, Azure, and Vault setup helpers.

## References

- [AIP-4117: External Account Credentials (Workload Identity Federation)](https://google.aip.dev/auth/4117) — canonical spec for the cred-config file format
- [GCP Workload Identity Federation with OIDC providers](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-providers)
- [RFC 8693 OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [OpenID Connect Discovery 1.0](https://openid.net/specs/openid-connect-discovery-1_0.html)
- GitHub Actions [`ACTIONS_ID_TOKEN_REQUEST_*`](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect) env vars — prior art for the sandbox-side env injection
