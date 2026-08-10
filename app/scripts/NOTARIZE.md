# Notarizing PinWall (for sharing with others)

The DMG built by `scripts/package.sh` runs on **your** Mac, but on **anyone else's**
Mac macOS Gatekeeper will block it ("unidentified developer", and screensavers are
extra strict) until it's **notarized** by Apple.

Notarization needs a **paid Apple Developer Program** membership ($99/yr) and a
**"Developer ID Application"** certificate. You currently have only the free
"Apple Development" cert.

## One-time setup

1. **Enroll** in the Apple Developer Program: https://developer.apple.com/programs/
2. **Create a "Developer ID Application" certificate**
   - Xcode → Settings → Accounts → your Apple ID → Manage Certificates → **+** →
     *Developer ID Application*. (It installs into your login keychain.)
3. **Create an app-specific password** for notarization
   - https://account.apple.com → Sign-In & Security → App-Specific Passwords → generate one.
4. **Store notary credentials in the keychain** (you type the password, not Claude):
   ```bash
   xcrun notarytool store-credentials "PinWall" \
     --apple-id "singhadityasfs@gmail.com" \
     --team-id "GTWF62427T" \
     --password "<the app-specific password>"
   ```

## Every release

```bash
bash scripts/package.sh
```

With the Developer ID cert present, `package.sh` automatically:
- signs the app + screensaver with the Developer ID cert (hardened runtime + timestamp),
- builds `dist/PinWall.dmg`,
- submits it to Apple with `notarytool` and waits,
- staples the ticket so it opens cleanly offline.

The resulting `dist/PinWall.dmg` can be shared with anyone — they drag PinWall to
Applications, open it, connect their Pinterest, and click "Set up PinWall screensaver".

## Auto-update note
Uploading `PinWall.dmg` as a GitHub **Release** asset (tag like `v1.1.0`, and bump
`MARKETING_VERSION` in `project.yml`) is what the in-app updater checks against.
