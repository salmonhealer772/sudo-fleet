# sudo-gws OAuth click-path (operator)

This is the one thing no agent can do for you: create the GCP OAuth client.
Do these steps once, in order, then hand the two values back through the
secrets store (`GWS_CLIENT_ID` and `GWS_CLIENT_SECRET`) — do NOT paste them in
chat and do NOT commit them to git.

## The two values you must register

- **Application type (client type):** `Desktop app` (a.k.a. installed app).
  This is the type Google intends for the "user consents in their own browser
  via a loopback redirect" pattern. No public HTTPS URL is needed.
- **Redirect URI (copy this exactly):**
  `http://127.0.0.1:8747/oauth2callback`
  This is a LOOPBACK URI — it lands on YOUR Mac (the consent browser), not on
  the pod. Google allows plain `http://` for loopback hosts (127.0.0.1 /
  localhost) and rejects `http://` for anything else.
- **Scopes requested** (the server requests exactly these for Drive+Docs+Sheets;
  they are derived automatically from `--tools drive docs sheets`):
  - `openid`
  - `https://www.googleapis.com/auth/userinfo.email`
  - `https://www.googleapis.com/auth/userinfo.profile`
  - `https://www.googleapis.com/auth/drive`
  - `https://www.googleapis.com/auth/drive.readonly`
  - `https://www.googleapis.com/auth/drive.file`
  - `https://www.googleapis.com/auth/documents`
  - `https://www.googleapis.com/auth/documents.readonly`
  - `https://www.googleapis.com/auth/spreadsheets`
  - `https://www.googleapis.com/auth/spreadsheets.readonly`

## Steps

1. **Create a project**
   Go to https://console.cloud.google.com/projectcreate — name it anything
   (e.g. `sudo-fleet-gws`). Note the project.

2. **Enable the three APIs** (one each; the search box is the fast path):
   - Drive API — https://console.cloud.google.com/apis/library/drive.googleapis.com
   - Docs API — https://console.cloud.google.com/apis/library/docs.googleapis.com
   - Sheets API — https://console.cloud.google.com/apis/library/sheets.googleapis.com
   Click **Enable** on each.

3. **Configure the OAuth consent screen**
   https://console.cloud.google.com/apis/credentials/consent
   - User type: **External** (a personal @gmail.com cannot use Internal).
   - App name: anything (e.g. `sudo-fleet-gws`).
   - User support email: `operator@example.com`.
   - Scopes: add the ten scopes listed above (or leave "add scopes" minimal —
     the exact set is requested at runtime; Google shows them at consent).
   - Test users: click **Add users** and add `operator@example.com`, then
     Save. (In "Testing" publishing status, ONLY listed test users can consent.)

4. **Create the OAuth client**
   https://console.cloud.google.com/apis/credentials
   - **+ Create credentials → OAuth client ID**.
   - Application type: **Desktop app**.
   - Name: `sudo-gws`.
   - Under **Authorized redirect URIs → Add URI**, paste:
     `http://127.0.0.1:8747/oauth2callback`
   - Click **Create**.

5. **Copy the two values** from the dialog (or reopen the client and re-copy):
   - **Client ID** → `GWS_CLIENT_ID`
   - **Client secret** → `GWS_CLIENT_SECRET`

6. Hand them back through the secrets store, then re-run
   `bash factories/sudo-gws/kube-scripts/up.sh` (with those two env vars set)
   so the secret is created with real values.

## The consent click-path (what happens after the client exists)

On your Mac, run ONE command:

```sh
python3 oauth-consent.py
```

It will: ask the pod to start the flow, open the authorization link in Brave,
wait for Google to bounce back to `http://127.0.0.1:8747/oauth2callback` on
your Mac, and forward the code to the pod — which exchanges it and stores the
refresh token on its PVC. You click **Allow** once and you are done.

If the script is not already on your Mac, fetch it first (same one-liner):

```sh
curl -fsSL -o oauth-consent.py \
  https://raw.githubusercontent.com/salmonhealer772/sudo-fleet/main/factories/sudo-gws/kube-scripts/oauth-consent.py \
  && python3 oauth-consent.py
```

## Why the redirect URI is a loopback on YOUR Mac

Google only accepts `http://` redirect URIs for loopback hosts. The consent
browser runs on your Mac, so the redirect URI is a loopback address ON THE MAC
(`127.0.0.1:8747`). The helper script catches that redirect locally and hands
the one-time code to the pod over the LAN (`192.168.5.15:27462`). There is no
reverse tunnel and no log scraping — the pod does the token exchange itself
because it already holds the client secret and the PKCE verifier.
