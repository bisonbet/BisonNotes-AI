# User guide releases

Each app release has its own complete user guide on the website. The app
opens the guide for the version that's installed, and the default address
always shows the guide for the version that's currently on the App Store.

| File | Publishes to | App version |
| --- | --- | --- |
| [`bisonnotes-ai-v3-0.html`](bisonnotes-ai-v3-0.html) | `/bisonnotes-ai-v3-0/` | 3.0 |
| [`bisonnotes-ai-v2-5.html`](bisonnotes-ai-v2-5.html) | `/bisonnotes-ai-v2-5/` | 2.5 |

All addresses are under `https://www.bisonnetworking.com`.

## How the app links to the guide

`BisonNotesDocumentation.swift` builds the address from the app's
major and minor version, so 3.0 opens `/bisonnotes-ai-v3-0/`. A help button
that covers one topic adds that topic's anchor, such as `#bn-ai`. If the
version can't be read, the app opens `/bisonnotes-ai/`.

Anchors are the same in every guide (`bn-ai`, `bn-trim`, and so on), so a
link still lands on the right section after a redirect. Builds 2.3 to 2.5
shipped with versioned anchors (`bn23-ai`, `bn24-ai`, `bn25-ai`). Every guide
keeps those as empty `<span>` elements just before the AI section, so those
builds also land on the right section.

## Website setup

| Address | What it should be |
| --- | --- |
| `/bisonnotes-ai-v3-0/` | Page with the 3.0 guide |
| `/bisonnotes-ai-v2-5/` | Page with the 2.5 guide |
| `/bisonnotes-ai/` | **302** redirect to the current App Store version's page (`/bisonnotes-ai-v2-5/` until 3.0 ships) |
| `/bisonnotes-ai-v2-4/`, `/bisonnotes-ai-v2-3/`, `/bisonnotes-ai-v2-2/` | **302** redirect to `/bisonnotes-ai/` |

The redirects live in the Redirection plugin's **Redirections** group. Set
each one up like this:

- **302 (temporary).** Browsers cache a 301 for a long time, so after the
  target changes, people would keep landing on the old page.
- **Query parameters: Ignore.** With the default *Exact match*, a link with a
  query string (`?utm_source=…`) skips the redirect, and WordPress guesses the
  nearest slug instead, which sends `/bisonnotes-ai/` to the Privacy Policy
  page at `/bisonnotes-ai-2/`.
- **Nothing published at the source address.** A page at `/bisonnotes-ai/`
  would be served instead of the redirect.

Redirection watches for slug changes, and when a page's slug changes it adds a
**301** from the old address. Change that redirect to a 302 or delete it.

## Publishing a new release

Do steps 1–3 before the build goes to TestFlight, so testers get a working
Help link. Do step 4 when the release goes live on the App Store.

1. **Write the guide.** Copy the previous guide to
   `bisonnotes-ai-v<major>-<minor>.html`. Update the hero version, the "What's
   new" box, every changed section, and the "Guides for Other Versions" list.
   Keep every existing `bn-*` id and the legacy anchors. Add new ids for new
   sections and never rename old ones.
2. **Check the anchors.** `BisonNotesDocumentationTests` fails if the guide
   for the app's current version is missing, or if it lacks an anchor the app
   links to.
3. **Publish the page.** In WordPress, create a page with the slug
   `bisonnotes-ai-v<major>-<minor>`. Paste the whole file into a single
   **Custom HTML** block and publish it. Outside a block, WordPress adds
   `<p>` and `<br>` tags all through the page.
4. **Point the default at it.** When the release is live on the App Store,
   change the target of the `/bisonnotes-ai/` redirect to the new page. Add the
   new version to "Guides for Other Versions" in the previous guide too.

A patch release (for example 3.0.1) uses its minor version's page, so update
that page in place.

## Rules

- **Never rename a published version page or leave its address broken.**
  Installed builds keep opening it for as long as they're installed. Fixing its
  content is fine.
- **Retire a version with a redirect, not a 404.** When a version is too old
  to maintain, replace its page with a 302 redirect to `/bisonnotes-ai/`.
- **Every guide is complete.** A guide covers the whole app as it was in that
  release, not just what changed, so the default page is always a full guide.
