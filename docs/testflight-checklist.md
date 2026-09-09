# Ripple Garden: TestFlight and App Store checklist

Audited 2026-09-09 against branch `garden`. Everything marked DONE is already in the
repo. Everything marked OWNER needs a human in Xcode, App Store Connect or a browser.

Bundle id `com.radicraft.ripple`, team `VQQCV6BB8R`, version 1.0 (1), iOS 17.0,
iPhone only.

---

## 1. Xcode, before the archive

- [ ] **OWNER: add the iCloud capability.** Target Ripple, Signing & Capabilities,
  the **Release** configuration. Add **iCloud**, tick **CloudKit**, and select the
  container `iCloud.com.radicraft.ripple`. If the container is not in the list, press
  the `+` under Containers and type it exactly. This has to be done once in Xcode so
  the App ID on the developer portal gains the capability; the entitlements file in
  the repo already names the container, but the App ID is what the profile is built
  from, and only Xcode (or the portal) can change that.
- [ ] **OWNER: add the Push Notifications capability** on the same screen. SwiftData's
  CloudKit mirroring learns about writes from other devices through a silent push.
  `Info.plist` declares the `remote-notification` background mode for that; without
  the push capability the app cannot register, so the mode does nothing and progress
  only syncs when the app is launched or foregrounded. Adding it writes
  `aps-environment` into the entitlements at build time.
  If you would rather not ship push at all, delete the `UIBackgroundModes` block from
  `Info.plist` instead and accept launch-time-only sync. Do not leave the background
  mode without the capability.
- [ ] **OWNER: confirm CloudKit schema.** Open the CloudKit console for
  `iCloud.com.radicraft.ripple`. Run the app once on a real device from a Release
  build so SwiftData creates `CD_LevelRecord` and `CD_GardenRecord` in the
  **Development** environment, then press **Deploy Schema to Production**. A build
  that reaches TestFlight talks to the Production environment, and an undeployed
  schema means silent sync failure, not a crash.
- [ ] **OWNER: Product > Archive** with the Release configuration, then Distribute App,
  App Store Connect, Upload. Xcode will manage signing automatically.
- [ ] DONE: Release configuration references `Ripple/Ripple.entitlements`
  (`CODE_SIGN_ENTITLEMENTS`). Debug deliberately does not, so a Debug device build
  signs without iCloud and `ProgressStore` falls back to a local store.

## 2. App Store Connect: the app record

- [ ] **OWNER: sign the Paid Applications agreement.** Business > Agreements. Until it
  is active with valid bank and tax details, `Product.products(for:)` returns nothing
  and the Seasons pass menu shows "Coming soon", including for the reviewer.
- [ ] **OWNER: create the app record** with bundle id `com.radicraft.ripple`, name
  "Ripple Garden", primary language, primary category Games, subcategory Puzzle plus
  a second (Casual or Family) if wanted.
- [ ] **OWNER: privacy policy URL.** Required for every app. Must be a live page
  before submission.
- [ ] **OWNER: support URL.** Also required.
- [ ] **OWNER: screenshots.** 6.9 inch is the only required iPhone set now. There is no
  iPad set to supply because the app is iPhone only.

## 3. The two subscriptions

Both product ids are hard-coded in `Ripple/Store.swift` and must match exactly.

- [ ] **OWNER: create one subscription group**, for example "Seasons". Both products
  live in the same group so a player can move between them and so only one can be
  active at a time.
- [ ] **OWNER: create `com.radicraft.ripple.seasons.monthly`**, auto-renewable, 1 month.
- [ ] **OWNER: create `com.radicraft.ripple.seasons.annual`**, auto-renewable, 1 year.
- [ ] **OWNER: for each**, set a localised display name and description, a price for
  every storefront, and a review screenshot of the Seasons pass menu.
- [ ] **OWNER: the group needs a localised group display name** as well as the two
  product names. Apple rejects groups without one.
- [ ] **OWNER: submit both subscriptions attached to the 1.0 build.** For a first
  release, in-app purchases that are not attached to the version go unreviewed and the
  app ships with a dead store.

### Blocking code gap for the subscriptions

The paywall in `Ripple/Game/WaterMenu.swift` (`WaterMenus.storeRows`) currently shows
the title, a sentence of prose, and two buttons reading "Month <price>" and
"Year <price>". Guideline 3.1.2 wants all of the following visible in the app, on the
page where the purchase happens:

1. the subscription name,
2. the length of one period,
3. the price, and the price per period if the offer is a bundle,
4. a functional link to the Terms of Use (EULA), and
5. a functional link to the Privacy Policy.

Items 4 and 5 are missing, and this is the single most common rejection for a first
subscription app. Two lines in the water menu carrying the two links, or a plain
"Terms" and "Privacy" pair of stones next to "Done", would close it.

The copy also needs a look. "The first year is yours to keep." reads like a one-off
purchase sitting under an auto-renewing subscription, which is exactly the ambiguity
3.1.2 exists to stop. Say plainly that it renews until cancelled.

Apple's standard EULA can be linked at
`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` if no custom one
is written.

## 4. App Privacy answers

- [ ] **OWNER: "Do you or your third-party partners collect data from this app?" No.**
  This is true and the code backs it. There is no analytics SDK, no network client, no
  crash reporter. Progress goes to the player's own private CloudKit database, which
  Apple does not count as collection by you, and purchases are handled by the App
  Store. `Ripple/PrivacyInfo.xcprivacy` declares the same thing and is in the bundle.
- [ ] DONE: privacy manifest created at `Ripple/PrivacyInfo.xcprivacy`. It declares no
  tracking, no tracking domains, no collected data types, and one required-reason API:
  `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (the app reading and
  writing its own defaults). Verified present in both the Debug and Release simulator
  bundles.
- [ ] DONE: no other required-reason API is used. A grep found no file timestamp reads,
  no `systemUptime` or `mach_absolute_time`, no free-disk-space queries and no keychain
  use, so no further reason codes are owed.

## 5. Age rating

- [ ] **OWNER: answer the questionnaire for a 4+ rating.** No violence, no profanity,
  no gambling, no simulated gambling, no horror, no unrestricted web access, no user
  generated content, no messaging between players. Do declare that the app offers
  in-app purchases (the questionnaire and the store listing both ask).

## 6. Credits and licences

- [ ] DONE, nothing owed: the sounds. `Ripple/Audio/Sounds/LICENSES.md` records that
  every file comes from Pixabay under the Pixabay Content License, which requires no
  attribution and permits commercial use. Nothing is CC-BY-NC or personal-use-only.
  A credits line is written at the bottom of that file if a credits screen is ever
  wanted, but it is optional.
- [ ] DONE, obligation met: the fonts. Shippori Mincho is under the SIL Open Font
  License 1.1, which requires the licence text to travel with the font. `OFL.txt`
  ships in the app bundle (verified in the built `.app`). The OFL also forbids selling
  the fonts on their own, which is not what is happening, and forbids using the
  reserved font name on a modified version, which is also not happening.
- [ ] OWNER, optional: nothing requires a visible credits screen. If one is added, the
  line at the end of `Ripple/Audio/Sounds/LICENSES.md` plus "Shippori Mincho, copyright 2021 The Shippori Mincho Project Authors
  SIL Open Font License 1.1" covers everything.

## 7. Export compliance

- [ ] DONE: `ITSAppUsesNonExemptEncryption` is `false` in `Info.plist`, so App Store
  Connect will stop asking on every upload. This is correct: the app uses no
  encryption of its own, and HTTPS through Apple's own frameworks is exempt.

## 8. What was already right

Deployment target 17.0, `TARGETED_DEVICE_FAMILY = 1` (iPhone only, so iPad is not a
supported device and no iPad screenshots or layout are owed), `DEVELOPMENT_TEAM` set,
Release `SWIFT_OPTIMIZATION_LEVEL = -O` with whole-module compilation, a single
1024x1024 app icon with no alpha channel (which is all modern Xcode needs, and alpha
in an icon is an automatic rejection), portrait-only orientation, status bar hidden,
indirect input events supported, and the three bundled fonts listed in `UIAppFonts`
exactly matching the three files in `Ripple/Fonts`.
