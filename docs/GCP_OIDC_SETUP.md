# GCP OIDC Setup

This guide explains how to connect Sandcastle sandboxes to Google Cloud with Workload Identity Federation. The goal is that users never paste service account keys into sandboxes. Sandcastle injects short-lived external account credentials, and GCP decides which Sandcastle identities can impersonate which service accounts.

For the lower-level architecture and token format, see [OIDC_FEDERATION.md](OIDC_FEDERATION.md).

## Model

Sandcastle issues an OIDC token for a running sandbox. The token contains stable claims:

```text
user       Sandcastle username
sandbox    sandbox name
sandbox_id database ID of the sandbox
email      Sandcastle user email
```

The GCP Workload Identity provider maps those claims to attributes:

```text
google.subject       = assertion.sub
attribute.user       = assertion.user
attribute.sandbox    = assertion.sandbox
attribute.sandbox_id = string(assertion.sandbox_id)
```

GCP service account IAM decides who can impersonate a service account:

```text
attribute.user/thies         all sandboxes owned by user thies
attribute.sandbox_id/123     only sandbox ID 123
```

The service account's project or resource IAM roles decide what the sandbox can read or modify.

## Prerequisites

- Sandcastle must have OIDC enabled with `OIDC_PRIVATE_KEY_PEM`.
- `SANDCASTLE_HOST` must be the public HTTPS host that GCP can reach.
- These URLs must work from outside the Sandcastle host:
  - `https://SANDCASTLE_HOST/.well-known/openid-configuration`
  - `https://SANDCASTLE_HOST/oauth/jwks`
- The sandbox image must include `sandcastle-oidc` and `gcloud`.
- The GCP user running setup needs permission to enable APIs, create workload identity pools/providers, create service accounts, and edit IAM policy bindings.

## Default Setup

Use this for the common case: every sandbox owned by a Sandcastle user can use one default read-only service account for a GCP project.

### 1. Get GCP Project Data

```bash
export GCP_PROJECT="my-gcp-project"
gcloud config set project "$GCP_PROJECT"
gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)'
```

You need both:

```text
Project ID      my-gcp-project
Project number  123456789012
```

### 2. Create the Sandcastle GCP Config

In the web UI:

1. Open `Settings -> GCP`.
2. Add a config.
3. Fill:
   - `Name`: short Sandcastle name, for example `prod`
   - `Project ID`: GCP project ID
   - `Project number`: numeric GCP project number
   - `Pool ID`: usually `sandcastle`
   - `Provider ID`: usually `sandcastle`
   - `Location`: fixed to `global`
4. Save.

With the CLI:

```bash
sandcastle gcp config create prod \
  --project-id "$GCP_PROJECT" \
  --project-number "$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')" \
  --pool sandcastle \
  --provider sandcastle
```

### 3. Run the GCP Setup Commands

In `Settings -> GCP`, each saved config shows two copyable command blocks:

- `OIDC setup commands`
- `Default service account, roles, and impersonation`

Run both in a shell authenticated to the target GCP project.

With the CLI:

```bash
sandcastle gcp config setup prod
```

The generated setup does the following:

```bash
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project="$GCP_PROJECT"

gcloud iam workload-identity-pools create sandcastle \
  --project="$GCP_PROJECT" \
  --location=global \
  --display-name=Sandcastle

gcloud iam workload-identity-pools providers create-oidc sandcastle \
  --project="$GCP_PROJECT" \
  --location=global \
  --workload-identity-pool=sandcastle \
  --issuer-uri="https://SANDCASTLE_HOST" \
  --allowed-audiences="//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle" \
  --attribute-mapping="google.subject=assertion.sub,attribute.user=assertion.user,attribute.sandbox=assertion.sandbox,attribute.sandbox_id=string(assertion.sandbox_id)"

gcloud iam service-accounts create sandcastle-reader \
  --project="$GCP_PROJECT" \
  --display-name="Sandcastle read-only"

gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:sandcastle-reader@$GCP_PROJECT.iam.gserviceaccount.com" \
  --role=roles/viewer

gcloud iam service-accounts add-iam-policy-binding "sandcastle-reader@$GCP_PROJECT.iam.gserviceaccount.com" \
  --project="$GCP_PROJECT" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/attribute.user/SANDCASTLE_USER"
```

Sandcastle also grants these default read-only roles to `sandcastle-reader`:

```text
roles/viewer
roles/storage.objectViewer
roles/bigquery.dataViewer
roles/bigquery.jobUser
roles/logging.viewer
roles/monitoring.viewer
```

Each Sandcastle user has their own GCP config and their own generated `attribute.user/<username>` impersonation binding. To give another Sandcastle user access to the same project, create a config for that user or add the corresponding `attribute.user/<username>` binding on the service account.

### 4. Create a Sandbox with GCP Credentials

In the web UI:

1. Create or edit a stopped sandbox.
2. Enable `Configure GCP credentials`.
3. Select the GCP identity config.
4. Leave `Custom service account override` blank to use the default reader service account.
5. Keep `Principal scope` as `All my sandboxes` for the default low-friction path.

With the CLI:

```bash
sandcastle create devbox --gcp --gcp-config prod
```

or configure an existing stopped sandbox:

```bash
sandcastle gcp configure devbox --enable --config prod --scope user
```

When the sandbox starts, Sandcastle writes:

```text
/etc/sandcastle/gcp-credentials.json
/etc/sandcastle/oidc.env
/run/sandcastle/oidc-token
```

It also exports:

```text
GOOGLE_APPLICATION_CREDENTIALS=/etc/sandcastle/gcp-credentials.json
CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=/etc/sandcastle/gcp-credentials.json
GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1
CLOUDSDK_CORE_PROJECT=PROJECT_ID
GOOGLE_CLOUD_PROJECT=PROJECT_ID
```

### 5. Verify from Inside the Sandbox

Open a terminal in the sandbox and run:

```bash
gcloud config get-value project
gcloud projects describe "$GOOGLE_CLOUD_PROJECT" \
  --format="json(projectId,projectNumber,lifecycleState,name)"
```

Optional resource checks:

```bash
gcloud storage buckets list --project="$GOOGLE_CLOUD_PROJECT"
bq ls --project_id="$GOOGLE_CLOUD_PROJECT"
```

## Restricting Access to Specific Sandboxes

GCP IAM bindings are additive. If a service account already has an `attribute.user/thies` binding, adding `attribute.sandbox_id/123` does not restrict it to sandbox `123`; the user-level binding still allows all of that user's sandboxes.

For "only this and that sandbox can use this role", use a service account that does not have a user-level binding. You can use a custom service account for that restricted access path.

Example:

```bash
export GCP_PROJECT="my-gcp-project"
export PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
export RESTRICTED_SA="sandcastle-prod-reader@$GCP_PROJECT.iam.gserviceaccount.com"

gcloud iam service-accounts create sandcastle-prod-reader \
  --project="$GCP_PROJECT" \
  --display-name="Sandcastle prod read-only"

gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:$RESTRICTED_SA" \
  --role=roles/viewer
```

Create or configure the sandbox with a custom service account and sandbox scope:

```bash
sandcastle gcp configure prod-tool \
  --enable \
  --config prod \
  --service-account "$RESTRICTED_SA" \
  --scope sandbox
```

Find the sandbox principal in the sandbox detail page under `GCP Identity`, or print setup commands:

```bash
sandcastle gcp setup prod-tool
```

Grant only that sandbox access to the restricted service account:

```bash
gcloud iam service-accounts add-iam-policy-binding "$RESTRICTED_SA" \
  --project="$GCP_PROJECT" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/sandcastle/attribute.sandbox_id/SANDBOX_ID"
```

Repeat the binding for each sandbox ID that should be allowed.

## Service Account Permissions

Sandcastle separates impersonation from authorization:

- `roles/iam.workloadIdentityUser` on the service account controls which Sandcastle identities can impersonate the service account.
- Project or resource IAM roles on the service account control what the sandbox can do after impersonation.

For project-wide read-only access, the default `sandcastle-reader` roles are a reasonable baseline. For narrower access, grant roles directly on resources, for example a single bucket or dataset, and use a custom service account override on the sandbox.

## Troubleshooting

### `Permission 'iam.serviceAccounts.getAccessToken' denied`

This means GCP accepted the OIDC token but refused service account impersonation.

Check:

- The service account has `roles/iam.workloadIdentityUser`.
- The member is the exact Sandcastle principal shown in the UI.
- You used the project number, not the project ID, in the principal URI.
- The provider location is `global`.
- The IAM binding has had time to propagate.

For new IAM bindings, wait 30-60 seconds and retry. If `gcloud` cached the failed attempt inside a disposable sandbox, clear the sandbox cache:

```bash
rm -f /run/sandcastle/oidc/gcp-executable-cache.json
rm -rf ~/.config/gcloud
```

The cache clear is only for the sandbox user environment. It does not affect GCP IAM.

### `LOCATION_POLICY_VIOLATED` or `locations/local`

Use `global`. GCP Workload Identity Federation pools are global in Sandcastle's setup.

### Audience or issuer errors

The provider allowed audience must exactly match:

```text
//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID
```

The issuer URI must exactly match the Sandcastle host:

```text
https://SANDCASTLE_HOST
```

Check the public discovery endpoints:

```bash
curl -fsS https://SANDCASTLE_HOST/.well-known/openid-configuration
curl -fsS https://SANDCASTLE_HOST/oauth/jwks
```

### `gcloud auth login` prompt inside the sandbox

The sandbox is not seeing the injected credential config. Check:

```bash
env | grep -E 'GOOGLE|CLOUDSDK'
ls -l /etc/sandcastle/gcp-credentials.json /etc/sandcastle/oidc.env
```

`CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` and `GOOGLE_APPLICATION_CREDENTIALS` should both point to `/etc/sandcastle/gcp-credentials.json`.

### Project is unset

Check:

```bash
echo "$CLOUDSDK_CORE_PROJECT"
gcloud config get-value project
```

Both should resolve to the configured GCP project ID.

### The sandbox authenticates but cannot read a resource

The service account impersonation worked, but the service account lacks the needed resource role. Grant the role to the service account, not to the Sandcastle user.

## Useful Commands

Show the service account impersonation bindings:

```bash
gcloud iam service-accounts get-iam-policy "sandcastle-reader@$GCP_PROJECT.iam.gserviceaccount.com" \
  --project="$GCP_PROJECT"
```

Show the provider configuration:

```bash
gcloud iam workload-identity-pools providers describe sandcastle \
  --project="$GCP_PROJECT" \
  --location=global \
  --workload-identity-pool=sandcastle
```

Print Sandcastle setup commands:

```bash
sandcastle gcp config setup prod
sandcastle gcp setup devbox
```
