# App Store setup: the Apple checklist

Every step the owner takes on Apple's side to put QBank on the App Store with a Cloud subscription: who does it, in what order, and the exact names to type. [release.md](release.md) covers TestFlight uploads; [app-store-listing.md](app-store-listing.md) and [app-review.md](app-review.md) hold the listing and review text.

**Nothing here is done yet.** No step is entered in App Store Connect, the developer portal, DNS or any server by this file or by a worker. The owner clicks; a worker prepares the text.

Apple's pages were read on **2026-11-22**. Apple changes its screens often, so each step names the page it came from. Where a screen differs from the page, follow the screen and fix this file in the same pull request.

## How to read a step

Each step carries one tag:

| Tag | Meaning |
|---|---|
| **Owner click** | Only the owner can do it: it needs the owner's Apple account, role or money. A worker may walk the owner through it. |
| **Owner vault step** | A secret that goes into Automic Vault, never into Git, chat or a file in this repository. |
| **Worker-prepared text** | The words to type are written here or in the document named. The owner pastes them. |
| **Waiting** | Blocked on something open. The step says what, and nothing in it is final until that closes. |

A step can carry two tags (text prepared by a worker, clicked by the owner).

One thing is still open and is named wherever it bites:

- **Later pull requests.** The notification route (S-08), the privacy answers (I-43) and the listing text (I-44) do not exist yet. Steps 10, 12 and 13 name which one they wait on.

## The names, in one place

Type these exactly. A mistake in a product id cannot be undone.

| Thing | Value |
|---|---|
| Bundle id (exists) | `com.dimitrygallego.qbank` |
| Subscription group, reference name | `QBank Cloud` |
| Subscription group, display name shown to people | `QBank Cloud` |
| Monthly product id | `com.dimitrygallego.qbank.cloud.monthly` |
| Monthly duration and price | 1 month, US$4.99 |
| Yearly product id | `com.dimitrygallego.qbank.cloud.yearly` |
| Yearly duration and price | 1 year, US$29.99 |
| Family Sharing | off |
| Introductory offer (trial) | none |
| Billing grace period | on |
| App price | free |
| Server | `https://qbank.dimitrygallego.com` |

## The order

| # | Step | Who | When |
|---|---|---|---|
| 1 | Paid Apps Agreement | Owner click | Now |
| 2 | Tax forms | Owner click | Now, after 1 |
| 3 | Banking | Owner click | Now, after 2 |
| 4 | Small Business Program | Owner click | Now, after 1 |
| 5 | Digital Services Act status (not a trader) | Owner click | Now; needed before submission |
| 6 | Sign in with Apple on the App ID | Owner click | Before 7 |
| 7 | Sign in with Apple key, into the vault | Owner click, owner vault step | Before the server's account deletion (S-06) is used |
| 8 | Subscription group and the two subscriptions | Owner click, worker-prepared text | After 1, before the plans sheet (I-33) is tried on a device |
| 9 | Family Sharing off, no trial, billing grace on | Owner click | With 8 |
| 10 | App Store Server Notifications, version 2 | Owner click, **waiting** | After S-08 is live |
| 11 | Sandbox tester | Owner click | Before the device pass (R-2) |
| 12 | App Privacy | Owner click, worker-prepared text, **waiting** | Before submission |
| 13 | Age rating and content rights | Owner click, worker-prepared text | Before submission |
| 14 | Countries and regions | Owner click | Before submission |
| 15 | Price, copyright, review contact | Owner click | Before submission |
| 16 | Privacy policy, support and terms addresses | Owner click | Before submission |
| 17 | Release option | Owner click | At submission |
| 18 | Attach the subscriptions to the version | Owner click | At submission |
| 19 | Optional keys and notices | Owner click, owner vault step | Only if S-12 or S-13 is taken |

Steps 1 to 5 are the owner's first move: the subscription cannot be tested, even in the sandbox, until the agreement is active.

## Steps

### 1. Paid Apps Agreement

**Owner click.** Role: Account Holder.

- [ ] App Store Connect > **Business**. On the **Agreements** tab, find the **Paid Apps** row and click **View and Agree to Terms**. Read it and click **Agree**. A two-factor code may be asked.

Apple says accepting cannot be undone. A new app or in-app purchase cannot be created until the latest Paid Apps Agreement is accepted, and the agreement must be **Active** to test in-app purchases in the sandbox. Apple's status list has Pending User Info and Processing before Active, and steps 2 and 3 feed it, so start today and check that the row reads **Active** before step 11. [release.md](release.md) step 4 covered only the agreements a free app needs; this is the one it left out.

Apple: [Sign and update agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/), [View agreements status](https://developer.apple.com/help/app-store-connect/manage-agreements/view-agreements-status/), [Overview for configuring in-app purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/). Read 2026-11-22.

### 2. Tax forms

**Owner click.** Roles: Account Holder, Admin or Finance. Needs step 1.

- [ ] **Business** > **Agreements** tab > **Tax Forms** > **Add Tax Info** next to the form, or the **+** next to Tax Forms, then **Paid Apps**. Fill it in and click **Submit**. A US-based developer completes the W-9.

Apple says a submitted form cannot be changed in App Store Connect; a correction goes through Apple support. Check each entry before **Submit**.

Apple: [Provide tax information](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/). Read 2026-11-22.

### 3. Banking

**Owner click.** Roles: Account Holder, Admin or Finance. Needs steps 1 and 2.

- [ ] **Business** > **Agreements** tab > **Bank Accounts** > **Add Bank Account**. Choose the bank's country or region, then the currency, account type, account number, and the account holder's details. Tick the statement and click **Add**.

Type the details exactly as the bank shows them, or the payment may be rejected. Apple pays into one bank only. Apple processes bank details only after every tax form the paid agreement needs is submitted.

Apple: [Enter banking information](https://developer.apple.com/help/app-store-connect/manage-banking-information/enter-banking-information/). Read 2026-11-22.

### 4. Small Business Program

**Owner click.** Role: Account Holder. Needs step 1.

- [ ] Enroll through Apple's program page. It gives Apple's 15% rate on paid apps and in-app purchases instead of 30%. A developer new to the App Store qualifies; so does one with up to US$1 million in proceeds in the prior calendar year.

Timing matters: Apple adjusts proceeds fifteen days after the end of the fiscal month in which enrollment is approved, so enroll before the first paying customer. Apple's page does not describe the enrollment screens (the enrollment page needs a sign-in), so follow the screen.

Apple: [App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/). Read 2026-11-22.

### 5. Digital Services Act status (not a trader)

**Owner click.** Roles: Account Holder or Admin. The app launches without the EU, and the owner is not a trader under the EU Digital Services Act (DSA). Apple still wants a declaration, so make it once.

- [ ] **Business** (at the top) > **Agreements** tab > scroll to **Compliance** > next to **Digital Services Act**, **Complete Compliance Requirements**. Choose **I'm not a trader under the DSA or I don't plan to distribute in the EU** (Apple's page words it **This is not a trader account.**). Apple's page says no contact information is needed. **Done**.
- [ ] Nothing else is asked: no address, no P.O. Box, no phone number, no document.

Apple's page words the two options "This is a trader account." and "This is not a trader account." The screen words the second one "I'm not a trader under the DSA or I don't plan to distribute in the EU", as the owner reported it; it is the one that means not a trader. Step 14 takes the EU storefronts out, so no EU page ever shows trader details.

**Adding the EU later** needs, first, trader status: the same screen with the trader option (Apple's page words it **This is a trader account.**). Then the owner enters an address or P.O. Box, a phone number and an email address, validates the phone and email with a code, and uploads a current document that proves the name and address (a P.O. Box also needs a receipt or bill that ties the owner to it). Apple shows these details publicly on the app's page in the EU. The app's own setting is under **Apps** > QBank > **General** > **App Compliance** > **Digital Services Act** > **Edit**. Only after the status is verified would the EU storefronts be ticked in step 14. Apple removes an app from the EU storefronts while it has no verified status.

Apple: [Manage European Union Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/). Read 2026-11-22. The menu path and the option wording "This is not a trader account." are from that page; the screen wording of that option is as the owner reported it.

### 6. Sign in with Apple on the App ID

**Owner click.** Roles: Account Holder or Admin.

The plan expected automatic signing to add this capability on the first `scripts/testflight-upload.sh --no-upload` run after Sign in with Apple ships (I-30), as it did for Associated Domains ([release.md](release.md), "The Associated Domains capability"). The key in step 7 is tied to an App ID that already has the capability, and it is needed before I-30, so do it in the portal now. Signing then finds it already on.

- [ ] developer.apple.com > Account > **Certificates, Identifiers & Profiles** > **Identifiers** > `com.dimitrygallego.qbank` > **Edit**. Tick **Sign In with Apple**, click **Configure**, and choose to enable the App ID **as a primary App ID** (Apple: for a new app, enable it as a primary). **Save**, then **Save** at the top right. **Confirm** any warning.

Apple says editing an App ID invalidates the provisioning profiles that contain it. The next signed build regenerates them (`-allowProvisioningUpdates` in `scripts/testflight-upload.sh`), so a development build on a device may ask for a new profile once.

Not part of this step, and not done by it: the capability and its entitlement in the app. I-30 added `com.apple.developer.applesignin` to `QBank/QBank.entitlements`, pinned in `test/release-checks.sh` and required by the export check in `scripts/testflight-upload.sh` (see the capabilities section of [release.md](release.md)).

Apple: [About Sign in with Apple](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple/), [Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/). Read 2026-11-22. The page that describes grouping apps was not opened.

### 7. Sign in with Apple key, into the vault

**Owner click, owner vault step.** Roles: Account Holder or Admin. Needs step 6. The server uses this key only to revoke a person's Apple token when they delete their account (Guideline 5.1.1(v): apps that support Sign in with Apple should use its REST API to revoke user tokens). Signing people in needs no secret.

- [ ] developer.apple.com > **Certificates, Identifiers & Profiles** > **Keys** > **+**. **Key Name**: `qbank-sign-in-with-apple`. Tick **Sign in with Apple**, click **Configure**, choose the primary App ID `com.dimitrygallego.qbank`. Continue, **Confirm**, then **Download**.
- [ ] Note the **Key ID** (under the key's name on the Keys page) and the **Team ID** (developer.apple.com > Membership details).
- [ ] At the owner's Mac, save all three in Terminal. The values never appear on screen or in chat:

  ```sh
  av save SIGN_IN_WITH_APPLE_KEY_ID      # hidden prompt: paste the Key ID
  av save SIGN_IN_WITH_APPLE_TEAM_ID     # hidden prompt: paste the Team ID
  av save --stdin SIGN_IN_WITH_APPLE_KEY_P8 < ~/Downloads/AuthKey_REPLACE_WITH_KEY_ID.p8
  av list                                # shows the names, never the values
  ```

- [ ] Delete the `.p8` from Downloads and empty the Trash. The vault holds the only copy.

Apple offers the `.p8` for download **once**. If it is lost, make a new key (an App ID can hold two) and revoke the old one. Never put the file, the Key ID or the Team ID in this repository: the Team ID stays out of Git ([release.md](release.md), "Security boundaries").

A worker never reads these entries. The key goes from the vault into the server's environment through the owner's Allow, when the server change that revokes tokens (S-06) is deployed. The server's setting names are chosen there; the vault names above are this repository's. The App Store Connect upload key keeps its one job, uploads.

For the server's call, Apple's revoke endpoint takes the app's App ID (the bundle id) as `client_id` and a client secret signed with this key, with the Team ID and Key ID in it. A native-only app needs no Services ID.

Apple: [Create a private key](https://developer.apple.com/help/account/keys/create-a-private-key/), [Create a Sign in with Apple private key](https://developer.apple.com/help/account/capabilities/create-a-sign-in-with-apple-private-key/), [Get a key identifier](https://developer.apple.com/help/account/keys/get-a-key-identifier/), [Revoke tokens](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens), [Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/). Read 2026-11-22. The Configure and Continue labels are Apple's page wording as far as it gives them; follow the screen. The two-keys-per-App-ID limit is from a search summary, not a page read in full.

### 8. Subscription group and the two subscriptions

**Owner click, worker-prepared text.** Needs step 1 (the agreement) and the app record, which exists.

**Product ids cannot be reused.** Apple says a product id cannot be edited after it is saved, and cannot be reused within the app even after the product is deleted. Apple's page says this of in-app purchases, and the same rule is expected for subscriptions. Type the two ids once, from this file, and check each against the table above before **Create**. A subscription group can be deleted only when it has no subscriptions, so a wrong group name is fixable; a wrong product id is not.

- [ ] App Store Connect > **Apps** > QBank > **Monetization** > **Subscriptions** > **+**. Reference name `QBank Cloud`. **Create**.
- [ ] In the group, **Display Name and Description** > **Add**: language English (U.S.), display name `QBank Cloud`. Apple does not show the reference name to people; it shows the display name.
- [ ] In the group > **Create**: **Reference Name** `QBank Cloud Monthly`, **Product ID** `com.dimitrygallego.qbank.cloud.monthly`. **Subscription Duration**: **1 month**. A duration cannot change after submission.
- [ ] **Subscription Prices** > **Add Subscription Price**: country **United States**, price **US$4.99**, **Next**, then **Confirm**. Apple fills in comparable prices for every storefront, with tax and exchange rates. The owner reviews the list before **Next**; each one can be edited.
- [ ] **Availability**: every country the app is sold in (step 14).
- [ ] Localization, English (U.S.): display name `QBank Cloud Monthly`, description `Save your bank to Cloud and sync devices`.
- [ ] In the group > **Create**: **Reference Name** `QBank Cloud Yearly`, **Product ID** `com.dimitrygallego.qbank.cloud.yearly`, **Subscription Duration** **1 year**, price **US$29.99**, availability as above, localization display name `QBank Cloud Yearly`, same description.
- [ ] **Subscription level**: Apple ranks the group's products from level 1 (offers the most) down. Monthly and yearly give the same content for different durations, which Apple lets sit at the same level. Leave them at one level. If Apple's screen puts them on separate levels, the yearly plan is level 1.
- [ ] **Review Information** on each: a review screenshot and notes. Apple says the screenshot must show the item offered, is for review only, and can be replaced but not removed. A worker supplies the screenshot of the plans sheet (I-45, from I-33) and the notes: Cloud keeps the person's question bank on the QBank server and syncs it between devices; everything else in the app is free and needs no subscription; the path to the plans sheet comes from I-33. Review notes may run to 4,000 characters.

Apple limits a subscription's display name to 30 characters (at least 2) and its description to 45. The two names and the description above fit. Apple's page states these limits for in-app purchases in general, not for subscriptions in particular, so the screen has the last word. A localized group name takes no emoticons, accents or markup.

After a save, Apple says changes to product metadata can take up to one hour to appear in the sandbox.

Apple: [Offer auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions), [In-app purchase information](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/), [Manage pricing for auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions/). Read 2026-11-22; the last part of the first and third pages was cut off when read. The subscription page does not list which localization fields are required beyond display name and description.

### 9. Family Sharing off, no trial, billing grace on

**Owner click.** Done with step 8.

- [ ] **Family Sharing**: leave it off on both subscriptions. It is off until someone turns it on, and Apple says once it is turned on it cannot be turned off, so never click **Turn On** in the **Family Sharing** section of a subscription.
- [ ] **Introductory offer**: add none. A trial exists only if someone sets one up (**Subscription Prices** > **View all Subscription pricing** > **Set up Introductory Offer**), so do not. Apple says an offer, once made, cannot be edited, only deleted and made again.
- [ ] **Billing grace period**: App Store Connect > QBank > **Subscriptions**, **Billing Grace Period** section > **Set Up Billing Grace Period**. Apple offers **3**, **16** or **28** days. **16 days**, **All Renewals**, **Production and Sandbox Environment**. Click **Confirm**. This is one app-wide setting, not per product. A change can take up to 24 hours and applies to upcoming renewals.

The server, not the app, decides who has Cloud, from Apple's notices; S-08 handles grace and billing retry.

The plan names the switch but not the length; 16 days is the number chosen here, between Apple's shortest and longest. Change it before the first paying customer if the owner prefers another.

Apple: [Turn on Family Sharing for in-app purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases/), [Set up introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/), [Enable billing grace period](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions). Read 2026-11-22.

### 10. App Store Server Notifications, version 2

**Owner click. Waiting** on S-08 being live on the server, which fixes the route and says what it answers.

- [ ] App Store Connect > QBank > **General** > **App information**. Under **General Information**, find **App Store Server Notifications**.
- [ ] **Production Server URL** > **Set Up URL**: `https://qbank.dimitrygallego.com` plus the route S-08 documents.
- [ ] **Sandbox Server URL** > **Set Up URL**: the same, unless S-08 says the sandbox has its own route.
- [ ] Choose **Version 2 notifications**. **Save**.

Version 1 is deprecated; choose version 2. The URL must be HTTPS with TLS 1.2 or later, and one URL can serve both environments. With no Sandbox URL, sandbox notices go to the Production URL. With only a Sandbox URL, no production notice is sent, so set both.

The sandbox is how the route is proven: a sandbox purchase from a TestFlight build must show a received line in the server's log (R-2). Apple's test-notification request belongs to the App Store Server API, which needs the optional key in step 19, so it is not planned.

Apple: [Enter server URLs for App Store Server Notifications](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/enter-server-urls-for-app-store-server-notifications), [Enabling App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications/enabling-app-store-server-notifications). Read 2026-11-22. The documentation pages came as text with some links missing.

### 11. Sandbox tester

**Owner click.** Roles: Account Holder, Admin, App Manager or Developer. Needs step 1, with the agreement **Active**.

- [ ] App Store Connect > **Users and Access** > **Sandbox**. On first use, **Create Test Accounts**; then **+**. First and last name, an email, a password and the App Store country or region (**United States**).
- [ ] The email must not be an Apple Account and must never have bought iTunes or App Store content. A plus address of a mailbox the owner controls works (`name+qbank-sandbox@...`). Apple does not let the name or email be edited later.
- [ ] On the iPhone, with **Developer Mode** on, the tester appears in **Settings** > **Developer** after a first purchase attempt in a development-signed app. For a build from TestFlight, sign out of the production account under **Media & Purchases**, then in **Settings** > **Developer** scroll to the bottom and choose **Sign In** under **Sandbox Apple Account**.
- [ ] A sandbox account works only for apps in the same developer account. Keep its email and password in the vault or the owner's password manager, never in this repository.

TestFlight builds run in the sandbox without a tester for a basic purchase. The tester is needed to test billing retry and to change renewal rates. Apple's TestFlight page says each subscription renews **daily**, up to six times in a week, whatever its length, so the device pass sees a month renew in a day.

Apple: [Create a sandbox Apple Account](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account), [Testing in-app purchases with sandbox](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox), [Testing subscriptions and in-app purchases in TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/). Read 2026-11-22.

### 12. App Privacy

**Owner click, worker-prepared text. Waiting** on I-43 (the privacy answers and the policy that match the build). Apple has no way to enter these by script, and incomplete answers blocked another app's first submission.

- [ ] App Store Connect > QBank > **App Privacy** > **Get Started**. Choose **Yes, we collect data from this app**. **Next**. Select each type below, then open each one under **Data Types** and answer; **Save**. Then **Publish** and confirm **Publish Your App Privacy Responses?** Answers can be edited and published again at any time.
- [ ] **Privacy Policy** > **Edit**: the policy's address (step 16). Apple requires it for iOS.

The types, drafted from the decisions and **to be checked by I-43 against the shipped build**. [privacy-manifest.md](privacy-manifest.md), which I-43 rewrites, is the authority, and the owner types from it, not from this table:

| Apple category | Data type | Why |
|---|---|---|
| Contact Info | Email Address | the Sign in with Apple email, which may be Apple's relay address, and the invited accounts' email |
| Identifiers | User ID | the Apple user id and the server's account id |
| Purchases | Purchase History | the subscription record the server keeps to decide who has Cloud |
| User Content | Other User Content | the question bank, answers and progress, **for Cloud and invited accounts**; a free bank stays on the phone and is not collected |
| User Content | Photos or Videos | Make questions, only for the accounts the owner enabled it for; the same build ships it |
| Usage Data | Product Interaction | study sessions and the last course used |

Each is linked to the person, not used for tracking, with the purpose **App Functionality** only. Apple lists the purposes as Third-Party Advertising, Developer's Advertising or Marketing, Analytics, Product Personalization, App Functionality and Other Purposes. Apple says developers need not disclose data Apple itself collects. Its pages do not say whether Sign in with Apple's email counts as Email Address; the table counts it, as the server stores it.

Apple: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy), [App privacy details](https://developer.apple.com/app-store/app-privacy-details/). Read 2026-11-22. The per-type questions are not listed on Apple's help page, only on the screens.

### 13. Age rating and content rights

**Owner click, worker-prepared text.** The answers come from I-44, which writes them for a general study tool.

- [ ] **General** > **App Information**. Under **Age Ratings**, **Set Up Age Ratings** (later **Edit** at the top of the page). Apple's questionnaire runs in sections: **In-App Controls** (Parental Controls, Age Assurance), **Capabilities** (Unrestricted Web Access, User-Generated Content, Social Media, Messaging and Chat, Shared Location, Advertising and others), **Mature Themes**, **Medical or Wellness**, **Sexuality or Nudity**, **Violence**, and **Chance-Based Activities**. Each content item takes a frequency. Then **Age Categories and Override**: choose **Not Applicable**, and leave **Age Suitability URL** empty. **Save**.
- [ ] **Content Rights**, on the same page: whether the app contains, shows or accesses third-party content, from I-44.

The rule for the answers: they describe what the build ships, its sample set, and what people can bring in. Questions a person writes or imports stay private to them and are not shared, so answer the User-Generated Content question on that basis, and I-44 says how. [app-store-listing.md](app-store-listing.md) holds the nursing-era answers; they are replaced, not reused.

Apple requires the new questionnaire; an app with no rating (**Unrated**) cannot be published. The January 31, 2026 deadline for existing apps has passed. **Made for Kids** cannot be undone once approved, so never pick it.

Apple's help gives no question text for Content Rights, only that an app showing third-party content needs the rights to it; the screen's wording is what the owner answers.

Apple: [Set an age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating), [Age ratings values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions), [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/), [Upcoming requirements (age ratings)](https://developer.apple.com/news/upcoming-requirements/?id=07242025a). Read 2026-11-22. The age-rating definitions page was read to about 100,000 of its 118,000 characters.

### 14. Countries and regions

**Owner click.** Launch is without mainland China and without the EU.

- [ ] **Pricing and Availability** > **App Availability** > **Set Up Availability**. Choose **Specific Countries or Regions**, and clear these 28 (App Store Connect's names): **China mainland**, **Austria**, **Belgium**, **Bulgaria**, **Croatia**, **Cyprus**, **Czechia**, **Denmark**, **Estonia**, **Finland**, **France**, **Germany**, **Greece**, **Hungary**, **Ireland**, **Italy**, **Latvia**, **Lithuania**, **Luxembourg**, **Malta**, **Netherlands**, **Poland**, **Portugal**, **Romania**, **Slovakia**, **Slovenia**, **Spain**, **Sweden**. **Next**, **Confirm**.
- [ ] Leave the box at the bottom of the list **unticked**. It adds every country Apple opens later, and one of them could be an EU member's or China's. Add later countries by hand.
- [ ] The count after the change is **147**: Apple's availability page counts 175 storefronts, less these 28. Apple's start-times table for the same storefronts lists 174 rows, so the screen may show 146; both lists hold all 27 member states and China mainland, so the 28 are right either way. Read the count off the screen and make sure the 28 are the only ones missing.
- [ ] The subscriptions' availability in step 8 follows the same list.

**Adding mainland China later** takes an ICP filing number from China's ministry (outside Apple), entered where Apple's **Availability in China mainland** section says. Without a valid number the app shows **ICP Filing Number Missing** and is not available there. **Adding the EU later** takes trader status first (step 5).

Apple: [Manage availability for your app](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store), [Start times by country or region](https://developer.apple.com/help/app-store-connect/reference/app-store-pricing-and-availability-start-times-by-country-or-region/), [App information, Availability in China mainland](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/). Read 2026-11-22. The names "ICP Filing Number Missing" and "...Invalid" come from the status reference and search results, not from this page.

### 15. Price, copyright, review contact

**Owner click.** The text is the owner's.

- [ ] **Pricing and Availability** > **Price Schedule** > **Add Pricing**: base country **United States**, the free price. Apple's pages give no "Free" label, so pick the US$0.00 price point. **Next**, **Next**, **Confirm**.
- [ ] The version page, **Copyright**: `2026 OWNER_NAME`, the name on the Apple Developer account. Apple adds the copyright symbol.
- [ ] **App Review Information**, on the version page: first name, last name, phone (international format, `+` and the country code) and email, then the notes. The owner types their real details in App Store Connect only. They never go into this repository. The notes come from I-44.
- [ ] **Sign-in required**: leave off. The reviewer uses their own Apple Account. If Apple asks for an account for the email-and-password door, make the demo account with the how-to in [app-review.md](app-review.md) and type it into App Store Connect only.

Apple allows notes up to 4,000 bytes.

Apple: [Set a price](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price/), [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information). Read 2026-11-22. Apple's reference lists the contact as one property (name, email, phone); the separate first-name and last-name boxes and the sign-in checkbox are the screen's, which Apple's page does not describe.

### 16. Privacy policy, support and terms addresses

**Owner click.** The addresses are in [app-store-listing.md](app-store-listing.md); the pages must answer first ([ci.md](ci.md#public-pages-pagesyml)). The address goes into shipped builds, so it must stay put.

- [ ] **App Privacy** > **Privacy Policy** > **Edit** (step 12): the privacy address.
- [ ] **App Information**, the version's **Support URL**: the support address.
- [ ] The subscriptions' terms: the description on the version page, and the app, must link the **Terms of Use** and the **Privacy Policy**. The owner uses Apple's standard terms; the app names all three addresses once, in `QBank/Shared/LegalLinks.swift`.

The privacy address changes with the next app version, not instantly, when edited. Apple wants both links in the app and in the metadata for a subscription; an earlier app that sold Cloud this way was rejected under 3.1.2 for a missing terms link.

Apple: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy), [App Store subscriptions](https://developer.apple.com/app-store/subscriptions/), [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), 3.1.2. Read 2026-11-22. Guideline 3.1.2 asks for the price and what it buys to be clear before a person subscribes; the list of what the plans sheet shows comes from the subscriptions page, not the guideline.

### 17. Release option

**Owner click.** The owner's call, one switch at submission.

- [ ] The version page > **App Store Version Release**. Choose one:
  - **Release the app yourself** (Apple: "Manually release this version"). **Recommended**: the server is the authority for Cloud and must be up and checked before the public sees the app.
  - **Automatically release the app after approval**.
  - **Automatically release the app but no earlier than a specified date**, with a date and time.
- [ ] **Save**. With the first, release later from **Pending Developer Release**: **Release This Version**, then **Confirm**.

Apple: [Select an App Store version release option](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/). Read 2026-11-22.

### 18. Attach the subscriptions to the version

**Owner click.** At submission. A first subscription is reviewed together with an app version, and the group goes with it.

- [ ] **Monetization** > **Subscriptions**, open a subscription > **Add for Review**. Choose an existing draft or **Create New Submission**, then the platform and the app version, and add the group if it is not yet approved. Both subscriptions go in the same submission. **Submit for Review** in the submission window, once the version is ready.

Each subscription needs its metadata complete first (the localization, price and review screenshot of step 8). After the first approval, later subscriptions need no new app version.

The plan said the subscriptions are added on the version's own page. Apple's current help describes this **Add for Review** path and never an "In-App Purchases and Subscriptions" section on the version page, so this file follows Apple. Forum posts mention both.

Apple: [Offer auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions), [Submit an in-app purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/). Read 2026-11-22. Apple's status page for in-app purchases names **Prepare for Submission** and **Ready for Review**; its subscription statuses were not found.

### 19. Optional keys and notices

**Owner click, owner vault step.** Only if the work is taken. None blocks the release.

- [ ] **An In-App Purchase key** for the App Store Server API, only with S-13 (reconcile a subscription's state with Apple). App Store Connect > **Users and Access** > **Integrations** > **In-App Purchase**. A new `av save` set, named when S-13 is written.
- [ ] **A Sign in with Apple server notice URL**, only with S-12 (ends sessions when a person stops using Apple with the app). It is registered on the primary App ID's **Sign in with Apple** configuration, one URL for each app group and key.

Apple: [About Sign in with Apple](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple/). Read 2026-11-22. The In-App Purchase key page was not read.

## What is still open

- **S-08**, the notification route: step 10.
- **I-43 and I-44**, the privacy answers, the age-rating answers and the review notes: steps 12, 13 and 15.

## Changing this file

Apple's screens move. When a step's screen no longer matches, fix the step, the page link and the date read in the same pull request. A step the owner completes is ticked in the same pull request, with the date, as [release.md](release.md) does.
