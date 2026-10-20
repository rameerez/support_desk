# 12 — Open questions (owner decisions)

1. **Stack behaviour default:** `:auto` (single open ticket opens the thread directly) vs `:always` (always the list). Recommendation: `:auto`.
2. **`reopen_on_reply` default:** `true` (write into a closed thread ⇒ reopen, no wall) vs `false` (locked composer + door, what #309 renders). Recommendation: `true`; agents see a `reopened` event and the queue treats it as new activity. Keep `false` available for regulated desks.
3. **Mount path for CarHey:** keep `/messages/support` or move to `/support`. Only affects the native rule and fixtures.
4. **Gem name:** `support_desk` (free on rubygems). Module `SupportDesk`. Alternative `supportdesk` reads worse in Ruby.
5. **Requester macro name:** `has_support_tickets` (chosen; describes what it adds) vs `acts_as_support_requester` (matches chats' `acts_as_*` but adds nothing to the sentence). Agent side keeps `acts_as_support_agent` because it is a role.
6. **Snooze in 0.1 or 0.2:** cheap to add early (one status, one column, one job). Recommendation: 0.2 unless CarHey agents ask for "waiting on user".
7. **UUID pinning:** follow chats' `primary_key_type` option (host decides) vs UUID-only. Recommendation: follow chats.
8. **Should chats own `via` (S9)?** Cosmetic; decide when the email channel lands.
9. **Internal notes as events vs a notes table:** events chosen (searchable timeline, no new table). Revisit only if notes need attachments.
10. **Bot may close tickets by default?** Recommendation: no (`bots_may_close = false`).
11. **License and repo visibility:** chats is private on GitHub but public on rubygems. Same for support_desk?
12. **Who writes chats 0.2.0:** the seams are small but touch the gem's core views and inbox query; the owner may want to author S4 (stacks) personally since it changes the inbox's public shape.

---

## Recorded decisions (settled during the 2026-09-16 conventions pass)

13. **MySQL uniqueness: not solved, deliberately.** MySQL has no partial
    unique index, so the two cardinality invariants ("one open case per
    thing", "one open assignment per case") are enforced by the database on
    PostgreSQL and SQLite and by the model plus `SupportDesk.doctor`
    everywhere else. The standard MySQL substitute exists: a stored generated
    column carrying the cardinality key while the case is open and NULL once
    it closes, with a plain unique index on it, because NULLs never collide.
    It was surveyed and NOT adopted for 0.1.0 — it is a schema change, MySQL
    is not in the test matrix (the suite is 4 red there, two of them
    `skip_unless_partial_indexes` failing by design rather than skipping),
    and it would need adapter-aware tests we chose not to write. Revisit only
    when a real MySQL host appears. The fallback is honest in the meantime:
    tickets keep a non-unique index on the same four columns so the
    find-then-create lookup stays indexed, assignments are covered by the
    leading column of an existing index, and `doctor` checks all three
    invariants the indexes would otherwise hold.

14. **Configurable table names: not adopted.** Only `wallets` does it, and
    only because `usage_credits` embeds it. Nothing embeds `support_desk`, so
    a prefix would make every model's table name dynamic and the migration
    unreadable for no caller.

15. **The migration lives in three places that must agree**: the generator
    template, the dummy app's copy, and the source-text assertions in
    `test/generators/install_generator_test.rb`. Two tests enforce the first
    two. Any template change touches all three — this is why an adapter fix
    is never a one-line change here.

## Writing first (settled as defaults during the 0.2.0 implementation)

These three came out of the review of carhey#326 (see 13). The
implementation took the recommended default for each; they are recorded
here so a later change is a decision rather than a discovery.

16. **Banned accounts.** `has_support_tickets if: :kept?` explicitly
    **permits** them, although `User#active_for_authentication?` refuses
    their login. Recommendation, and what CarHey takes: exclude them from
    in-app writes with a named predicate, `support_contactable? = kept? &&
    !banned?`, preserving readable history and leaving shadowbanned users
    eligible. If the owner wants banned users to receive in-app outreach
    anyway, record that choice and the lack of login access honestly. The
    email-channel work is separate; existing unread email does not make
    this an email reply channel. **Taken:** the recommended default. The gem
    itself has no opinion — it only honours the `if:` the host writes.

17. **`by: :system` in 0.2.0.** Recommendation: defer, ship persisted agent
    records first; CarHey uses its human User agents. It is not free: on an
    existing unassigned/take-over case the reply policy tries to assign a
    Symbol; unsigned desk messages expose the Desk as `reported_owner`,
    while CarHey's Moderate flags require a User. If accepted later,
    explicitly define and test system behaviour for every reply policy and
    assignment state, a symbol allowlist (`:system`, not any typo), unsigned
    moderation ownership/reporting, NULL provenance under rolling upgrades,
    test-helper handling, closed/ineligible recipients, audit actor identity
    and notification delivery. Do not bypass `reply!` to make it work.
    **Taken:** deferred. `Ticket.open!` rejects a Symbol opener with
    `NotAnAgent`, which is what makes NULL provenance unambiguously legacy
    and the backfill safe to run at any time.

18. **`awaiting_reply?` → `awaiting_desk?`.** A newcomer can read
    `awaiting_reply?` as "waiting for the requester to reply"; it means the
    opposite. Not in this release: it renames a queue tab key, the summary
    and CarHey's views. Recommendation: deprecation alias in 0.3.0.
    **Taken:** not renamed.

## Assistants (settled 2026-09-18, see 14)

19. **The persona is `SupportDesk::Assistant`**, a record the gem ships with
    the Desk pattern (row = identity, `config.assistant :rose` = behaviour).
    04's `Bot` sketch and its `responder_class` are superseded: the gem never
    owns the model loop. **Taken.**

20. **An approved draft is authored by the human who sent it.** The customer
    sees that person's signature; `metadata: { drafted_by:, draft_id:,
    edited: }` on the message keeps the provenance for transcript, metrics
    and the brief. **Taken** over "assistant + reviewed_by" and over an
    edits-dependent rule.

21. **A case the assistant closed that the requester reopens goes back
    unassigned with the assistant capped at `:draft`** on that case (a ticket
    override); `hand_off!(to: rose)` lifts the cap. **Taken** over letting her
    retake it (bounded by `max_turns`) and over paging humans immediately.

22. **Disclosure has no default.** `disclosure=` is required configuration
    on every assistant (`:signature_and_notice`, `:signature`, `:notice`,
    `:none`); omitting it is a boot failure, and `:none` is an explicit
    choice that warns nowhere. **Taken** over the recommended
    `:signature_and_notice` default with a warning on `:none`. The AI Act
    art. 50(1) reading in 14 §3 stands as guidance for hosts; counsel
    confirms in the legal repo.

Running on the recommended defaults: autonomy `:draft`, `max_turns` 6,
`responds_within` 3 minutes with a scheduled sweep, `may_open_conversations`
false, levels off/observe/draft/reply/resolve, `hand_off_when` as a gem-side
host block.

## Adversarial review refinements (2026-09-18, review-1 → v3)

The four decisions above stand. The implementation contract (15, v3) refines
their mechanics after the adversarial review (15-assistants-review-1.md;
disposition in 15-assistants-review-2.md):

- #19: any host `kind: :ai` model that is not the desk's `SupportDesk::Assistant`
  is refused for every support write (fail closed), never treated as a human.
- #20: unchanged; a human plain reply also supersedes the pending draft.
- #21: the reopen cap is keyed on the recorded closer (`closed_by`), stored in
  its own column (`assistant_cap`), and cleared only by an explicit hand-back.
- #22: unchanged.
- The turn is derived from a per-ticket revision bumped by every message and
  transition; every assistant action requires and consumes it.
- No `even_if_stale`: a human resubmits with the `seen_turn` they reviewed.
- `hand_off_when` fails closed (a raise or a non-boolean requires a person).
- Pause, case cap and human-required are three independent columns.
- No AI triage in 0.3.0. No chats change is required.
