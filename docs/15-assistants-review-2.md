# Review of the adversarial review — disposition of R01–R46

*2026-09-18. v2 (e9adfa7) found real bugs in v1 and then rebuilt the contract
as a distributed-systems spec. v3 keeps the bugs fixed and the gem small.
Legend: **adopt** = fixed as v2 proposed · **adapt** = fixed with a lighter
mechanism · **reject** = not in 0.3.0, with the reason.*

The one mechanism that replaces most of v2's machinery: **a monotonic
`assistant_revision` bumped by every registered message and every
transition, exposed as the opaque `assistant_turn`, required and consumed by
every assistant action**. It fences late answers (R02/R03), makes a retried
job a no-op (R06), invalidates drafts and approvals on any change (R22/R24),
and is one integer column. Under the existing ticket row lock it is as
strong as claims + receipts for a single-desk, single-assistant gem.

| ID | verdict | how v3 handles it |
|---|---|---|
| R01 | adopt | `rule, level = ceilings.min_by { |_r, l| RANK.fetch(l) }` — key first; a policy table test covers every ceiling. |
| R02 | adopt | `turn:` is required for every AI actor on every verb (`ArgumentError` when nil); no nil bypass. `reply!` / `close!` / `note!` / `escalate!` take `turn:`. |
| R03 | adapt | The turn derives from `assistant_revision`, bumped by every transition (assignment, pause, escalate, topic, reopen, close) and every message — not only requester messages. |
| R04 | adapt | `reconcile_unregistered_messages!` folds any committed-but-unregistered requester message in under the lock before the turn check, so it makes the turn stale. No transactional chats wrapper. |
| R05 | adopt | `registered?` tightened: equal timestamps register unless the id is the same-role last id. Test with frozen time. |
| R06 | adapt | Every assistant action consumes the turn ⇒ a duplicate/retried job hits `StaleTurn`. No receipts / idempotency keys. |
| R07 | adopt | No `rescue RecordNotUnique`; supersede-then-create under the row lock; MySQL relies on the model rule + `doctor` (12 #13 stance). |
| R08 | adopt | `kind:` validated; any AI-kind actor that is not the desk's `SupportDesk::Assistant` is refused on every write (`NotAnAssistant`), including approvals and targets. Documented behaviour change. |
| R09 | adopt | `AssistantPolicy.for` returns Null for an assistant that is not `ticket.assistant`; `resolve_assistant!` refuses. |
| R10 | adopt | No AI triage in 0.3 (`change_topic!` / `attach_subject!` refused); topic caps are ancestor-minimums; a reopen cap and a human refile that lowers the level release her seat. |
| R11 | reject | A domain-level host authorization hook is new surface the gem has never had for humans either; the harness selects which tickets it runs and the console keeps `authorize_console`. Revisit with multi-tenant hosts. |
| R12 | reject | Preventing a host from calling `desk.message!(author: rose)` needs a chats interception layer; misuse of a lower-level API by the host is documented as unsupported, not sandboxed. |
| R13 | adopt | Outreach checks `may_open_conversations`, autonomy, topic cap and `cap` block on the resolved topic before insert; a reuse turns into a full-rules reply. |
| R14 | adopt | Budget on `reply!` and outreach; `close!` needs held + `awaiting_requester?` + no human required + current turn; `reopen!` by AI refused. |
| R15 | adopt | `ensure_assignable!` evaluates `hand_back: true` (ignores pause/case cap/human_required/holder; keeps autonomy/topic/cap/inactive/closed); the clears happen inside the same transition. |
| R16 | adopt | Separate columns: `assistant_paused_at/reason`, `assistant_cap`, `human_required_at/reason`. Resume clears pause only; hand-back clears all three explicitly. |
| R17 | adopt | Reopen cap keyed on `closed_by` (captured before the reopen clears it); cap = min(existing, draft). |
| R18 | adopt | Silent release re-checks under the lock via `flag_human_required!`; counts committed transitions only. |
| R19 | adapt | `assistant_acted_at` + `assistant_idle_since` scope + `redispatch_assistant_turns!` + a doctor warning cover unassigned/draft-level silence without work rows. At `:draft` the humans are the responders anyway; nobody is stranded. |
| R20 | adopt | Silent release **is** `escalate!(by: :system, reason: "assistant_silent")`: seat released *and* a person required; the revision bump fences the delayed job. Inactive assistants are swept regardless of `responds_within`? — their seats fail `doctor`'s `assistant seats` check and the sweep's `escalate!` path is the same; `deactivate!` documents running the sweep. |
| R21 | adapt | Redispatch task re-emits `:assistant_turn` for idle turns; at-least-once, duplicates harmless (R06). No work table. |
| R22 | adapt | `seen_turn` (the ticket turn the reviewer rendered) replaces `even_if_stale`; the model refuses a mismatch; the console re-renders with the current turn and the text preserved. Drafts carry `proposed_turn` for `stale?`. |
| R23 | adapt | `support_console_draft` looks up any status and flashes `draft_already_reviewed`; the model raises `InvalidTransition` for non-pending (a console message, not a replay protocol). |
| R24 | adopt | `was_stale` computed before mutation; `body: ""` is an `ArgumentError`; a human plain `reply!` supersedes pending drafts. |
| R25 | adopt | Drafts have `has_many_attached :files`; attachment-only drafts allowed; files copied to the message on send. |
| R26 | reject | Separate approve/publish and immutable revisions are a workflow product; `send!` (approve+send, verbatim or edited) and `sent_body` cover 0.3. Schema leaves room (`sent_body`, `reviewed_by`). |
| R27 | adopt | `request_human!` does reopen + `ensure_writable!` + flag in one lock. |
| R28 | adopt | `hand_off_when` fails closed: non-boolean or raise ⇒ reported + `human_required` (`hand_off_when_error`); message preserved. |
| R29 | adopt | `assistant_in_play?` = configured on the desk **or** any assistant message in the case; the door renders on that and shows a status line while a person is required. The chats thread slot is not needed: the partial is rendered by the host's thread view (CarHey ejects chats views). |
| R30 | adopt | `Ticket#role_of` unchanged; `Transcript` is its own serializer. |
| R31 | adopt | `acts_as_support_agent kind: :ai, if: :active?`; `ensure_agent_record!` re-reads `active?` fresh; config is code (reloads with the app). |
| R32 | adapt | Provenance and `display_name` are snapshotted in message metadata; signed/nameless is decided at send by posting `author: rose` or `author: nil`, so a later mode change never rewrites old bubbles. No chats change. |
| R33 | adopt | Migration derives FK types from the referenced columns; `sources` default `[]`; guards preflight every statement. |
| R34 | adapt | The new pointer column is all-NULL at migration time (nothing stale to repair); rolling-safe claim scoped to the schema expansion; `config.assistant` only after full deploy. |
| R35 | adopt | `brief(include_internal: false)` excludes notes/drafts by default; README warns that `support_context` goes to the model. No separate `assistant_context` hook (hosts shape `support_context`). |
| R36 | adopt | Sources validated (≤ 20, title ≤ 500, http(s) URL ≤ 2048); host metadata nested under `"host"`; reserved `"support_desk"` namespace; templates escape. The "imperative grep" test is dropped. |
| R37 | adapt | Message metadata snapshots the display name; export uses a positive per-kind mapping (unchanged shape plus `from: "assistant"`). |
| R38 | adopt | `config.default_assistant=`; `config.assistant(key)` never reads the default; explicit `desk.assistant = nil` disables. Implicit single-assistant default kept (DX). |
| R39 | adopt | Generator prints the stanza, writes name-specific files, never overwrites, requires `--disclosure`. |
| R40 | adopt | Exact actor key first; bare id (UUID or integer) only when exactly one pool member matches. |
| R41 | adopt | Honest compatibility statement (§13.1); `needs_human` tab hidden unless relevant. |
| R42 | adopt | §16 explains global-ceiling vs topic caps; promotion = raise `autonomy` + cap the rest. |
| R43 | adopt | Metrics defined with denominators; acceptance ≠ accuracy; containment labelled a proxy. |
| R44 | adapt | Moderation: both signed (Assistant author) and nameless (desk sender) shapes named for the host bridge; audit = `ticket_transitioned` post-commit, stated as such. |
| R45 | adopt | Hand-back and resume emit `:assistant_turn` when awaiting; `:nothing` is documented as "did not act" and surfaces in the idle-turn check. |
| R46 | adapt | The turn is checked once at the start of the outer operation; nested `assign!` bumps the revision but the outer operation already passed its check and reports the successor turn. |

## What v2 got structurally right and v3 keeps

The fail-closed stance everywhere; the separation of pause / cap / human
required; "humans outrank"; the `seen_turn` idea; derived FK types;
`default_assistant`; ancestor-minimum topic caps; no triage for the AI; the
honesty about compatibility and metrics.

## Why v3 stops short of v2

v2 answers "what would make this correct for any host, any scale, any
harness topology". v3 answers "what does a gem with one assistant per desk
and a row lock need to be *safe*". The difference is nine tables versus two,
a claim/lease protocol versus one integer, and a harness that reads
`claim.context` and manages `idempotency_key`s versus one that calls
`ticket.respond!(text, by: rose, turn:)`. Every guarantee the owner asked for
— no double answers, no authority creep, human-in-the-loop, a way to a
person, evidence — holds under v3's tests (§12 of the PRD). When a second
assistant per desk or a multi-tenant host arrives, v2 is the map for the
next step, and nothing in v3's schema blocks it.
