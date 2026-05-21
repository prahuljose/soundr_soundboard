# Privacy Policy for Soundr

**Effective date:** 22 May 2026
**Last updated:** 22 May 2026

This Privacy Policy explains how the Soundr mobile application ("Soundr", "the app", "we", "us") handles information when you use it. Soundr is published by **Rahul Jose** ("the developer").

In short: **Soundr is a fully offline app. We do not collect, transmit, sell, or share any personal data.** Everything you do in the app stays on your device.

---

## 1. Information we collect

**We collect nothing.**

Soundr does not have a backend server. There are no accounts, no sign-ups, no logins, and no analytics SDKs. The app does not have internet permission in its manifest — it physically cannot send data anywhere.

Specifically, we **do not** collect:

- Personal identifiers (name, email, phone number, device ID)
- Location
- Contacts, calendar, photos, or files outside the app's own storage
- Usage analytics, crash logs, or telemetry
- Advertising identifiers
- Audio recordings, audio analysis results, or decibel readings

---

## 2. Data Soundr stores on your device

Some Soundr features create data that lives **only on your device**:

| Feature | What's stored | Where |
|---|---|---|
| Voice Memo | Recorded audio (WAV) | App-private storage (`voice_memos/`) |
| Decibel Meter | Saved session history (min / max / avg dB, duration, optional name, optional waveform thumbnail) | `decibel_sessions.json` in app-private storage |
| Decibel Meter | User preferences (calibration offset, A-weighting, alert threshold) | `decibel_prefs.json` |
| Custom Clips | Recorded or imported audio (WAV) + names, emojis, categories | App-private storage |
| Soundboard | Favourites, theme preference, accent colour | App-private storage |

This data:
- Never leaves your device
- Is not synced, backed up to a cloud, or transmitted to us or any third party
- Is deleted when you uninstall the app (Android removes app-private storage on uninstall)
- Can be individually deleted from within the app at any time (delete a memo, clear sessions, remove a clip, etc.)

---

## 3. Permissions Soundr requests, and why

Soundr requests two Android permissions:

### Microphone (`RECORD_AUDIO`)

Used by the following features, all of which process audio **locally on your device**:

- **Decibel Meter** — measures sound levels in real time. Raw audio is analysed and discarded; only the resulting numeric dB values are stored, and only when you save a session.
- **Spectrum Analyser** — performs a real-time FFT on the microphone input. Audio is not stored.
- **Voice Memo** — records audio to a file in app-private storage when you tap record.
- **Hearing Check** — does not actually record; this permission is requested implicitly by the audio stack.
- **Morse Code** — does not actually record from the microphone; included for compatibility with future tapper features.

Audio is **never transmitted off the device**. Soundr has no network code that sends recordings or analysis results anywhere.

You can revoke this permission at any time in your phone's Settings → Apps → Soundr → Permissions. The microphone-using features will stop working, but the rest of the app continues to function.

### Notifications (`POST_NOTIFICATIONS`, Android 13+)

Used only to display the **playback notification** when a sound is playing, with quick-play and stop-all controls.

We do not send push notifications. The app does not have a push notification token, and we have no way to message you.

---

## 4. Third-party services

Soundr does not integrate any third-party services, SDKs, analytics platforms, advertising networks, or crash reporters inside the app.

Soundr is distributed via the **Google Play Store**. When you install Soundr from Play, Google may collect some information about the installation as part of operating the Play Store. This is governed by [Google's Privacy Policy](https://policies.google.com/privacy) and is outside our control.

---

## 5. Children's privacy

Soundr does not knowingly collect data from anyone, including children. The app is rated **Everyone** in the Play Store's content rating but is not specifically designed for children under 13. We do not direct the app at children, do not collect any data, and have no way to contact users.

---

## 6. Data security

Because Soundr does not transmit, collect, or store any data outside your device's app-private storage, there is no server, database, or cloud account that could be breached.

Data on your device is protected by Android's app sandbox: other apps cannot read Soundr's files. Device-level encryption (enabled by default on modern Android) provides additional protection if your device is lost or stolen.

---

## 7. Data retention and deletion

- **In-app deletion** — Voice memos, decibel sessions, and custom soundboard clips can each be deleted from within the app.
- **Full deletion** — Uninstalling Soundr removes all stored data automatically.

Because we hold no data on our servers (we have no servers), there is no separate account-deletion or data-export process. Uninstalling the app is the complete deletion.

---

## 8. Your rights

You have the right to:

- Use Soundr without providing any personal information
- Revoke any permission at any time via Android settings
- Delete any data stored by the app (either individually or by uninstalling)
- Contact us with privacy questions (see Section 10)

Since we collect no personal data, requests under GDPR / CCPA / similar regulations to access, correct, port, or delete personal data are not applicable — there is nothing for us to access or delete on our side.

---

## 9. Changes to this policy

We may update this Privacy Policy occasionally (for example, if a future Soundr update adds a feature that handles data differently). The "Last updated" date at the top of this document will reflect any changes. Material changes will be highlighted in the app's release notes on the Play Store.

This policy applies to the version of Soundr available on the Google Play Store. Older versions of the app you may have installed previously are governed by whatever policy was in effect when that version was published.

---

## 10. Contact

If you have any questions about this Privacy Policy or about Soundr's data practices, you can contact:

**Rahul Jose**
Email: `<YOUR_EMAIL_HERE>`

Please replace `<YOUR_EMAIL_HERE>` with a real contact address before publishing this policy.

---

*Soundr — soundboard and audio tools, with zero strings attached.*
