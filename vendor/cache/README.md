# Reviewed chats dependency

support_desk 0.5.0 requires chats `>= 0.7.0, < 1.0` (the tray its launcher sits
in, and the `:unread_changed` event its badge listens to). This standard
Bundler cache holds the reviewed chats package CI resolves until that package
is on rubygems; CI sets `BUNDLE_CACHE_PATH` to it so appraisal Gemfiles share
it, and asserts the version it resolved (`CHATS_VERSION_UNDER_TEST` in
.github/workflows/test.yml). There is no path dependency or sibling checkout,
and the gemspec excludes `vendor/`, so the package is never embedded in
support_desk.

**Release step (pending):** once chats 0.7.0 is tagged (`v0.7.0`), build it from
a clean worktree of the tag and add it here, recording its commit and SHA-256:

```bash
git -C ../chats worktree add /tmp/chats-v070 v0.7.0
(cd /tmp/chats-v070 && gem build chats.gemspec)
cp /tmp/chats-v070/chats-0.7.0.gem vendor/cache/
shasum -a 256 vendor/cache/chats-0.7.0.gem
git add -f vendor/cache/chats-0.7.0.gem
```

chats-0.5.1.gem (the 0.4.0 floor) was removed with the move to `>= 0.7.0`: it
can no longer satisfy the constraint. Publish chats 0.7.0 before support_desk
0.5.0, which cannot resolve from rubygems without it. After publication,
removing this cache is optional.
