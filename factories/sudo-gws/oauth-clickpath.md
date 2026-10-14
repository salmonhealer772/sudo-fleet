# sudo-gws OAuth click-path (operator)

This is the one thing no agent can do for you: create the GCP OAuth client.
Do these steps once, in order, then hand the two values back through the
secrets store (`GWS_CLIENT_ID` and `GWS_CLIENT_SECRET`) — do NOT paste them in
chat and do NOT commit them to git.

## The two values you must register

- **Redirect URI (copy this exactly):**
  `http://localhost:8000/oauth2callback`
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
   - Application type: **Web application**.
   - Name: `sudo-gws`.
   - **Authorized redirect URIs → Add URI:**
     `http://localhost:8000/oauth2callback`
   - Click **Create**.

5. **Copy the two values** from the dialog (or reopen the client and re-copy):
   - **Client ID** → `GWS_CLIENT_ID`
   - **Client secret** → `GWS_CLIENT_SECRET`

6. Hand them back through the secrets store. Then run
   `bash factories/sudo-gws/kube-scripts/up.sh` again (with those two env vars
   set) so the secret is created with real values, and start the consent tunnel:
   `bash factories/sudo-gws/kube-scripts/oauth-tunnel.sh`.

## Why the redirect URI is `localhost`, not the node IP

Google rejects a non-loopback `http://` redirect URI (it must be `https://` for
anything but `localhost`/`127.0.0.1`). The consent browser runs on your Mac, so
we make the server's callback reachable at the Mac's loopback: a reverse SSH
tunnel maps `Mac:8000 -> pod:27462`. Register `http://localhost:8000/oauth2callback`
and run `oauth-tunnel.sh` before you click the authorization URL.
