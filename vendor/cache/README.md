# Reviewed chats dependency

`chats-0.5.1.gem` was built with Ruby 3.2.2 from `rameerez/chats@6159ea1`
(tag `v0.5.1`, PR #15: the lookup seam, the missed-broadcast recovery), from a
clean worktree of the tag. SHA-256:

`006126ea4d8fcc832d6316077ae6dc282388ebf843d34c6ede1f6370cf59e3a1`

Bundler uses this standard cache for CI and local development until the exact
artifact is published. CI sets `BUNDLE_CACHE_PATH` explicitly so appraisal
Gemfiles share it. There is no path dependency or sibling-repository checkout.
The gemspec excludes `vendor/`, so this package is not embedded in support_desk.

support_desk requires chats `>= 0.5.1, < 1.0`, so this package is also the
floor the suite runs on. Publish chats 0.5.1 before support_desk 0.4.0, which
cannot resolve from rubygems without it. After publication, removing this
cache is optional.
