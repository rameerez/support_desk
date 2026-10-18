# Reviewed chats dependency

`chats-0.5.0.gem` was built with Ruby 3.2.2 from `rameerez/chats@285788e`
(tag `v0.5.0`, PR #11, the messaging dock), from a clean worktree of the tag.
SHA-256:

`41d960bd3810218db2dd43884977e4e5c0605a238b42f38074508c3e90fec39e`

Bundler uses this standard cache for CI and local development until the exact
artifact is published. CI sets `BUNDLE_CACHE_PATH` explicitly so appraisal
Gemfiles share it. There is no path dependency or sibling-repository checkout.
The gemspec excludes `vendor/`, so this package is not embedded in support_desk.

support_desk requires chats `>= 0.4.2, < 1.0`; the suite also runs against
0.4.2 (a per-version Gemfile pointing at that tag). Publish chats 0.4.2 and
0.5.0 before support_desk 0.4.0, which cannot resolve from rubygems until they
exist there. After publication, removing this cache is optional.
