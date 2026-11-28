# Privacy manifest and App Store privacy labels

Two Apple declarations say what data QBank handles. They must agree with each other and with [privacy-policy.md](privacy-policy.md):

- the **privacy manifest**, `PrivacyInfo.xcprivacy`, a file inside the app target that ships in every build;
- the **App Privacy answers** (the "nutrition labels") the owner fills in once in App Store Connect, under the app's App Privacy page.

This file is the source for both. It describes the App Store build: Sign in with Apple, the bank on the phone, QBank Cloud with its purchase, move, combine and hand-back, and the invited accounts' email and password, Make questions and agent keys. Any change that sends a new kind of data to the server, adds a third-party SDK, or uses a new required-reason API updates this file, the manifest, and the policy in the same pull request.

## Why these answers

Apple counts data as **collected** when it leaves the device and is kept longer than it takes to answer the request. QBank's server keeps the account and its sessions in every mode, and the bank (answers, progress, and the rest) of a Cloud or invited account, so those are collected. Data that stays on the phone is not collected: a free account's whole bank (no request about it leaves the phone, `BankRoutedTransport`), the offline copy, the safety copies, the drafts, and the look setting.

Everything collected is **linked** to you, because it is stored under your account. Nothing is used for **tracking**: no ads, no data brokers, no joining with other companies' data. The only purpose is **App Functionality**: signing in, keeping your bank and progress, and deciding who has Cloud.

## Collected data types

| App Store Connect category | Data type | Manifest key | What it is in QBank | Linked | Tracking | Purpose |
|---|---|---|---|---|---|---|
| Contact Info | Email Address | `NSPrivacyCollectedDataTypeEmailAddress` | the account's email: the address Apple shares at Sign in with Apple (the person's own or a private relay address), or an invited account's sign-in email | yes | no | App Functionality |
| Identifiers | User ID | `NSPrivacyCollectedDataTypeUserID` | the server's account id that every answer is stored under, and Apple's id of the person for an account made with Sign in with Apple | yes | no | App Functionality |
| User Content | Photos or Videos | `NSPrivacyCollectedDataTypePhotosorVideos` | Make questions, offered to invited accounts only: the photos the person takes or picks of their notes, slides, or practice questions, sent on to Anthropic's Claude API to read them and deleted from the server once read; the text read from them stays in the set's record | yes | no | App Functionality |
| User Content | Other User Content | `NSPrivacyCollectedDataTypeOtherUserContent` | for a Cloud or invited account: the whole bank (semesters, courses, topics, pages, folders, sets, questions, terms), answers, guesses, per-question progress, the Review list, exam picks and scores, each row's time of last change; an imported or hand-written set, which becomes that account's own study content, private to the account, not shared course content, and is kept with the account; the bank a phone uploads when Cloud turns on, or combines with the one the server holds; for Make questions, the notes the person pastes and the file they pick, sent on like the photos; their text stays in the set's record | yes | no | App Functionality |
| Usage Data | Product Interaction | `NSPrivacyCollectedDataTypeProductInteraction` | for a Cloud or invited account: study-session start and end times and the last-opened course (Apple lists "saved place" under this type) | yes | no | App Functionality |
| Purchases | Purchase History | `NSPrivacyCollectedDataTypePurchaseHistory` | a QBank Cloud subscription bought in the app: the transaction the App Store signed goes to the server, which keeps the plan, the App Store's ids of the subscription and its latest transaction, when the period it pays for began and ends, whether Apple refunded or revoked it, and the App Store environment, under the account, with the account's purchase token (the appAccountToken), to decide whether it has Cloud. No price, currency or storefront is kept | yes | no | App Functionality |

Answer these in App Store Connect exactly this way: "Yes, we collect data from this app", then the six types above, each "linked to the user", "not used for tracking", purpose "App Functionality" only.

### Considered and not declared

| Data | Why not declared |
|---|---|
| Password | Invited accounts only. Apple's list of data types has no password type. The app sends it only to sign in, to link Apple and to delete the account, and the server keeps a one-way hash. |
| Apple's identity token and authorization code | Used once, at sign-in, linking or Delete account, and never kept: the server keeps only a mark that the nonce was used, until the token expires. The person's Apple id is declared above as User ID. |
| Name | Sign in with Apple asks for the email only, never the name. A store account's name is the part of its email before the @; an invited account's is set by the owner on the server. Declare **Name** if a later version lets you type or change it in the app. |
| Agent key | Invited accounts only. Apple's list has no credential type. Connect an agent sends the server only the short code the person's own agent shows them and their answer; the agent picks its key up from the server itself, so no key reaches the app. The server keeps each key's name, what it may do, and when it was made, last used and revoked, only to let the agent in and to list the keys. |
| IP address | The server no longer records it, or the user agent, on a new session (since 2026-11-23); sessions made before then keep what was recorded until they are removed. It is kept only to limit tries: with a refused Sign in with Apple, a wrong password or a refused sign-up, for 15 minutes of lock, and while an agent pairing waits. Apple says to declare an IP address by how it is used (location, device ID, diagnostics), and QBank uses it for none of these. |
| Crash data, performance data, other diagnostics | The app has no crash or analytics SDK and sends no diagnostics. TestFlight crash reports and feedback are collected by Apple, and Apple says developers are not responsible for disclosing data Apple collects. |
| Audio | Not read. |
| Export file | Export my bank goes where the person sends it; QBank never receives it. |
| Device backup | A free account's bank is in the device's own backup, which is Apple's service or the person's computer, not QBank's. |
| Payment details and other financial info, health, location, contacts, browsing, search history, sensitive info | Not handled. Apple takes the payment for QBank Cloud; the app and the server never see a card or a bank account. |

### When later phases change the answers

| Phase | Change |
|---|---|
| 3 Face ID lock | shipped: nothing is collected. iOS checks Face ID, Touch ID or the passcode and tells the app only whether it matched; the on-off setting stays on the device. |
| 3 Passkeys | removed on 2026-10-29: the app no longer saves passkeys or signs in with them, so it sends no passkey data. Nothing Apple's labels count changes. |
| 3 Import | shipped: an imported question file becomes that account's own study content, private to the account, not shared course content. It is Other User Content, already declared above. No new data type. |
| Q Make questions (the accounts the server allows) | shipped: **Photos or Videos** and **Other User Content** (notes, files) declared above; the policy names Anthropic. The app asks once per device before first use, with Allow and Not now, and sends nothing before Allow; the choice stays on the device and Settings changes it. |
| Q Exam twins (the same accounts) | shipped: nothing new is collected. The app sends the course, the ticked folders and the pool, the exam picks under Other User Content; the server sends those practice questions, the account's own study content, to Anthropic, which the policy says. The same one-time permission comes first. |
| Connect an agent | shipped: nothing new is collected that Apple's labels count (see Agent key above). The sets an agent imports with its key are Other User Content, already declared. |
| Q Delete and Undo | shipped: nothing new is collected. Deleting a course or study topic, a page, a set, a folder or a past exam hides it on the server, where it stays with its answers until the account is deleted, which the policy says. |
| Sign in with Apple | shipped: **Email Address** and **User ID** declared above now also cover the address Apple shares and Apple's id of the person. No name is asked for. |
| Free on this phone | shipped: a free account's bank is never sent anywhere and is not collected; the account itself (email, ids, sessions, color, purchase token) is. |
| QBank Cloud purchase | shipped: **Purchase History** declared above. The app sends the server the transaction the App Store signed for a Cloud plan, after a purchase, a restore or a renewal, and the server keeps the subscription under the account, since it decides who has Cloud. |
| Move to Cloud, combine, and Cloud ending | shipped: nothing new is collected. The bank the phone uploads or combines with the server's is Other User Content and Product Interaction, already declared. When Cloud ends the bank comes back to the phone and the server keeps its copy until the account is deleted, which the policy says. |

## `PrivacyInfo.xcprivacy`

The app target carries this file at `QBank/PrivacyInfo.xcprivacy`. The project's folder-synchronized `QBank` group copies it into the app bundle; the test targets and the packages do not. Eddie's Wallet ships the same shape at `EddysWallet/PrivacyInfo.xcprivacy`.

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
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePurchaseHistory</string>
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
| User defaults (`UserDefaults`, `@AppStorage`) | yes: the look setting, the highlighter, the Face ID lock, the Anthropic choice, the sets being written | `CA92.1` | read and written only by the app itself |
| File timestamp (`creationDate`, `modificationDate`, `stat`) | only if the offline store reads file dates | `C617.1` | files inside the app's own container |
| System boot time (`systemUptime`, `mach_absolute_time`) | only if a timer measures elapsed time this way | `35F9.1` | time between events inside the app; never sent off the phone |
| Disk space (`volumeAvailableCapacity...`) | only if the offline store checks free space before saving | `E174.1` | to avoid writing when the phone is full |
| Active keyboards | no | | |

The exam timer is ruled by the server's clock (`serverNow`), so it should not need the boot-time group.

A search of the app and of `Packages/QBankKit` and `Packages/QBankDesign` finds `UserDefaults` only, in the look setting, the highlighter, the Face ID lock, the Anthropic choice and the sets being written (2026-11-28). The manifest declares that group with `CA92.1` and no other required-reason group.

## Related build settings

- **Export compliance:** the app uses only Apple's HTTPS, which is exempt. Set `ITSAppUsesNonExemptEncryption` to `NO` in the app's Info.plist so App Store Connect stops asking on every build.
- **No tracking prompt:** the app never shows the App Tracking Transparency prompt and has no `NSUserTrackingUsageDescription`.
- **Usage descriptions** (`NS...UsageDescription`) are added only with the feature that needs them. Make questions' Take photo uses the camera, so the app carries `NSCameraUsageDescription`. Its photo picker (`PhotosPicker`) runs outside the app and hands over only the photos the person picks, so there is no photo library usage description.
