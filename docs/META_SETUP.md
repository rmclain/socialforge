# Posting to Facebook, Instagram, and Threads

SocialForge posts to your Facebook Pages, your Instagram professional accounts, and
your Threads profile from this Mac, with **your own Meta apps**. Nothing goes through
a SocialForge server. App ids and secrets, account tokens, and storage keys stay in
your Keychain.

**Status:** built from Meta's documentation (Graph API v25.0, Threads API v1.0) and
covered by tests against recorded request shapes. It has **not yet been verified with
a live post**. The first real post on each platform is the test; the Activity log shows
the exact error if Meta refuses something.

## What posts how

| Post | Uploads from this Mac | Needs public media storage |
|---|---|---|
| Facebook Page: text, photo, Reel | Yes | No |
| Instagram Reel (a video asset) | Yes (resumable upload) | No |
| Instagram photo | No: Meta fetches it from a URL | **Yes** |
| Threads text | Nothing to upload | No |
| Threads photo or video | No: Meta fetches it from a URL | **Yes** |

Public media storage is an S3-compatible bucket you own, such as Cloudflare R2 (see the
end of this guide). Files go in a random folder and are deleted once the post is out.

## 1. Before you start

- **Instagram must be a professional account** (Business or Creator) and **linked to a
  Facebook Page** you manage. In the Instagram app: Settings › Account type and tools ›
  Switch to professional account; then link it to the Page (Instagram: Settings ›
  Accounts Center, or the Page's settings › Linked accounts). Personal Instagram
  accounts can't be posted to by any app.
- **Facebook** posting is to **Pages** only, not personal profiles.
- Your Mac posts while it is awake (SocialForge open, or "Publish while SocialForge is
  closed" on). Due posts go out when it wakes.

## 2. Create the Meta app (Facebook and Instagram)

1. Go to <https://developers.facebook.com/apps>, sign in with the Facebook account that
   manages your Page, and choose **Create app**.
2. Pick the use cases for managing a Page and for Instagram content (the dashboard names
   them along the lines of *Manage everything on your Page* and *Manage messaging and
   content on Instagram*). If asked for an app type, choose **Business**.
3. Add these permissions to the use cases (each use case has a *Permissions* or
   *Customize* screen):
   `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`,
   `instagram_basic`, `instagram_content_publish`, and `business_management`.
4. Add the **Facebook Login** (or **Facebook Login for Business**) product, open its
   **Settings**, and:
   - Add `https://www.facebook.com/connect/login_success.html` to **Valid OAuth Redirect
     URIs**. This is Meta's own page for desktop apps; after you allow access, you copy
     the address it shows and paste it into SocialForge.
   - If your app uses **Facebook Login for Business**, create a **Configuration** with the
     permissions above and copy its **Configuration ID** into SocialForge's *Login
     configuration ID* field. SocialForge then asks for that configuration instead of a
     list of permissions.
5. **Leave the app in Development mode.** Development mode lets the app's admins,
   developers, and testers use it with every permission, without Meta's App Review.
   That is exactly your case. (Publishing the app for other people would need App
   Review and Business Verification.) If someone else should connect, add them under
   **App roles › Roles**.
6. In **App settings › Basic**, copy the **App ID** and **App secret**.

### A redirect to this Mac instead (optional)

If your app type accepts `http://localhost` redirect URIs in Development mode (Meta says
localhost is allowed in Development mode for consumer-type apps; Business apps may
refuse it), you can register `http://127.0.0.1:8085/meta/callback` and put that address
in SocialForge's *Redirect URI* field. SocialForge then catches the answer itself, with no
pasting. If Meta rejects the redirect, use the `login_success.html` address above.

## 3. Connect in SocialForge

1. **Settings › Publishing**, with *This Mac* chosen: under **Your Meta app**, enter the
   App ID and secret (and the configuration ID if you have one) and press **Connect
   Facebook & Instagram**.
2. Your browser opens Facebook. Allow access, and **choose every Page** (and Instagram
   account) SocialForge should post to.
3. The browser lands on a mostly blank Facebook page. **Copy the whole address** from the
   address bar, paste it into **Finish connecting Facebook**, and press **Finish**.
4. Each Page appears in **Accounts** as a Facebook account, and each linked Instagram
   professional account as an Instagram account.

Tokens: Page tokens made this way don't expire. The Instagram token lasts about 60
days; connect again before then (Accounts shows the date).

## 4. Threads

Threads apps have their **own** app ID and secret.

1. In your Meta app (or a new one), add the **Threads** use case (*Access the Threads API*)
   with the permissions `threads_basic` and `threads_content_publish`.
2. In the Threads use case's settings, find the **Threads app ID** and **Threads app
   secret**, and add a **Redirect Callback URL**. Threads accepts **https** addresses only
   and rejects localhost. SocialForge suggests `https://rmclain.github.io/socialforge/`
   (the SocialForge site); any https page works, because you paste the address back and
   the page itself does nothing with the code.
3. Add your Threads account as a **Threads tester** (App roles › Roles › Threads testers)
   and accept the invitation in the Threads app (Settings › Account › Website
   permissions › Invites).
4. In SocialForge, **Your Threads app**: enter the Threads app ID and secret, the same
   redirect URI, and press **Connect Threads**. Allow access, then paste the address the
   browser lands on and press **Finish**.

Threads tokens last 60 days; SocialForge refreshes them in their last ten days whenever
it refreshes accounts.

## 5. Public media storage (Cloudflare R2 example)

Needed only for Instagram photos and Threads photos and videos.

1. In the Cloudflare dashboard: **R2 › Create bucket** (for example `socialforge-media`).
2. In the bucket's **Settings › Public access**, turn on the **r2.dev subdomain** (or
   connect a custom domain). Copy the public address, such as
   `https://pub-1234abcd.r2.dev`.
3. **R2 › Manage API tokens › Create API token** with *Object Read & Write* on that bucket.
   Copy the **Access Key ID**, **Secret Access Key**, and the **S3 endpoint**
   (`https://<account id>.r2.cloudflarestorage.com`).
4. In SocialForge, **Public media storage**: endpoint, bucket, region `auto`, the public
   URL, and both keys. Press **Test Upload**: it uploads a small file, reads it back from
   the public address, and deletes it.

Any S3-compatible service works (AWS S3 with a public-read bucket policy, MinIO behind
https, and so on): use its endpoint and region.

## Limits worth knowing

- Instagram allows a limited number of API posts per account per 24 hours; when it's
  reached, SocialForge retries later. Reels: MP4 or MOV, 3 seconds to 15 minutes
  (Meta's reference), 9:16 recommended. Photos: JPEG, at most 8 MB.
- Facebook Reels: Meta limits Pages to 30 API-published Reels per 24 hours.
- Threads: 500 characters of text; images and videos must be at a public URL.
- If a post's request times out after it may have reached Meta, SocialForge looks for a
  post with the same text made since the first attempt before trying again, so a timeout
  doesn't become a double post.

## Sources

- [Instagram content publishing](https://developers.facebook.com/docs/instagram-platform/content-publishing/)
- [Instagram resumable uploads](https://developers.facebook.com/documentation/instagram-platform/content-publishing/resumable-uploads)
- [IG container reference](https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-container)
- [Facebook Reels Publishing API](https://developers.facebook.com/docs/video-api/guides/reels-publishing)
- [Threads posts](https://developers.facebook.com/docs/threads/posts/)
- [Threads access tokens](https://developers.facebook.com/docs/threads/get-started/get-access-tokens-and-permissions)
- [Threads long-lived tokens](https://developers.facebook.com/docs/threads/get-started/long-lived-tokens/)
