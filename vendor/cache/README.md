# Reviewed chats dependency

`chats-0.7.1.gem` is the released package of `rameerez/chats@b752dbb` (tag
`v0.7.1`: 0.7.0's dock tray, `chats_tray`, `chats_tray_item` and
`:unread_changed` owned by the transaction, packaged without the README's
screenshots). Every one of its 99 files is byte-identical to the tag.
SHA-256:

`14c1aa9925469b3a6410b2107285bae9b87266794aef512c4d9e81f4a46da76e`

support_desk 0.5.0 requires chats `>= 0.7.1, < 1.0` (the tray its launcher
sits in, and the `:unread_changed` event its badge listens to), so this
package is also the floor the suite runs on. Bundler uses this standard cache
for CI and local development until the package is on rubygems; CI sets
`BUNDLE_CACHE_PATH` to it so appraisal Gemfiles share it, and asserts the
version it resolved (`CHATS_VERSION_UNDER_TEST` in .github/workflows/test.yml).
There is no path dependency or sibling checkout, and the gemspec excludes
`vendor/`, so the package is never embedded in support_desk.

chats-0.5.1.gem (0.4.0's floor) was removed with the move to `>= 0.7`.
Publish chats 0.7.1 before support_desk 0.5.0, which cannot resolve from
rubygems without it. After publication, removing this cache is optional.
