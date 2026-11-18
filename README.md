# LocalLink 3.0 — hostless LAN chat starter

Flutter app for Android, iOS, Windows and macOS. Devices announce themselves with UDP multicast and exchange messages using direct TCP sockets. No central chat host, cloud service, account, or internet is used. Message history is stored as JSON Lines in each device's app-support directory.

## Important scope and limitations

- This is a runnable **starter/prototype**, not a security-audited production messenger.
- Discovery and chat require all devices to be on the same reachable IPv4 LAN.
- Router/AP client isolation, guest Wi-Fi isolation, VLANs, firewall rules, or multicast filtering can prevent discovery or messaging. Check Airtel Xstream router settings for AP/client isolation and keep devices on the same main SSID/subnet.
- iOS requires Apple's `com.apple.developer.networking.multicast` entitlement to send/receive arbitrary multicast. Apple approval/signing is required; without it, iOS multicast discovery will not work. The iOS entitlement and local-network privacy snippet are supplied as starting points.
- Windows Defender Firewall may ask to allow LocalLink on Private networks. Allow it only on trusted home/private Wi-Fi.
- This prototype has no encryption/authentication. Anyone on the same LAN who knows the protocol/ports could potentially inject messages. Do not use on public/shared Wi-Fi or send sensitive information.
- Messages are stored separately on each device. A device that was offline does not receive messages sent while it was away. There is no central sync or guaranteed delivery.
- The current version sends each message directly to currently discovered peers; it does not implement end-to-end encryption, delivery receipts, file transfer, or robust peer reconnection.

## Build

### Download an Android APK from GitHub Actions

After pushing to GitHub, open the repository's **Actions** tab, select **Build Android APK**, and wait for the run to finish. Download `locallink-release-apk` from the run's **Artifacts** section and extract `app-release.apk`.

### Build locally

Install the Flutter SDK and platform toolchains, then generate the Android project scaffolding and run:

```bash
flutter create --platforms=android --org com.example --project-name locallink build/locallink
cp pubspec.yaml build/locallink/pubspec.yaml
cp -R lib/. build/locallink/lib/
cp android/app/src/main/AndroidManifest.xml build/locallink/android/app/src/main/AndroidManifest.xml
mkdir -p build/locallink/android/app/src/main/kotlin/com/example/locallink
cp android/app/src/main/kotlin/com/example/locallink/MainActivity.kt build/locallink/android/app/src/main/kotlin/com/example/locallink/MainActivity.kt
cd build/locallink
flutter pub get
flutter build apk --release
```

The APK is written to `build/locallink/build/app/outputs/flutter-apk/app-release.apk`.

For iOS:
1. Merge `Info.plist.local-network-snippet` into `ios/Runner/Info.plist`.
2. Add `LocalLink.entitlements` to the Runner target's Code Signing Entitlements setting.
3. Obtain Apple's multicast networking entitlement for the App ID and provisioning profile. A local-network permission prompt alone does not grant multicast entitlement.
4. Build/sign on macOS with Xcode.

For macOS, merge `macos/Runner/LocalLink.entitlements` into the app's entitlements and ensure the target uses that file.

For Windows, allow inbound TCP 45455 and UDP multicast 45454 on Private networks when Windows Firewall prompts. Do not open these ports to Public networks.

## Network protocol

- Discovery: IPv4 multicast `239.255.42.99:45454`, JSON heartbeat every 3 seconds.
- Messaging: TCP port `45455`, one JSON message per connection.
- Each app is both a listener and a client. There is no designated host.
- History: `messages.jsonl` in the platform application-support directory.

## Router checklist

- Connect devices to the same main Wi-Fi network (not guest Wi-Fi).
- Disable AP/client isolation if enabled.
- Avoid VPNs while testing.
- Permit LocalLink on the private/home network firewall.
- Some ISP router firmware filters multicast; if discovery fails, the router may not support this approach without configuration or a different discovery method.
