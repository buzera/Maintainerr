# feat(overlays): choose how far a show collection's overlay reaches

A show collection draws its countdown on every season poster and episode
title card that leaves with the show. On a large Plex library that is
thousands of uploads on every run, and as many writes to Plex's metadata
directory, when the show poster alone says the same thing.

- **Overlay scope** in the rule editor, under "Enable overlays", for a show
  rule with overlays on: Show only, Show + seasons, Show + seasons +
  episodes. The last is the default, and the generated migration gives it to
  every existing collection (new column `collection.overlayScope`, default
  `all`), so nothing changes until a scope is picked.
- The scope trims the inheritance walk, not the uploads it leads to: Show
  only reads no seasons or episodes, Show + seasons reads no episode lists.
  Membership, delete dates and the collection action are untouched. Season
  and episode collections keep drawing everything, since their own members
  sit below the show; `resolveOverlayScope` in contracts is the one place
  that decides this, for the form, the save path and the overlay run.
- Narrowing a scope needs no new restore path: what it leaves out is no
  longer a target, so the run's existing revert pass restores it from the
  saved original, skips anything another overlay collection still draws on,
  keeps backup and state when the upload fails, and holds everything while a
  hierarchy read fails.
- An update that omits the field keeps the saved scope, so an older client
  cannot widen a collection back to every episode.
