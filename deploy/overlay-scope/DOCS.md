# Overlay scope (docs section for docs.maintainerr.info/overlays)

Proposed text for the Overlays page of the documentation site, which lives in
its own repository.

---

## Overlay scope

When a show collection deletes on a schedule, everything under each show
leaves with it, so by default Maintainerr draws the countdown on the show's
poster, every season poster and every episode title card. **Overlay scope**
chooses how far down that goes, per collection.

| Overlay scope                       | Show poster | Season posters | Episode title cards |
| ----------------------------------- | ----------- | -------------- | ------------------- |
| Show only                           | Yes         | No             | No                  |
| Show + seasons                      | Yes         | Yes            | No                  |
| Show + seasons + episodes (default) | Yes         | Yes            | Yes                 |

The setting is in the rule editor, under **Enable overlays**. It appears for
rules with the media type **Shows** once overlays are enabled.

### Why choose Show only

Every overlay is an image upload to your media server, repeated whenever the
countdown changes. A show with ten seasons and two hundred episodes is two
hundred and eleven uploads a day at the default scope, and one with Show
only. On a large library that is the difference between thousands of
metadata writes per run and a handful, and the run finishes much sooner,
since Maintainerr no longer reads the seasons and episodes at all.

### Changing the scope of a collection with overlays

Nothing changes when you save. On the next Overlay Handler run:

- Narrowing the scope restores the original artwork of the seasons or
  episodes it no longer covers, from the originals Maintainerr saved when it
  first drew on them. The show poster keeps its overlay. Each saved original
  is deleted only after its restore succeeded.
- If a restore fails, for example because the media server is unreachable,
  the saved original and the overlay record are kept and the next run tries
  again.
- An item another overlay collection still draws on keeps that collection's
  overlay.
- Widening the scope draws the overlays again.
- Turning overlays off for the collection restores everything it drew, as
  before.

### Limitations

- Only show collections have the setting. Season and episode collections
  always draw everything that leaves with them, because their own members sit
  below the show.
- The scope only covers artwork that is drawn because it leaves with a show.
  An item that is itself a member of an overlay collection always gets that
  collection's overlay.
- Restoring a large collection takes as long as drawing it did, since each
  restore is an upload. Plex keeps the restored original as an uploaded
  poster.
- While Maintainerr cannot read a show's seasons, it keeps every overlay of
  that collection, including episodes the scope no longer covers, and
  restores them on the next run that can read them.
- Restores happen in the scheduled or manual Overlay Handler run, not when a
  single collection is processed on its own.
