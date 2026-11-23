# Privacy manifest and App Store privacy labels

Two Apple declarations say what data QBank handles. They must agree with each other and with [privacy-policy.md](privacy-policy.md):

- the **privacy manifest**, `PrivacyInfo.xcprivacy`, a file inside the app target that ships in every build;
- the **App Privacy answers** (the "nutrition labels") the owner fills in once in App Store Connect, under the app's App Privacy page.

This file is the source for both. It describes the app at TestFlight parity (phases 1a to 1e of the plan), with the Face ID lock and Import (phase 3) and Make questions (phase Q). Any change that sends a new kind of data to the server, adds a third-party SDK, or uses a new required-reason API updates this file, the manifest, and the policy in the same pull request.

## Why these answers

Apple counts data as **collected** when it leaves the device and is kept longer than it takes to answer the request. QBank's server keeps your account, sessions, answers, and progress, so those are collected. Data that stays on the phone (the offline copy, the look setting) is not collected.

Everything collected is **linked** to you, because it is stored under your account. Nothing is used for **tracking**: no ads, no data brokers, no joining with other companies' data. The only purpose is **App Functionality**: signing in and keeping your progress.

## Collected data types

| App Store Connect category | Data type | Manifest key | What it is in QBank | Linked | Tracking | Purpose |
|---|---|---|---|---|---|---|
| Contact Info | Email Address | `NSPrivacyCollectedDataTypeEmailAddress` | the account's sign-in email | yes | no | App Functionality |
| Identifiers | User ID | `NSPrivacyCollectedDataTypeUserID` | the server's account id that every answer is stored under | yes | no | App Functionality |
| User Content | Photos or Videos | `NSPrivacyCollectedDataTypePhotosorVideos` | Make questions: the photos she takes or picks of her notes, slides, or practice questions, sent on to Anthropic's Claude API to read them and deleted from the server once read; the text read from them stays in the set's record | yes | no | App Functionality |
| User Content | Other User Content | `NSPrivacyCollectedDataTypeOtherUserContent` | answers, guesses, per-question progress, the Review list, exam picks and scores; an imported question file, which becomes that account's own study content, private to the account, not shared course content, and is kept with the account; for Make questions, the notes she pastes and the file she picks, sent on like the photos; their text stays in the set's record | yes | no | App Functionality |
| Usage Data | Product Interaction | `NSPrivacyCollectedDataTypeProductInteraction` | study-session start and end times and the last-opened course (Apple lists "saved place" under this type) | yes | no | App Functionality |

Answer these in App Store Connect exactly this way: "Yes, we collect data from this app", then the five types above, each "linked to the user", "not used for tracking", purpose "App Functionality" only.

### Considered and not declared

| Data | Why not declared |
|---|---|
| Password | Apple's list of data types has no password type. The app sends it only to sign in, and the server keeps a one-way hash. |
| Agent key | Apple's list has no credential type. Connect an agent sends the server only the short code her own agent shows her and her answer; the agent picks its key up from the server itself, so no key reaches the app. The server keeps each key's name, what it may do, and when it was made, last used and revoked, only to let her agent in and to list her keys. |
| Name | The account name is set by the owner on the server, not collected by the app. Declare **Name** if a later version lets you type or change it in the app. |
| IP address and user agent of a session | The server's sign-in library records them with each session; QBank reads them for nothing. Apple says to declare an IP address by how it is used (location, device ID, diagnostics), and QBank uses it for none of these. Cleaner still: a server task turns that recording off (see [release.md](release.md)), and this row then goes away. |
| Crash data, performance data, other diagnostics | The app has no crash or analytics SDK and sends no diagnostics. TestFlight crash reports and feedback are collected by Apple, and Apple says developers are not responsible for disclosing data Apple collects. |
| Audio | Not read. |
| Export file | It goes where you send it; QBank never receives it. |
| Purchases, financial info, health, location, contacts, browsing, search history, sensitive info | Not handled. |

### When later phases change the answers

| Phase | Change |
|---|---|
| 3 Face ID lock | shipped: nothing is collected. iOS checks Face ID, Touch ID or the passcode and tells the app only whether it matched; the on-off setting stays on the device. |
| 3 Passkeys | removed on 2026-10-29: the app no longer saves passkeys or signs in with them, so it sends no passkey data. Nothing Apple's labels count changes. |
| 3 Import | shipped: an imported question file becomes that account's own study content, private to the account, not shared course content. It is Other User Content, already declared above. No new data type. |
| Q Make questions (the accounts the server allows) | shipped: **Photos or Videos** and **Other User Content** (notes, files) declared above; the policy names Anthropic. The app asks once per device before first use, with Allow and Not now, and sends nothing before Allow; the choice stays on the device and Settings changes it. |
| Q Exam twins (the same accounts) | shipped: nothing new is collected. The app sends the course, the ticked folders and the pool, the exam picks under Other User Content; the server sends those practice questions, the account's own study content, to Anthropic, which the policy says. The same one-time permission comes first. |
| Connect an agent | shipped: nothing new is collected that Apple's labels count (see Agent key above). The sets an agent imports with its key are Other User Content, already declared. |
| Q Delete and Undo | shipped: nothing new is collected. Deleting a course or study topic, a page, a set, a folder or a past exam hides it on the server, where it stays with her answers until the account is deleted, which the policy says. |
| 4 Free on this phone | data in on-phone mode is never sent anywhere and is not collected; the signed-in mode keeps the answers above. |

## `PrivacyInfo.xcprivacy`

The app target carries this file at `QBank/PrivacyInfo.xcprivacy`. The project's folder-synchronized `QBank` group copies it into the app bundle; the test targets and the packages do not. Kun's Eddie's Wallet ships the same shape at `EddysWallet/PrivacyInfo.xcprivacy`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeEmailAddress</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeUserID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePhotosorVideos</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeOtherUserContent</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeProductInteraction</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

## Required-reason APIs

Apple rejects an upload that calls one of these API groups without a declared reason. Declare only what the code really calls; check with a search of the app's sources before each release.

| API group | Expected in QBank | Reason code | Why |
|---|---|---|---|
| User defaults (`UserDefaults`, `@AppStorage`) | yes: the look setting, the Face ID lock | `CA92.1` | read and written only by the app itself |
| File timestamp (`creationDate`, `modificationDate`, `stat`) | only if the offline store reads file dates | `C617.1` | files inside the app's own container |
| System boot time (`systemUptime`, `mach_absolute_time`) | only if a timer measures elapsed time this way | `35F9.1` | time between events inside the app; never sent off the phone |
| Disk space (`volumeAvailableCapacity...`) | only if the offline store checks free space before saving | `E174.1` | to avoid writing when the phone is full |
| Active keyboards | no | | |

The exam timer is ruled by the server's clock (`serverNow`), so it should not need the boot-time group.

A search of the app and of `Packages/QBankKit` and `Packages/QBankDesign` finds `UserDefaults` only, in the look setting and the Face ID lock. The manifest declares that group with `CA92.1` and no other required-reason group.

## Related build settings

- **Export compliance:** the app uses only Apple's HTTPS, which is exempt. Set `ITSAppUsesNonExemptEncryption` to `NO` in the app's Info.plist so App Store Connect stops asking on every build.
- **No tracking prompt:** the app never shows the App Tracking Transparency prompt and has no `NSUserTrackingUsageDescription`.
- **Usage descriptions** (`NS...UsageDescription`) are added only with the feature that needs them. Make questions' Take photo uses the camera, so the app carries `NSCameraUsageDescription`. Its photo picker (`PhotosPicker`) runs outside the app and hands over only the photos she picks, so there is no photo library usage description.
