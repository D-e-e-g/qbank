# QBank privacy policy

Status: this policy describes the QBank app for iPhone and iPad as it ships on the App Store, and the QBank server it talks to. Each claim was checked against the app's and the server's code on the date below. This policy is updated before a change to what the app or the server keeps ships.

Last reviewed against the code: 2026-11-28.

This policy is published at https://qbank-app.dimitrygallego.com/privacy, the privacy policy address in the app and in [app-store-listing.md](app-store-listing.md). [release.md](release.md) says when it is checked again.

## What QBank is

QBank is a study app for iPhone and iPad: practice questions on any subject, with Review, exams, and terms. You sign in with Apple. Your whole question bank works on your device, free, with no connection. QBank Cloud is an optional subscription that keeps your bank on the QBank server instead, so it follows you to your other devices.

One person, the owner, runs the QBank server. It also serves the accounts the owner set up before the App Store release (here called invited accounts), which sign in with email and password, in the app and in the QBank web app.

## What we do not do

- No advertising, ad networks, or advertising identifiers.
- No tracking. Nothing about you is shared with data brokers or used across other companies' apps or websites.
- We do not sell, rent, or share your data with anyone.
- No analytics or crash-reporting services. The app bundles no third-party code that collects data.
- No access to your contacts, location, microphone, health data, or other apps. The camera and your photos are used only to make questions, which only some invited accounts can do, and only for the photos you take or pick (see section 8).
- No chat, public profiles, or feeds.

## What the app and the server keep

### 1. Signing in with Apple

- **What Apple shares.** QBank asks Apple for your email address only, not your name. You can let Apple share your own address or hide it behind a private relay address that Apple forwards to you.
- **What the app sends.** The app sends the QBank server the identity token Apple signed for this sign-in, with a one-time random value (a nonce) the app made for it, over HTTPS. The server checks the token with Apple's public keys (that Apple signed it, for this app, for this nonce, and that it has not expired) and takes each token once.
- **What the server keeps.** Your user account: an account id, Apple's id for you in this app, and the email address Apple shares (when Apple shares none, a placeholder made from Apple's id that reaches no one). The account's name is the part of that email address before the @, or empty when Apple shares none. QBank keeps no Apple token: only a mark that the nonce was used, until the token would have expired.
- **Limits on tries.** After 5 refused Sign in with Apple tries from one IP address, the server refuses more from that address for 15 minutes. For that it keeps the address, a count of refused tries, and when the lock ends. That record names no account, and the server does not remove it when the lock ends.
- **What the device keeps.** The session token (section 3) and Apple's id for you, in the iOS Keychain on that device only. Apple's id names your bank on the device, so signing in again with the same Apple Account opens it. If the server cannot be reached when Apple says yes, your bank opens on the device anyway, and the app keeps that sign-in in the Keychain to send to the server again later.

### 2. Invited accounts: email and password

This section is only for the accounts the owner set up before the App Store release. A new account cannot be made with an email and password in the app.

- **Email address and password.** You sign in with the email address and password of your QBank account. The server stores the email address and a one-way hash of the password, never the password itself. The app sends your password only to the QBank server, over HTTPS, at sign-in, and does not store it. iOS may offer to save it in your own Passwords app; that is Apple's feature and under your control.
- **Linking Sign in with Apple.** In **Settings > Sign in with Apple** you can link your Apple Account to your invited account, so a new device needs no password. The app sends your current password and Apple's identity token and nonce; the server keeps Apple's id for you with your account. Your bank stays on the server, and your email and password keep working.
- **Passkeys saved on the web.** The app does not save passkeys or sign in with them. If you saved a passkey for your account on the web, the server keeps what it kept when you saved it (its public key and id, a name such as "iPhone", when it was saved, and whether it syncs between your devices) until you delete your account. The app never reads or sends any of it.
- **Agent keys.** If you use your own AI agent with QBank, it asks to pair and shows you a short code; in **Settings > Connect an agent**, which the app shows to invited accounts only, or on the web, you type or paste the code, see the agent's name and what it asks to do, and approve or deny it. The app sends only the code and your answer. An approved agent picks its key up from the server itself, so the key never reaches the app. The server keeps each key's name (the one the agent gave), what it may do, when it was made, last used, and revoked, and which sets it imported. While a pairing waits for your answer, the server also keeps the IP address the agent asked from, and removes the pairing a day after it expires. Settings lists your keys and revokes one; a revoked key never works again, and what it imported or changed stays.
- **Display name.** Your account has a name: the one the owner set when the account was made, or, when you signed up on the web, the part of your email address before the @. The app may show it; it does not ask you for one.
- **Account role.** Whether the account is a user account or the owner's admin account, and whether you must choose a new password at your next sign-in.
- **Sign-up list.** Invited accounts sign up on the web, with an email address the owner added to a list. The server keeps each address on that list, with when it was added, until the owner removes it; removing one does not delete an account made with it.
- After 5 wrong passwords in a row from one IP address, the server locks sign-in for that email address from that address for 15 minutes, and after 5 refused sign-ups it locks sign-up for that email the same way. For that it keeps the email address, the IP address, a count of failed tries, and when the lock ends, until a sign-in succeeds or the account is deleted.

### 3. Your sign-in session

- When you sign in, the server creates a session and the app receives a session token. The app stores the token in the iOS Keychain on that device only, and sends it with every request to the server so you stay signed in.
- With each session the server stores when it was created, last refreshed, and expires. It does not record the IP address or the device description (user agent) of a session. Sessions made before 23 November 2026 hold the IP address and device description recorded then; QBank never used them, and they are removed with that session, at the latest when the account is deleted.
- A session expires 400 days after it was last refreshed; the server refreshes it at most once a day while you use it. Signing out removes the token from the device and ends the session on the server when the device can reach it. **Sign out everywhere** in Settings ends every session of your account.

### 4. Your bank on this device (no QBank Cloud)

Without QBank Cloud, your question bank lives only on your device: your semesters, courses, topics, pages, folders, sets, questions, terms, answers, progress, Review list, and exams. A new bank starts with a short sample set that comes with the app.

- **Nothing of your bank is sent to the server.** Every request about your bank is answered on the device, which needs no connection. The server holds your user account and its sessions (sections 1 and 3), its purchase token (section 6), and your Color choice (section 9), and no study content.
- **On the device** the bank is kept in the app's own storage, protected by iOS data protection, and is included in your device's own backup (iCloud Backup or a backup on your computer), because it is your only copy. That backup is Apple's service or your computer, under your control.
- **Signing out keeps your bank** on the device. Signing in again with the same Apple Account opens it. Each of your devices keeps its own bank until you turn on QBank Cloud.

### 5. QBank Cloud: your bank on the server

QBank Cloud is a subscription you buy in the app (section 6). While you have it, your bank is on the QBank server, so it is the same on every device you sign in on.

- **Moving your bank.** When QBank Cloud turns on and your user account has no bank on the server yet, the app sends your whole bank from this device to the server in one file. The server stores it and answers with counts, and the app checks them against its own before it uses the bank on the server.
- **Combining two banks.** When QBank Cloud is on and this device already holds a bank, the app sends that bank to the server and combines it with the bank your user account already has there: for example a second device that has its own bank, or a returning subscriber. The combined bank keeps everything from both. A row changed on both sides keeps the later change, every answer is kept once, and nothing is removed. The app checks the result before it switches, then shows what was combined. The app does this without asking first.
- **A device with no bank of its own**, such as a new iPad you sign in on while QBank Cloud is on, uses the bank on the server and sends nothing up.
- **What the server then keeps** for your account: your whole bank, as in section 7.
- **What stays on the device.** After a move or a combine, the bank file that was on the device stays there as it was, as a safety copy, with a record of each combine (what was joined, and the counts). The app does not use the copy while QBank Cloud is on. Like invited accounts, the app also keeps a copy of your recent courses and the answers waiting to be sent (section 9).

### 6. Purchases

- QBank Cloud is sold through Apple's App Store as an auto-renewing subscription. Apple takes the payment; the app and the server never see your card, bank account, or billing address.
- The server gives your account a random purchase token, and the app buys with it, so the purchase names your QBank account to the server and nothing else about you. The server keeps the token with your account.
- After a purchase, a restore, or a renewal, the app sends the server the transaction the App Store signed. The server checks Apple's signature and keeps, with your account: the plan, the App Store's ids of the subscription and of its latest transaction, when the period it pays for began and ends, whether Apple refunded or revoked it, and the App Store environment. Apple also sends the server signed notices when the subscription renews, ends, is refunded, or is revoked, and the server updates the same record. It uses this only to decide whether your account has QBank Cloud. To take each notice once, it keeps a log of Apple's notices: each one's id, kind, App Store environment, and when it was signed and received. The log does not name your account.
- The server does not receive or keep the price, the currency, or your country or storefront.
- To cancel, use **Manage subscription** in the app or your Apple Account settings.

### 7. Your answers and progress on the server

For an account whose bank is on the server (QBank Cloud, or an invited account), the server keeps:

- every semester, course, topic, page, folder, set, question, and term in your bank, as your account's own study content, which another account cannot see or reach. There is no shared question bank;
- every answer you submit: which question, your response, whether you marked it as a guess, its score, and when you answered;
- your progress per question (how many tries, how many fully right, the latest result) and which questions are on your Review list, including ones you cleared by hand;
- your study sessions: practice sets, Review runs, and exams, with when they started and ended, the folders and question pool you picked for an exam, the time limit, and the score;
- the course you opened most recently, so the app opens where you left off;
- the time each item last changed, so two banks can be combined (section 5).

**The owner can see invited accounts' progress.** The server's admin account can look at an invited account's study content, answers, and progress (to help with studying), repair its progress, and set a temporary password for an invited account that forgot its own. The admin account cannot list, see, or change an account made with Sign in with Apple. No email is sent; the owner gives the temporary password in person.

### 8. Adding questions

- **Importing a question file or writing a set by hand.** The file you choose or paste, or the set you write in the Add tab, is checked and becomes a set in the course and folder you pick. Without QBank Cloud this all happens on the device; with QBank Cloud or an invited account it is sent to the server and kept there with your account.
- **Making questions and exam twins** (only on the invited accounts the owner turns it on for: the app offers them to invited accounts only, and the server allows them only for the accounts the owner lists). The first time you use Making questions or exam twins on a device, the app asks whether it may send your material to Anthropic, naming what is sent (the notes you paste, your photos, a file you choose, or the practice questions you pick for exam twins), to whom, and why. Nothing is sent until you choose Allow; Not now leaves both unused, and the app asks again next time. The choice is kept on that device only, is not sent to the server, and you can change it in Settings. The notes you paste, the photos you take or pick, or the file you choose are sent to the server with the course, folder, and choices you make. The server deletes the photos and files once it has read them. It keeps the text of your material (what you pasted, and what it read from your photos and files) in the record of that set, with the questions it wrote, so the set can carry on where it stopped; the record is deleted with your account. To read your material and to write and check the questions, the server sends it to Anthropic's Claude API under the owner's own Anthropic account; the app never contacts Anthropic itself and holds no key. The questions become a set in the course and folder you pick. The server also keeps a record of each set you start (when, for which course and folder, how far it got, and how much of the AI service it used), to show your recent sets and to keep to a daily limit of 5. **Exam twins** work the same way: Write exam twins on Exam setup sends the course, the folders you tick, and whether to use only the questions you last got wrong; the server sends those practice questions, already in QBank, to Anthropic's Claude API to write a new exam question for each, files them in the same folders, and keeps a record of the job like a set's.
- **Camera and photos.** The app uses the camera only when you tap Take photo while making questions. The photo picker gives the app only the photos you pick; the app cannot see the rest of your photo library.

### 9. Other things kept on your device

- **Saved for offline** (QBank Cloud and invited accounts). So you can practice without a signal, the app keeps a copy of the courses on your Home screen, with their sets and questions, and your recent progress, plus the Review list and terms of each course you open, in its own storage on the device. It saves them by itself while it is online. Answers you give without a connection are scored on the device and wait there until they can be sent. The server ignores an answer it already has, so nothing is counted twice. Exams need a connection and are not kept for offline use.
- **Settings on the device.** Your Look choice (light, dark, or match the device), the highlighter color you last used, whether the Face ID lock is on, and your choice about Anthropic are stored on the device. Your Color choice goes with your account and is kept on the server, so it is the same on every device.
- **Sets you are writing.** A set you begin writing by hand in the Add tab and have not saved is kept as a draft on the device, under your account, and is not sent anywhere until you save it. Signing out keeps your drafts for when you sign back in, another account signed in on the device does not see them, and deleting your account deletes them.
- **The Face ID lock.** When you turn it on, iOS checks your face, fingerprint, or passcode and tells the app only whether it matched. The app never receives or stores any biometric data, and nothing about the lock is sent to the server.
- **Signing out** of an account whose bank is on the server removes the session token, the offline copy, and any answers still waiting to send, and keeps your drafts and any bank and safety copy on the device. The app warns you before it removes answers that have not been sent.
- Deleting the app removes everything it stored on that device, apart from what your device's own backup holds.

### 10. When QBank Cloud ends

QBank Cloud ends when the subscription lapses or you cancel it and its period runs out, or when Apple refunds or revokes it.

- **Your bank comes back to your device.** The app downloads your whole bank from the server into a new file on the device, checks that every item arrived, and from then on uses the bank on the device, as in section 4. Answers still waiting to be sent are added to it. The earlier files on the device stay as they were.
- **The server keeps its copy** of your bank, unchanged, until you delete your user account. It does not use it, and the owner cannot see it. If you subscribe again, the app combines it with the bank on your device (section 5).
- **A device that signs in after QBank Cloud ended** downloads the bank the server holds for your account and combines it with the bank already on that device, into a new file on the device. Nothing is sent to the server.

### 11. Exporting your bank

Settings has **Export my bank**, which saves your whole bank (every question and all your progress) as one file and hands it to the iOS share sheet: from the device when the bank is there, else downloaded from the server. Where the file goes from there (Files, AirDrop, another app) is your choice; QBank keeps no record of it.

### 12. TestFlight

While the app is tested through Apple's TestFlight, Apple may share with the owner the feedback, screenshots, and crash reports you choose to send from the TestFlight app, plus basic information Apple attaches to them (device model, iOS version). That is Apple's service, covered by Apple's privacy policy. The app itself sends nothing to Apple for it.

## Where the data lives and who handles it

- The QBank server runs on a rented server in the United States. All traffic between the app and the server is encrypted with HTTPS.
- The server's database is backed up so it can be restored after a failure. Backup copies are kept in private storage that only the owner can read, and are deleted automatically after about 30 days.
- The hosting and backup storage companies store the server's data on the owner's behalf and do not use it for anything else.
- Apple handles Sign in with Apple, the App Store purchase, and its notices about the subscription, under Apple's privacy policy. The server reaches Apple only to read Apple's public keys and, when you delete your account, to revoke QBank's Sign in with Apple authorization.
- No other company receives your data from QBank, except Anthropic, which receives the material invited accounts send to make questions, and the practice questions they pick for exam twins (section 8), and processes them under Anthropic's own commercial terms and privacy policy.

## How long data is kept

- **On the server:** your user account, and for a bank on the server your study content, answers, and progress, are kept until the account is deleted. That includes the bank of an account whose QBank Cloud ended (section 10). The subscription record and the purchase token are kept with the account. Expired sessions stop working; their records are removed with the account. Photos and files sent to make questions are deleted once the server has read them; the text of your material stays in the record of that set until the account is deleted. Deleting a course or study topic, a page, a set, a folder, or a past exam in the app hides it everywhere, and Undo can bring it back as it was for 30 days; it stays, with your answers to it, until the account is deleted, and nothing is ever deleted unless you confirm it. The same holds for a bank on the device.
- **In backups of the server:** up to about 30 days after deletion from the live server.
- **On your iPhone or iPad:** a bank on the device, its safety copies, and its records of combines stay until you delete your account or the app. The offline copy and answers waiting to send stay until you sign out, delete your account, or delete the app.

## Deleting your account and data

**An account made with Sign in with Apple.** Open **Settings > Delete account** and confirm with a fresh Sign in with Apple; any other Apple Account deletes nothing. The app first erases what it kept of the account on the device you delete from: your bank, its safety copies and records of combines, the offline copy, answers not yet sent, and the sets you were writing. Then it sends the server Apple's identity token, the nonce, and Apple's one-time authorization code. The server checks the token, uses the code to ask Apple to revoke QBank's Sign in with Apple authorization for your Apple Account, then deletes your user account for good, with everything linked to it: sessions on every device, your bank if it is on the server (also after QBank Cloud ended), the subscription record, and the purchase token. If Apple cannot be reached to revoke, the server still deletes the account. If the delete stops part way, the app offers to finish it or to sign out; signing out keeps the account on the server until you sign in again and delete it in Settings. A bank kept on another device without QBank Cloud stays on that device until you delete the app there. Deleting your account does not cancel a QBank Cloud subscription; Delete account offers **Manage subscription** to cancel it.

**Stopping Sign in with Apple outside the app.** If you stop using Sign in with Apple with QBank in your Apple Account settings, Apple tells the server, which ends every session of your account; signing in with Apple again opens the same account. If you delete your Apple Account, Apple tells the server, which ends every session and removes its link to your Apple Account. Neither deletes your QBank account or a bank on the server: delete the account in the app first, or ask the owner to delete it (contact below).

**An invited account.** Open **Settings > Delete account** and enter your password. The server deletes the account for good, and with it everything linked to it: sign-in, sessions on every device, passkeys, agent keys, a linked Sign in with Apple, your study content (semesters, courses, topics, pages, folders, sets, questions, and terms), answers, progress, Review list, exams, the records of the sets you made questions for, and your last-opened course. The app then signs out and deletes what it kept on your device, including answers not yet sent and the sets you were writing. Your email stays on the owner's sign-up list until it is removed.

Either way, nothing goes to Recently deleted and there is no Undo. Apart from an invited account's email on the sign-up list, what stays on the server names no account: the records of refused Sign in with Apple tries by IP address (section 1) and the log of Apple's subscription notices (section 6). Backup copies of the server age out within about 30 days. You can also ask the owner to delete your account (contact below). If you only want a copy of your data, use **Export my bank** first.

## Children

QBank is a general study tool. It is not directed at children.

## Changes to this policy

A change to what the app or the server keeps updates this policy before the change ships, and the date at the top says when it was last checked against the code.

## Contact

For privacy questions or to delete your account, email dimitrygallego@gmail.com. For questions about the source code, open an issue at https://github.com/D-e-e-g/qbank/issues; never put personal data in a public issue.
