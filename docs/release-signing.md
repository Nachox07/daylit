# Signing the macOS release

macOS ties its privacy permissions (Local Network, Accessibility, Automation) to the app's code
signature. The release is signed ad-hoc by default, and an ad-hoc signature is different for every
build. So after an update macOS can treat Daylit as a new app and the permissions are gone: Home
Assistant requests fail until the user turns Daylit off and on again in System Settings → Privacy &
Security → Local Network.

Signing every release with the same certificate should fix that. The release workflow does it when
two repository secrets exist, and keeps the ad-hoc signature when they do not.

**What is and is not known.** A stable certificate keeps the Accessibility and Automation grants
across updates. For Local Network it is *expected* to help, but this is not verified for a
self-signed certificate: Apple's TN3179 says Local Network privacy tracks an app by its code
signature **and** the main executable's UUID (which changes with every build), and Apple recommends
a persistent Apple-issued identity. The more reliable option is an **Apple Development** identity
(or Developer ID) instead of a self-signed one; `mac/build.sh` and the workflow accept any identity
in the `.p12`. Run the test below before telling users the problem is solved.

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

## Test it once (manual)

1. Build two versions signed with the certificate:
   `DAYLIT_SIGN_IDENTITY=<hash or name> DAYLIT_VERSION=9.9.1 mac/build.sh /tmp/a` and the same with
   `9.9.2` into `/tmp/b`, changing a line of code in between so the executable differs.
2. Install the first as `~/Applications/Daylit.app`, open it with a local Home Assistant URL
   configured, and allow Local Network when macOS asks. Check the panel shows Home Assistant data.
3. Quit it, replace the app with the second build, open it.
4. If Home Assistant still answers and the panel shows no "blocking" line, the certificate keeps the
   permission. If not, use an Apple Development or Developer ID identity and repeat.

## What changes for users

- The first signed release costs each user **one more permission prompt** (Local Network, and
  Accessibility or Automation if they were granted): the signature differs from the ad-hoc one.
- From then on every update keeps the permissions.
- A self-signed certificate does not remove the "Open Anyway" step on first open. Only an Apple
  Developer ID with notarization does.

## Local builds

`mac/build.sh` signs with `DAYLIT_SIGN_IDENTITY` (a certificate hash or name) if set, else with an
Apple Development identity if the keychain has one, else ad-hoc.
