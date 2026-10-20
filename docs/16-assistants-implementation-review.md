# Adversarial implementation review — support_desk 0.3.0 / CarHey Rose

Reviewed 2026-09-19. **Do not enable Rose yet.** The implementation has substantive correctness gaps, including in the initial human-reviewed draft rollout. Passing the existing suite does not establish the concurrency and recovery guarantees advertised by the release.

This is a review, not a fix or release. Production, configuration, primary source checkouts, tags and published packages were not changed. Findings and executable probes are saved locally in this intentionally ignored docs directory; nothing has been posted or pushed.

## Scope and evidence

- support_desk main `108eefd`, reviewed and executed in detached `/tmp/support-desk-030-adversarial`.
- CarHey main `e7350301` (includes #342), reviewed and tested in detached `/tmp/carhey-rose-adversarial`. The reported deployed SHA/flag state was not independently queried in production.
- Chats main `1b9cd3d`, version 0.3.2. There is no transactional Chats write seam in this implementation. The revised v3 PRD deliberately chose reconciliation instead; that design was assessed on its behavior rather than rejected merely for differing from v2.
- CarHey resolves the installed support_desk 0.3.0 gem. All 101 files in the local `carhey/support_desk-0.3.0.gem` archive match the primary support_desk checkout byte for byte. This checks the local release artifact, not a fresh download from RubyGems.
- Existing gem non-browser suite: **1,133 runs / 6,214 assertions / 0 failures / 0 errors**. Coverage: 97.22% lines, 81.71% branches. Separately, the focused assistants subset had 252 passing tests; its coverage threshold failure was expected for a subset, not an application failure.
- New regression probes: **8 SQLite examples (7 assertion failures, 1 StaleTurn error)** and **2 PostgreSQL barrier-controlled examples (2 assertion failures)**. All ten expose the expected-behavior violations below. The PostgreSQL tests really commit requester messages on a second connection and suspend only the host after-commit notification.
- CarHey focused harness/integration/moderation/context tests: **42 runs / 210 assertions / 0 failures**. Job and support console tests: **29 runs / 190 assertions / 0 failures**. Stock madmin assistant-rendering test: **1 run / 12 assertions / 0 failures**. Total focused CarHey verification: **72 runs / 412 assertions / 0 failures**.
- No live provider calls, production jobs, deployments or browser staging exercises were performed. Model factual accuracy and the external provider contract are not certified by these unit tests.

## Findings

### R1 — P1: requester writes do not share the lock that protects autonomous sends and human draft approval

**Locations:** `lib/support_desk/models/ticket/assistance.rb:150` and `:383`; `lib/support_desk/models/draft.rb` (`send!`, reconciliation then turn comparison); Chats `Message` after-commit host notification.

Reconciliation is a SELECT followed by a write, while a requester can commit a new Chats message without acquiring the ticket lock. The SELECT cannot exclude a commit that happens immediately after it. The held ticket revision therefore still matches even though the conversation has changed.

The PostgreSQL probes force this exact schedule, using ordinary requester `message!`, and produce:

```
Original question → New question → Answer based on old question
Original question → New question → Proposed answer approved from old page
```

Both sends succeed. The second is directly relevant to CarHey's initial `:draft` rollout: `seen_turn` does not guarantee the human saw the latest committed requester message. The first can also let a reply slip past a newly committed request for a person, whose hand-off callback is waiting on the ticket lock.

**Fix:** establish one transaction/locking protocol for every relevant message write and ticket action. Requester message persistence and revision/hand-off registration must serialize with answer/approval/close. A second SELECT alone merely narrows the race. A small Chats transaction hook or another shared serialization seam can accomplish this without requiring a general workflow engine. Define lock order and retain these barrier tests for requester reply, assistant send, draft send and close.

### R2 — P1: a stale assistant instance can steal a human's case; assignment/release also omit the mandatory turn

**Locations:** `lib/support_desk/models/ticket.rb:894-911`, `ensure_assistant_may_assign!` at `:1342`, `release!` at `:973`.

`assign!` checks whether the ticket is unassigned and whether the assistant may hold it **before** `write_transition!` acquires/reloads the ticket. Under the lock it checks only closed/same-holder state and then opens the new assignment.

Reproduction needs no threads: load an unassigned ticket into A; assign the same row to a human through B; call `A.assign!(to: rose, by: rose)`. Rose replaces the human. The probe fails with “assistant stole the human seat using stale pre-lock checks.” The same placement also makes the target policy vulnerable to a topic/pause change before lock acquisition.

Additionally, `assign!` and `release!` expose no `turn:` argument. They therefore cannot uphold the documented rule that every assistant action requires and consumes the turn it observed. A late run can release a newer assignment to the same assistant.

**Fix:** move all mutable assignment eligibility checks under the ticket lock; add and check assistant turns for assignment/take/release, with an explicit internal path for automatic assignment during an already-authorized reply. Human calls retain their existing API. Test stale human takeover, topic/pause changes, old-run release, and omitted turn.

### R3 — P1: a lost registration callback leaves a permanently stale turn that redispatch never repairs

**Locations:** `lib/support_desk.rb:183-195`; `Assistance#respond!` and `reconcile_unregistered_messages!`.

When a requester message commits but the process dies before SupportDesk registration, reconciliation discovers it inside the candidate answer's savepoint and bumps the revision. `ensure_current_turn!` then raises StaleTurn, rolling the registration and its emitted events back. The committed message remains unregistered. Redispatch emits the original revision again; the same refusal repeats forever.

The probe suppresses only the original registration lookup, attempts a reply, then runs redispatch after ten minutes. The revision is unchanged. This is not hypothetical queue redelivery: it is the very after-commit loss the recovery API is expected to handle. If the old ticket clock says `awaiting_requester`, the idle query may not even select it.

**Fix:** preferably make message registration atomic with persistence (R1). If legacy/unregistered rows must still be repaired, reconcile in a durable repair transaction, commit that repair and enqueue the new turn independently of the refused answer. Recovery discovery must examine unregistered messages, not exclusively the clocks whose callbacks may have been lost. A dead process followed only by scheduled recovery must eventually produce an actionable current turn.

### R4 — P2: equal-timestamp requester messages make a current answer fail indefinitely

**Locations:** `lib/support_desk/models/ticket/assistance.rb:392-404`; `Ticket#registered?` at `lib/support_desk/models/ticket.rb:1629`.

The tie query selects every message at the current timestamp whose ID differs from the last requester ID. That includes already registered earlier messages. `registered?` accepts only the one stored ID at that instant as already registered. It re-registers an older tied message, bumps the revision and invalidates the current answer. The rollback restores the old pointer, so retrying repeats the problem.

The probe registers two requester messages at the same instant, reloads the current turn and attempts one answer. It raises StaleTurn. This is relevant to coarse timestamp columns, imports and frozen-time tests; even fine precision does not provide uniqueness.

**Fix:** use a stable complete ordering/registration watermark compatible with the supported ID types, or exact registration evidence. Do not use `id <> last_id` as an unseen-message test. Cover three equal-time messages, reordered delivery, replay, UUID IDs, answering after all have registered, and subsequent draft approval. Audit the separate requester-vs-agent clock tie policy as part of this correction.

### R5 — P2: the silent sweep escalates a case whose silence already ended

**Locations:** `lib/support_desk.rb:163-167`; `Assistance#flag_human_required!` at `:534`.

The sweep's assignee/awaiting/deadline predicates are evaluated when candidates are selected. After a concurrent answer or takeover, `escalate!(by: :system)` acquires the lock but rechecks only closed and already-human-required state. It does not check that the same assistant still owes an overdue reply.

A deterministic probe inserts a human answer after candidate selection and before escalation. The sweep nevertheless marks the answered case human-required, raises its priority and posts the handoff line. It can similarly disrupt a just-resumed case or a newly reset waiting deadline.

**Fix:** provide an atomic conditional silent-release transition. Under the lock, recheck assistant identity, open state, awaiting side, current deadline and current handoff state before any event/message/state mutation. Use a real barrier test; merely asserting the human keeps their seat misses the incorrect escalation and public line.

### R6 — P2: deactivation and removing configuration can leave assistant seats stranded indefinitely

**Locations:** `lib/support_desk/models/assistant.rb:102-112`; `lib/support_desk.rb:158-163`; `Doctor#assistant_invariant_checks` early return for no configuration.

`deactivate!` promises the sweep releases held cases. The sweep instead iterates only currently configured assistants, skips nil `responds_within`, and considers only overdue `awaiting_reply` cases. An inactive assistant with an unlimited timeout keeps the seat forever; this is reproduced. An assistant removed by the global flag is not visited at all, and the doctor skips assistant invariant checks when configuration is empty. A held case awaiting the requester is also outside the sweep.

CarHey configures a timeout, but its documented flag-off kill switch removes the configuration entirely. After autonomous use, that makes this the host's issue too. The initial draft-only rollout normally has no assistant-held seats.

**Fix:** separate invalid-assignee recovery from silence detection. Scan actual assistant-held rows independently of today's configuration and reclaim seats whose assistant is inactive, unconfigured or otherwise ineligible, without requiring a timeout or requester-waiting clock. Keep relevant historical-seat doctor checks active when the flag is off.

### R7 — P2: max-turn escalation does not emit the escalation event CarHey subscribes to

**Locations:** `lib/support_desk/models/ticket/assistance.rb:170-174` versus `escalate!` at `:229`; CarHey assistant notification subscriptions in `config/initializers/support_desk.rb`.

The budget-exhaustion branch invokes `flag_human_required!` directly. It creates an `:escalated` timeline event, releases the seat and writes the public handoff line, but only the outer `escalate!` method emits `:ticket_escalated`. CarHey's NeedsHuman notifier therefore never receives this handoff. A draft notification may still fire; that is not the promised escalation signal or its routing/severity.

The probe uses max_turns=1, sends one answer, receives another requester message, and calls respond! again. Outcome is drafted/max_turns and human_required is true, but the escalation subscriber count is zero.

**Fix:** centralize after-commit public event emission for every successful handoff, preserving kind/reason/from/by and suppressing it on no-ops. Test the host subscriber for budget exhaustion, explicit escalation, phrase handoff and sweep, including outer rollback and duplicate invocation.

### R8 — P2: disabling or renaming the assistant rewrites disclosure on old signed messages

**Locations:** `lib/support_desk/models/assistant.rb:75-90`; Chats `lib/chats.rb:192-199`; message provenance snapshots in `Assistance#assistant_message_metadata`.

Messages store a display-name/disclosure snapshot, but the requester-facing default signature resolves the live author name/configuration instead. Removing configuration changes an existing signature from “— Rose · virtual assistant” to “— Rose”; the probe verifies this exact change. Renaming/reconfiguring has the same historical rewriting problem. The snapshot is not wired into the stock Chats renderer, and CarHey has no signature override that fixes it.

**Fix:** render signed assistant messages from validated per-message disclosure/name evidence, with a safe legacy fallback. Preserve the original signed-vs-nameless presentation as well as AI provenance. Test the actual Chats/requester bubble and exports before/after rename, mode change and flag-off, not just metadata presence.

### R9 — P2: an already-held assistant can send after deactivation commits while it waits for the ticket lock

**Locations:** `Assistance#respond!` at `:147-154`; `Ticket.ensure_agent_record!` at `lib/support_desk/models/ticket.rb:344`; `AssistantPolicy.for` at `lib/support_desk/assistant_policy.rb:83`.

The fresh eligibility lookup happens before acquiring the ticket lock and does not refresh the actor passed to policy. Policy reads that cached actor's active flag. The probe starts with Rose already holding the ticket, commits deactivation between actor resolution and acquiring the ticket lock, then resumes the operation. The reply succeeds. An unassigned case can incidentally refuse when automatic assignment performs another eligibility check; that does not protect already-held cases.

**Fix:** revalidate runtime eligibility at the mutation boundary after waiting for the case lock. If the product promises deactivation serializes with all writes, it additionally needs a shared lock/version protocol for assistant activation, with documented ordering; another uncoordinated read alone cannot guarantee that no in-flight transition wins. Document any intentionally allowed in-flight window instead of claiming the switch stops every subsequent send.

## Host observations and limits

The provider/harness boundary, requester-scoped record tools, internal-context default, metadata namespacing, human draft authorship and moderation owner bridge are sensible seams. Their presence does not repair the gem-level race in the approval path.

Do not interpret the confidence/citation gate as a factuality guarantee. It checks that at least one returned source was cited and that the model declared enough confidence; it does not prove that the answer follows that source. CarHey tests make stronger claims in comments than their assertions establish. This is a rollout limitation, not a demand for a particular provider or a second model.

Likewise, topic caps protect the selected topic, not every financial/identity question typed into an `other` or `app` case. The global draft cap prevents autonomous answers today. Before raising it, retain the planned sensitive-case evaluation and handoff checks; the prompt alone cannot make the selected topic a trusted risk classification.

The scheduled tasks run on the job infrastructure. A worker-kill drill must show what happens while the sweep itself cannot run and on recovery, rather than assuming an in-process recurring sweep is an independent monitor. This review did not perform that operational drill.

## Reproduction and follow-up

Evidence and executable tests are in `docs/reviews/assistants-030/`. The original probes remain under the detached gem worktree's `test/` directory. They deliberately assert the intended guarantees and therefore fail against 0.3.0; no production implementation was patched to manufacture the failures.

SQLite probes:

```sh
cd /tmp/support-desk-030-adversarial
DATABASE_URL=sqlite3:/tmp/support-desk-adversarial.sqlite3 RBENV_VERSION=3.4.7 \
  /Users/javi/.rbenv/shims/bundle exec ruby -Itest test/adversarial_review_test.rb
```

PostgreSQL barriers (database created only for this review):

```sh
DATABASE_URL=postgresql:///support_desk_adversarial_20260919 RBENV_VERSION=3.4.7 \
  /Users/javi/.rbenv/shims/bundle exec ruby -Itest test/adversarial_concurrency_review_test.rb
```

The PostgreSQL probe file uses real commits and intentionally leaves its synthetic rows in this isolated review database. Do not run it against a shared/development/production database. The silent-sweep and kill-switch probes deterministically interpose changes at the race boundary; their implementation hooks are only test scaffolding.

Recommended fix order: shared message/turn serialization and durable repair (R1/R3), under-lock assignment plus turn coverage (R2), tie-safe registration (R4), conditional recovery/kill behavior (R5/R6/R9), centralized handoff events (R7), immutable requester-facing disclosure (R8). Keep the initial rollout flag off until the draft-approval and recovery failures are fixed. Re-run these regressions plus the existing suites, then perform the documented staging drill and disclosure decision. No claim of “100% ready” follows from this review or from a green suite.
