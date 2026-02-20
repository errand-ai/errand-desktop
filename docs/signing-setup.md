# Code Signing & Notarization Setup

This guide covers setting up Apple Developer ID code signing for ErrandDesktop distribution outside the Mac App Store.

## 1. Create a Developer ID Application Certificate

1. Sign in to [Apple Developer](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Profiles** → **Certificates**
3. Click **+** to create a new certificate
4. Select **Developer ID Application** (used for distributing outside the App Store)
5. Follow the prompts to upload a Certificate Signing Request (CSR):
   - Open **Keychain Access** → **Certificate Assistant** → **Request a Certificate From a Certificate Authority**
   - Enter your email, set **Request is: Saved to disk**, click **Continue**
   - Upload the generated `.certSigningRequest` file
6. Download the generated `.cer` file and double-click to install it in Keychain Access

## 2. Export as .p12

1. Open **Keychain Access**
2. In the **login** keychain under **My Certificates**, find **Developer ID Application: Your Name (TEAM_ID)**
3. Right-click → **Export**
4. Choose **Personal Information Exchange (.p12)** format
5. Set a strong password — you'll need this as `CERTIFICATE_PASSWORD`
6. Save the `.p12` file

## 3. Configure GitHub Actions Secrets

In your repository, go to **Settings** → **Secrets and variables** → **Actions** and add:

| Secret | Value |
|---|---|
| `CERTIFICATE_P12` | Base64-encoded `.p12` file (`base64 -i certificate.p12 \| pbcopy`) |
| `CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_ID` | Your Apple ID email (used for notarization) |
| `APPLE_PASSWORD` | App-specific password (generate at [appleid.apple.com](https://appleid.apple.com/account/manage) → **Sign-In and Security** → **App-Specific Passwords**) |
| `TEAM_ID` | Your 10-character Apple Developer Team ID (visible in the Developer portal under Membership) |

## 4. Entitlements

Create `ErrandDesktop.entitlements` in the project root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

The `com.apple.security.virtualization` entitlement is required for the Apple Containerization framework to create and manage lightweight Linux VMs.

### Additional Entitlements (if sandboxed)

If you enable App Sandbox in the future, you will also need:

- `com.apple.security.network.client` — for outgoing network connections
- `com.apple.security.network.server` — for the bridge API server
- `com.apple.security.files.user-selected.read-write` — for user-selected file access

Currently the app runs without App Sandbox to allow full Containerization framework access.
