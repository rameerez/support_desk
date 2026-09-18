# Adversarial review — assistants PRD

*2026-09-18. Reviewed original docs commit d9ff5c55005ce397a24ee6342f78f4d7c5aba5bc
against support_desk main 4da67ed and the local Chats/CarHey source checkouts.
Changes are documentation only on docs/assistants-prd, isolated worktree
/tmp/support_desk-assistants-prd. No application/gem implementation, public
push, release, model call or deployment is part of this review.*

## Verdict

The original PRD was not safe to implement literally. It had concrete policy
and runtime bugs, unsupported concurrency/liveness claims, migration hazards,
and conflicts between its algorithms, signatures, tests and examples.
The revised [contract](15-assistants-prd.md) replaces those sections directly;
[14](14-assistants.md), [12](12-open-questions.md) and the index agree with it.
Original detail remains available at d9ff5c5, not interleaved as competing rules.

The four recorded owner choices remain: built-in Assistant identity,
human-authored approved replies, draft cap after AI closure/reopen, required
explicit disclosure with none allowed silently. Review refinements are
explicitly distinguished from owner decisions. CarHey disclosure/activation
remain host choices; nothing has been enabled.

## Findings and corrections

P0 means an intended authority or publication guarantee could be bypassed.
P1 means lost/incorrect work, concurrency/lifecycle/migration failure or a
blocking implementation contradiction. P2 covers misleading DX, rendering,
examples and operational claims. IDs are review identifiers, not issue numbers.

| ID | Severity | Original location / finding | Correction in revised 15 |
|---|---|---|---|
| R01 | P1 | §5.1 `level, rule = ceilings.min_by` reverses Ruby's key/value pair, so `level` becomes e.g. :topic and `RANK[level]` nil. | Explicit constants/decision contract; explanatory min_by warning; executable Ruby probe confirmed. |
| R02 | P0 | §5.2 ensure_current_turn!(nil) bypasses freshness; reply! signature omits turn entirely while prose says it accepts it. | Mandatory automation envelope on all AI mutations; no nil bypass, exact keyword obligations. |
| R03 | P0 | Message-ID token changes only for requester messages. Human takeover/release, pause/resume, policy/context edits can restore a state that accepts an old answer. | Monotonic input/control revision, policy/activation/context binding and fenced claims; cannot refresh across another actor's mutation. |
| R04 | P0 | §5.2 after-commit message registration leaves a committed requester message unseen by a concurrently committing answer. | Shared transactional Chats subject wrapper; input registration/work in same transaction; actual lock-order/race prototype required. |
| R05 | P1 | Existing registered? skips distinct messages at equal timestamps; original tests never cover that token omission. | Managed identity/sequence receipts; frozen-time UUID, edit/delete and old-callback replay tests. |
| R06 | P1 | respond! can avoid double replies through awaiting, but duplicate draft/note/escalation jobs create repeated effects or replace review work. | Durable operation receipts and payload fingerprints; same-key result replay, explicit mismatched-payload conflict. |
| R07 | P1 | §5.4 “MySQL belt” rescues a uniqueness exception on an adapter without that index; on PG queries after violation can run in aborted transaction. | Parent-row serialization + adapter indexes; whole-savepoint rollback/retry; no catch-and-return unrelated draft. |
| R08 | P0 | Hardcoded is_a?(Assistant) gives custom kind: :ai records human authority and approval rights; only doctor warns. | AI-kind classification; explicit host identity binding or refusal for every operation. |
| R09 | P0 | Supplied assistant not checked against actual desk in policy despite edge-case row promising refusal. | Persisted principal/desk binding verified before work and new effects. |
| R10 | P0 | observe can change topic/subject; child topic cap overrides parent; AI can move money case into permissive topic. | Triage separate opt-in; ancestor minimum; persistent restrictive case cap + host target authorization. |
| R11 | P0 | Model methods lack host tenant/action authorization; actions_for does not protect jobs or background draft approval. | Shared authorize_support read/write/resource hook in domain, composed with existing console policy. |
| R12 | P0 | Direct desk.message! / conversation.messages.create! bypasses ticket AI gates; two proposed Chats seams do not address it. | Generic transactional subject write gate and trusted internal gateway context; explicit unsupported raw-SQL boundary. |
| R13 | P0 | §5.13 outreach checks only global autonomy/allow flag, not actual topic/subject/holder/reuse policy; bypasses counters and turn controls. | Contextual collection + target policy, insert/reuse recheck, outreach receipts, consistent counters/presentation. |
| R14 | P0 | reply! bypasses respond!'s max_turns; close! has no current-turn/holder/unanswered-input gate; reopen! has no AI prohibition. | One gateway, conditional closure with successor token, all-verb matrix and AI reopen refusal. |
| R15 | P1 | §5.8 target policy refuses paused/human-required hand-back before flags can clear; code later clears all flags including unrelated caps. | Validate hypothetical resulting state, explicit independent resolutions, atomic hand-back with no wildcard clearing. |
| R16 | P1 | One assistant_autonomy column conflates pause and reopen cap; resume clears both; one human flag loses later distinct reasons. | Separate pause/reopen/case caps and keyed HumanRequirement rows with independent resolution. |
| R17 | P1 | §5.9 detects last holder instead of actual AI closer; reopening can raise an observe cap to draft. | Persist closer kind; cap by minimum; retain stricter restrictions and lifetime counters. |
| R18 | P1 | §5.11 query/lock race can release human takeover or already-answered case; release! only checks assigned and status. | Recheck work/claim/deadline/assignment identity under lock; count committed transitions only. |
| R19 | P1 | Timeout watches only assistant-held cases. At draft level or before first successful send there is no AI seat; dead harness invisible. | Durable work age from registration, including unassigned/draft-only opportunities. |
| R20 | P1 | Releasing a silent AI without fencing/restriction lets delayed job take it back; inactive agents with nil timeout aren't swept. | Recovery imposes human requirement, revokes work, handles invalid identities independent of timeout. |
| R21 | P1 | Post-commit callback errors are swallowed; no durable enqueue/replay contract despite promised reliable turn/job behavior. | Transactional work rows + optional callback/polling/redispatch; explicitly at-least-once, no provider runtime. |
| R22 | P1 | Draft send approves mutable content without exact revision; stale form auto-sets even_if_stale, allowing unseen further messages. | Immutable revisions; reviewed context token; compare again at send; no boolean bypass. |
| R23 | P1 | Draft send/reject retries raise instead of returning their completed result; pending-only controller lookup prevents replay. | Review/publication receipts; scoped all-status lookup; immutable decision history. |
| R24 | P1 | stale? computed after status=sent reports false in audit; blank edited body falls back to original; old draft stays offered after human reply. | Pre-mutation evidence, explicit blank validation, plain human reply supersedes/revokes proposal. |
| R25 | P1 | respond!(files:) may choose draft but files are discarded; attachment-only response fails unrelated body requirement. | Draft attachment support in revision/review; file authorization/checksum/validation and failure atomicity. |
| R26 | P1 | No separate approve/publish, durable edits, regeneration or exact-review contract despite broad human-in-loop scope. | approve!, publish!, revise!, atomic send!, explicit request_assistant_work! and server-bound human reviewer. |
| R27 | P1 | request_human! reopens before checking write eligibility outside whole-operation savepoint; acknowledgement after transition can fail independently. | One locked operation; requirement survives optional copy failure; author/requester fresh checks. |
| R28 | P1 | hand_off_when exceptions become false; !! coerces arbitrary values; failure silently allows autonomous continuation. | Strict boolean/nil; preserve requester message, record failure and require human intervention. |
| R29 | P1 | Door tied to may_draft? disappears at observe/paused/inactive/removed config; shipped Chats thread integration left to host. | Historical participation/actionable-request predicate + pending status + shipped composable thread slot. |
| R30 | P1 | Proposed Ticket#role_of human/assistant extension conflicts with existing registration branch expecting :agent. | Preserve lifecycle roles; independent transcript serializer roles. |
| R31 | P1 | AI eligibility default does not include active?; memoized assistant configuration can become stale; removed config breaks historical readers. | Fresh binding/control state, persisted fallback identity and immutable publication presentation. |
| R32 | P2 | Live signature veto retroactively changes old messages; requester rows/robot marks leak identity despite unsigned modes; one notice flag covers all personas. | Message-aware snapshot rendering on every surface; per-identity/disclosure-version notice receipts. |
| R33 | P1 | §6 uses current PK helper for existing ticket/message/actor FKs; sources gets object JSON default; adopts existing partial schema then drops it. | Referenced-column type inspection, array/object defaults, ownership preflight and real adapter upgrade tests. |
| R34 | P1 | Backfill fills only NULL although old writers leave non-null pointers stale; unconditional rolling-safe/downgrade claim ignores new identity/control semantics. | Disabled expansion only, drain all writers, full catch-up/activation epoch, tested compatible code rollback retaining schema. |
| R35 | P1 | Brief sends all internal notes/drafts/support_context, unbounded, without read authorization; generator falsely calls this redaction. | Authorized bounded consistent context, private fields opt-in, explicit host fact allowlist and schema/version. |
| R36 | P2 | Source URLs/metadata unvalidated; reserved provenance can be spoofed; imperative-sentence grep claimed to prevent instruction leakage. | Safe URL/schema/size limits, reserved namespace, untrusted content separation and appropriate tests. |
| R37 | P2 | Immutable evidence/export design relies on mutable/deleted actors and broad event visibility; future raw escalation summaries risk leakage. | Snapshots, restrictive references and positive public export mapping; staff details explicitly private. |
| R38 | P1 | §4.1 assistant getter/declaration/default delegation ambiguous; nil falls back instead of disabling desk. | Separate default_assistant setting, exact lookup, explicit nil disable, no implicit binding across every desk. |
| R39 | P2 | Generator overwrites shared job for each persona, appends initializer/YAML blindly, writes invalid required nil and unkeyed subscriptions. | Name-specific non-destructive templates, validate before writes, keyed module subscription; existing config.on forwarding limit documented. |
| R40 | P2 | Bare numeric actor fallback excludes existing UUID IDs; mixed User#1/Assistant#1 collision under new pool. | Existing actor_key from authorized pool; UUID/numeric unambiguous legacy fallback only. |
| R41 | P2 | No-assistant “zero query/column/tab change” conflicts with new state and always-present needs_human tab. | Honest opt-in semantic compatibility with explicit schema/AI-kind/picker changes and conditional tabs. |
| R42 | P1 | CarHey global draft ceiling prevents topic reply promotion; generic business-repo retrieval has no publication boundary; speculative model/method names. | Explicit global promotion plus all other caps; published help only; verify host readers and choose provider/model in host. |
| R43 | P2 | Acceptance/containment counts, self-confidence thresholds and fixed fortnight/80% promise imply more evidence than they provide. | Cohort/window/zero-denominator definitions; acceptance != accuracy; host evaluation and separate human-wait metrics. |
| R44 | P2 | Audit callbacks described as full durable audit; reported-owner nil assumed usable; timeout/queue retries overpromised. | Durable source evidence vs delivery distinction, actual host moderation contract test, scheduler latency and explicit retry configuration. |
| R45 | P1 | No work on resume/hand-back until customer writes again; no-action or internal notes can strand work or start loops. | Fresh explicitly triggered opportunities; own-command successor state; no note->work loop; no-action cannot silently consume unattended inbound work. |
| R46 | P1 | New permission/checkpoint design must not invalidate its own approval or send midway through nested assignment/notice callbacks. | Own-command atomic successor bookkeeping; approval audit alone does not mutate reviewed input revision; callbacks after commit. |

R45–R46 also cover traps found while validating the replacement design. They
are included so the implementer tests the revised design, not just the old bugs.

## Source checks and concrete reproduction

Local source examined:

- [Ticket](../lib/support_desk/models/ticket.rb): reply/assignment/close/reopen,
  actions_for, authorization eligibility, clock registration, role_of,
  registered?, export and message posting helpers.
- [Events](../lib/support_desk/events.rb): subscriber isolation,
  after_all_transactions_commit, keyed registration and callback signatures.
- [Configuration](../lib/support_desk/configuration.rb): delegation/defaults,
  existing config.on and validation timing.
- [Macro](../lib/support_desk/macros.rb) and
  [Agent](../lib/support_desk/models/concerns/agent.rb): AI label, role eligibility,
  agent sugar and configurable host model contract.
- [Assignment](../lib/support_desk/models/assignment.rb),
  [migration](../lib/generators/support_desk/templates/add_opened_by_to_support_desk_tickets.rb.erb),
  [engine](../lib/support_desk/engine.rb),
  [gemspec](../support_desk.gemspec): lock expectations, type/ownership
  precedent, load order and docs exclusion from package.
- Chats local lib/chats/models/message.rb, messaging concern and lib/chats.rb:
  after_create_commit notify_host, message! create path, mutable-author
  signature lookup, report owner, lock/attachment validations.
- CarHey current support initializer, User support declarations and Ai::Client:
  actual host topic/config/client timeout boundaries; no live provider or
  production query was performed.

The policy destructuring bug was reproduced with Ruby 3.4.7:

```ruby
ranks = { off: 0, observe: 1, draft: 2, reply: 3, resolve: 4 }
ceilings = { assistant: :reply, topic: :draft }
level, rule = ceilings.min_by { |_, value| ranks.fetch(value) }
p [level, rule, ranks[level]] # => [:topic, :draft, nil]
rule, level = ceilings.min_by { |_, value| ranks.fetch(value) }
p [level, rule, ranks[level]] # => [:draft, :topic, 2]
```

Two potential findings were **discarded after source verification**:
Configuration#on exists (it delegates without key: forwarding), and
Ticket.closed_between exists. The original use of those names was not itself
a bug. The revised PRD uses the keyed module form and corrects metric meaning,
not those existing API names. No inaccurate finding was left in the contract.

## Scope changes and why

The review deliberately broadens several primitives: draft revisions/files,
separate approval/publication, multiple independent human requirements,
policy-bound custom identities, durable work/claims/receipts, context access
hooks and a real transactional Chats boundary. These are necessary to fulfill
the requested downstream ergonomics and stated guarantees. They are not a
provider integration or an agent framework; the gem never runs a model.

One current proposal and one autonomous responder per desk remain explicit
initial product limits. General saved human drafts, multi-responder routing,
streaming, provider adapters, business tool execution and evaluations remain
out of scope. The revised plan replaces brittle pseudocode with ordered
transaction algorithms and a tested schema contract; final callback/DDL code
must be validated against actual adapters, not copied from an unexecuted sketch.

## Verification and limitations

Documentation validation checks local links, balanced code fences, section
number coverage, scenario/invariant coverage, Ruby syntax for runnable examples,
YAML syntax for locale examples and git whitespace. Pure-Ruby reproduction
confirms R01. These checks are recorded with the final review commit.

No runtime suite was run for the proposed APIs, because they do not exist yet.
The revised contract explicitly requires live adapter concurrency, migration,
UI, authorization and recovery tests before release. In particular the generic
Chats subject wrapper needs an integration prototype proving callback order
and lock behavior. This review fixes the written contract; it cannot certify
that a future implementation is “100% correct.”

Final documentation checks passed:

- Five edited/added documents; 23 local file links resolve.
- 12 fenced blocks balanced; all nine Ruby blocks parse with Ruby 3.4.7
  Ripper; the locale YAML parses with safe_load.
- Sections 0–18 present in order; every numeric § reference in the PRD resolves.
- 18 invariants, 40 scenario rows and 46 finding IDs present without gaps.
- git diff --check reports no whitespace errors.

The generated job/config snippets were syntax-checked, not executed against
future APIs. Implementation CI must execute them against stub host services.
