# Signing the macOS release

macOS ties its privacy permissions (Local Network, Accessibility, Automation) to the app's code
signature. The release is signed ad-hoc by default, and an ad-hoc signature is different for every
build. So after an update macOS treats Daylit as a new app and the permissions are gone: Home
Assistant requests fail until the user turns Daylit off and on again in System Settings → Privacy &
Security → Local Network.

Signing every release with the same certificate fixes that. The release workflow does it when two
repository secrets exist, and keeps the ad-hoc signature when they do not.

## One-time setup (the owner does this, not an agent)

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
   - Name: `Daylit Code Signing`
   - Identity Type: **Self Signed Root**
   - Certificate Type: **Code Signing**
   - Tick **Let me override defaults** and set a validity of 3650 days (the default 365 would need a
     new certificate, and a new permission prompt for everyone, every year).
2. Find the certificate under **My Certificates**, right-click → **Export…** → format
   **Personal Information Exchange (.p12)**, with a password you choose.
3. Store both as repository secrets (the file never leaves your machine unencoded):

   ```sh
   base64 -i DaylitCodeSigning.p12 | gh secret set MAC_CERT_P12 -R Nachox07/daylit
   gh secret set MAC_CERT_PASSWORD -R Nachox07/daylit      # paste the password when asked
   ```

4. Keep the `.p12` and its password somewhere safe (a password manager). Losing them means a new
   certificate, which costs users another permission prompt.
5. Delete the exported `.p12` from disk once it is stored.

The next `v*` tag builds a signed `Daylit.app`. The job log shows the signing certificate; the secrets
themselves are never printed.

## What changes for users

- The first signed release costs each user **one more permission prompt** (Local Network, and
  Accessibility or Automation if they were granted): the signature differs from the ad-hoc one.
- From then on every update keeps the permissions.
- A self-signed certificate does not remove the "Open Anyway" step on first open. Only an Apple
  Developer ID with notarization does.

## Local builds

`mac/build.sh` signs with `DAYLIT_SIGN_IDENTITY` (a certificate hash or name) if set, else with an
Apple Development identity if the keychain has one, else ad-hoc.
