# Mímir Privacy Policy

*Effective: September 10, 2026*

Mímir is a developer-tools web browser for Android published by MstSage Entertainment, LLC.
This policy explains what the app does with data. The short version: **Mímir does not collect,
store on our servers, or share any personal data. We have no servers.**

## Data the app stores on your device only

Mímir keeps the following on your device, in the app's private storage, and nowhere else:

- Browsing history, bookmarks and folders
- Settings (search engine, home page, appearance, DevTools preferences)
- User scripts and styles you create or import, and request-blocking rules
- Cookies, site data and cache belonging to the websites you visit, managed by Android System WebView

You can delete history, cookies, cache and site storage from **Settings → Privacy & data**, and
everything is removed when you uninstall the app. None of this data is transmitted to us.

## Network connections the app makes

- **Websites you visit** receive the requests a browser normally sends. Their own privacy policies apply.
  Mímir sends a desktop or mobile user-agent string according to your setting and does not add identifiers.
- **Chrome DevTools frontend**: when you open DevTools, the interface is loaded from Google's content
  delivery network (`chrome-devtools-frontend.appspot.com`). That request is subject to Google's privacy policy.
  The connection between DevTools and the page stays entirely on your device.
- **Script imports**: when you import a script or style from a URL, Mímir downloads that file from the
  address you entered and stores it locally.
- **Google Play Billing** (Play Store version only): optional tips are processed by Google Play. Mímir
  receives only a confirmation that a purchase completed; we never see payment details. Google's privacy
  policy applies to the transaction.
- **Donation link** (non-Play builds only): the Support page can open our PayPal page in a browser tab.
  PayPal's privacy policy applies there.

## Crash reports

If the app crashes, a diagnostic report is written to a text file in your device's Downloads folder
so you can read it or send it to us if you choose. Nothing is sent automatically.

## Analytics, advertising and tracking

Mímir contains no analytics, no advertising, and no tracking SDKs.

## Permissions

- `INTERNET` and `ACCESS_NETWORK_STATE`: required to load web pages.
- `com.android.vending.BILLING` (Play version): required for optional tips through Google Play.

## Children

Mímir is a general-purpose developer tool and is not directed at children under 13.

## Changes

If this policy changes, the updated version will be published at the same address with a new effective date.

## Contact

MstSage Entertainment, LLC — rane@mstsage.com
