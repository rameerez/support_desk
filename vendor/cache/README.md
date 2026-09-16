# Reviewed chats dependency

`chats-0.3.2.gem` was built with Ruby 3.4.7 from `rameerez/chats@ebd1556`
(PR #5). SHA-256:

`e0db60f7722074cf959733e0e53631e8f9a3182abaa9efc592e639501b29a836`

Bundler uses this standard cache for CI and local development until the exact
artifact is published. CI sets `BUNDLE_CACHE_PATH` explicitly so appraisal
Gemfiles share it. There is no path dependency or sibling-repository checkout.
The gemspec excludes `vendor/`, so this package is not embedded in support_desk.

Publish this exact artifact after integrating chats PR #5; do not rebuild from
an unrelated working tree. After publication, removing this cache is optional.
Keep its provenance in sync if the dependency changes before release; after a
version is published, further source changes require a new version.
