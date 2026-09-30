# Privacy Policy

**Effective date:** September 30, 2026

Sideline is a referee feedback assistant for youth soccer mentors. This policy explains what data we collect, how we use it, and your rights.

## Quick overview

- **Without an account:** Everything stays on your phone. We collect nothing.
- **With a mentor account:** Your evaluations are stored on our database so other approved mentors in your league can see referee profiles. Admins can delete records on request.
- **Minors:** Evaluations concern referees, some of whom may be minors. We treat this data as sensitive.

## Data we collect

### Without signing in

If you use Sideline without an account, we collect **nothing**. Your notes, ratings and saved evaluations stay on your device.

- The service worker caches the app shell and images for offline use.
- Your device stores everything locally using the browser's offline storage.
- Nothing is sent to us or any server.

### With a mentor account

When you sign in with Supabase, we collect:

- **Your email address** — only to identify your account and send sign-in codes. Supabase handles this; see [Supabase's privacy policy](https://supabase.com/privacy).
- **Your name** — to credit your evaluations and distinguish multiple mentors in the league.
- **Your saved evaluations** — referee name, date, ratings, notes, and comments. These are uploaded to our database.
- **Your activity** — when you sign in, upload, or delete evaluations.

We do **not** collect:
- Games or notes you are still working on (these stay local unless you save).
- Payment information (Sideline is free).
- Device identifiers, location, or contact list.
- Information about other people except through your evaluations.

### Admin console access

If you are an admin (league leadership), you can also:
- See all mentors' evaluations and activity.
- Approve or remove mentor accounts.
- Merge duplicate referee names.
- Delete a referee's records on request.

The admin console reads data fresh on each page load; nothing is stored in your browser.

## How we use your data

**Evaluations:** We store them in our database so other approved mentors in your league can see referee profiles—averages, trends, and notes. Only mentors and admins you approve can see them.

**Sign-in codes:** Supabase sends these by email and stores them temporarily (under 10 minutes by default) to verify your identity.

**Analytics:** We do not collect analytics, session identifiers, or tracking pixels.

## Who can see your data

| Account | Can see |
| --- | --- |
| You, not signed in | Your own local device data only. |
| You, signed in | Your own evaluations, and all other approved mentors' evaluations (referee profiles). |
| Other mentors | Your saved evaluations, credited by your name. |
| Admins | All evaluations, mentor activity, and import logs. |
| Public | Nothing. The app is not indexed or crawled. |

Evaluations are attributed by the name you enter in the app. Two mentors cannot share one account (a second mentor will be asked to add a middle initial to distinguish them).

## Data retention and deletion

- **Your evaluations:** We store them indefinitely until you or an admin deletes them. You can export a backup from the app anytime.
- **Sign-in codes:** Supabase deletes them after they expire (default 10 minutes) or are used.
- **Sign-in activity:** Supabase logs authentication events; see their privacy policy for retention.
- **Deletion requests:** If a referee (or their parent/guardian) asks to delete their records, an admin can delete all evaluations of that person from the database. New evaluations cannot recreate deleted ones. This does not delete local copies on mentors' phones or responses in the league's Google Form.
- **Account removal:** If a mentor is removed, their evaluations remain credited by the name they entered, but they can no longer access the app. Admins can still view or delete their contributions.

## Your rights

- **Access:** You can export your evaluations as JSON from the app anytime (Evaluations → Export recovery JSON).
- **Deletion:** You can delete any evaluation you created. Admins can delete evaluations on request.
- **Withdraw consent:** You can delete your account and sign out of all devices. Your evaluations remain until an admin deletes them.
- **Request a deletion:** Contact your league's admin or the app owner to delete a referee's records.

## Data security

- **In transit:** Supabase uses HTTPS and encryption. The app requires HTTPS; over plain HTTP, no service worker or clipboard access is available.
- **At rest:** Supabase encrypts your data on disk and enforces row-level security. The publishable API key is public by design; access rules protect your data.
- **Local storage:** The browser's offline storage is encrypted by your device.
- **Service worker:** The service worker caches the app shell and images, but never stores evaluation data outside the browser's normal offline storage.

We do not store passwords; Supabase handles authentication.

## Third parties

- **Supabase:** Hosts our database, authentication, and sign-in emails. [Supabase privacy policy](https://supabase.com/privacy).
- **Email provider:** Supabase's email provider (set by your league's admin—Resend, SendGrid, Postmark, etc.) sends sign-in codes. [Configure your provider's privacy policy.](https://supabase.com/docs/guides/auth/auth-smtp)
- **Google Sheets:** If your league uses a schedule sheet, the app reads it using the publicly shared link. Google's privacy policy applies.
- **GitHub:** If the database migrations are deployed via GitHub, GitHub has access to the repository. [GitHub privacy policy](https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement).

We do not sell, rent, or share your data with anyone except as above.

## Children's privacy

Evaluations are written assessments of referees, some of whom may be minors. We treat this data as sensitive and do not collect information about children except through your evaluations. If you believe a child's data is being misused, contact your league's admin immediately.

## Changes to this policy

We may update this policy from time to time. Changes take effect when posted. Your continued use of Sideline means you accept the updated policy.

## Questions or concerns?

Contact your league's admin or the app maintainer:
- **App:** sideline.codeoverload.dev
- **Repository:** github.com/CodeOverloader/sideline
- **Issues:** github.com/CodeOverloader/sideline/issues
