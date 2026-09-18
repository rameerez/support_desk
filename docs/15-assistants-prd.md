# PRD — Assistants as a first-class use case of support_desk

*2026-09-18; revised after adversarial review of d9ff5c5 against support_desk
4da67ed and the local Chats and CarHey sources. Proposed target: support_desk
0.3.0; required Chats release version is provisional until its compatibility
review. Nothing specified here is implemented or production-certified.*

This is the implementation contract. It replaces the original algorithms,
examples and migration sketch, rather than adding exceptions to them.
[14](14-assistants.md) explains the design; [the review](15-assistants-review.md)
records findings and the tests required to close them. Owner choices in
[12](12-open-questions.md) #19–22 remain intact. A passing documentation audit
is not evidence that these runtime invariants have been implemented.

## Contents

0. Scope and decisions
1. Goals and responsibility boundary
2. Vocabulary
3. Invariants
4. Public API
5. Algorithms and transaction boundaries
6. Schema and migrations
7. Console, requester and queue surfaces
8. Localization and rendering
9. Host integration and generator
10. Disclosure, privacy and authorization
11. Evidence and operations
12. Acceptance tests
13. Compatibility and rollout
14. README contract
15. Delivery gates
16. CarHey integration
17. Adversarial scenario register
18. Explicit deferrals
Appendix A — configuration example
Appendix B — sequences
Appendix C — file map

## 0. Scope and decisions

The gem owns support semantics and reliable support writes. The host owns
model calls, prompts, retrieval, classification, tools, scheduling, provider
retries, evaluation and business actions. No responder superclass, provider
SDK, model name, queue runner, arbitrary tool executor or prompt ships in the
gem. A durable work record is a support operation, not an agent runtime.

Preserved decisions:

| Decision | Contract |
|---|---|
| #19 | Ship SupportDesk::Assistant as an optional persisted identity. No responder_class. Host AI identities may bind to the same policy contract (§4.2). |
| #20 | Publishing an approved draft uses the accountable human sender as message.author; preserve generating author, reviewers, revisions and publisher separately. |
| #21 | Reopening an assistant-closed case leaves it unassigned with a ticket cap of at most draft. Explicit authorized hand-back may lift this cap, never unrelated restrictions. |
| #22 | Each configured assistant must explicitly choose disclosure. No default; none is a valid explicit choice with no warning. |

Defaults: autonomy draft; max_turns 6; response deadline 3 minutes;
may_open_conversations false; no arbitrary assistant triage permission;
private assistance permitted during a human requirement unless that
requirement/policy forbids it. Disclosure is never defaulted by a generator.

Included: persona/presentation, policy, reliable work, drafts with immutable
revisions and attachments, atomic approve-and-send, separate review/publish,
human intervention, requester door, context, history and host integration
seams. One configured autonomous responder per desk in this release; the same
persona may serve several desks. Multiple alternative drafts may exist as
history, but only one is the current proposal per case. This is an explicit
product limit, not a limitation on provider or harness choice.

Compatibility is **no unsolicited assistant behavior on unconfigured desks**,
not the original impossible promise of identical SQL and zero column writes.
Schema additions, actor-key picker values and validation of previously
unprotected kind: :ai actors are documented changes. Existing human ticket
behavior and default tabs stay unchanged. A host explicitly invoking a new
human-intervention verb gets its documented behavior even without an AI.

## 1. Goals and responsibility boundary

| Concern | Gem | Host |
|---|---|---|
| Identity | Record/contract, attribution, historical presentation | Persona and account authentication |
| Authority | Enforce per-operation decisions at the write | Business/tenant/access rules |
| Review | Draft revisions, decisions, publication and console | Generate content and choose reviewer rules |
| Intervention | Persist restrictions, queues, resolution | Detect situations and choose specialist pool |
| Execution | Work receipts, claims, freshness, idempotent effects | Schedule and execute any harness |
| Context | Authorized structured support records | Select product facts, redact, retrieve |
| External actions | Correlation references to host review records | Refund/ride/account validation and execution |
| Evidence | Who proposed/reviewed/published and why allowed | Model trace, cost, evaluation, audit delivery |

Success means:

- A small harness can fetch work/context and commit a result without
  reconstructing support policy, replay protection or human takeover.
- Every public write has a specified actor, permission, state check, return
  value, idempotency behavior and error behavior.
- Queued work is discoverable after a failed enqueue or process crash.
- No existing console, raw supported Chats write or alternative ticket verb
  bypasses assistant restrictions.
- A human can review and edit without race-prone hidden form assumptions.
- Customer access to a human survives pause, outage and configuration removal.
- Runtime acceptance is based on §12 tests, not test count or coverage alone.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| assistant | A policy-bound AI agent identity; normally SupportDesk::Assistant |
| principal | Persisted actor accountable for an operation; supplied by trusted host authentication, never chosen by model output |
| level | Reply autonomy preset: off, observe, draft, reply, resolve |
| restriction | An independent rule that only reduces permissions; all are ceilings, not “floors” |
| human requirement | Durable request for human handling or intervention, with its own resolution |
| assignment | Responsibility for a case; distinct from permission and work claim |
| revision | Monotonic ticket input/control version, unrelated to a message UUID |
| turn | Opaque token bound to ticket, assistant, revision and policy version |
| work | Durable opportunity to act on a current input/control revision |
| claim | Short-lived execution lease; prevents obsolete workers from committing |
| operation | Idempotent domain mutation and its persisted receipt |
| draft | Proposal identity with immutable revisions, review and publication history |
| approval | Human decision about one exact draft revision and reviewed ticket context |
| disclosure | Host-chosen requester presentation; independent of stored accountability |

Being assigned, being permitted to draft, being permitted to send, and having
an approved proposal are different facts. No single “AI mode” encodes them all.

## 3. Invariants

Each ID is an acceptance test family in §12.

| ID | Invariant |
|---|---|
| I01 | An unconfigured desk produces no assistant work, drafts, notices or extra visible tabs by default. Existing human behavior remains. |
| I02 | Every automated actor is policy-bound or refused; a custom kind: :ai model never falls through as human. |
| I03 | Domain authorization is enforced inside each operation; actions_for is a projection for the UI, not a substitute for host authorization. |
| I04 | All supported support-message creates/edits/deletes serialize with assistant commits and update freshness in their own transaction. |
| I05 | Assistant mutations require a valid work claim/turn and idempotency key; no nil-token bypass. Every replay returns its recorded result or explicit conflict. |
| I06 | A stale/revoked worker cannot publish, close, reclassify, escalate or alter ownership. No network call runs under a ticket lock. |
| I07 | One autonomous answer per requester input opportunity. Drafting, acknowledgement and system notices never count as answering a customer. |
| I08 | A human reviews an exact draft revision and ticket context. Editing invalidates approval; publication is atomic and retry-safe. |
| I09 | Pause, human requirements, reopen cap, topic caps and host restrictions are independent. Relaxing one cannot clear another. |
| I10 | An assistant cannot broaden its own authority by editing a topic, subject, metadata, configuration or assignment. |
| I11 | Human takeover fences obsolete work; a customer’s human request prevents subsequent autonomous publication until explicitly resolved. |
| I12 | Work remains discoverable and ages from a durable deadline even before an assistant has acquired a seat. Sweep races cannot release a human. |
| I13 | Identity, provenance and disclosure survive rename, deactivation and configuration removal. No hidden signature means no visible signature, not no author. |
| I14 | Drafts, attachments, internal summaries, approvals and model metadata stay out of requester exports/broadcasts unless explicitly published. |
| I15 | A rejected operation rolls back its entire mutation, including notices, assignment, draft supersession and receipts, even if the caller rescues inside an outer transaction. |
| I16 | Automated outreach uses the same contextual policy, counters, attribution and operation receipts as inbound replies. |
| I17 | Rollout enables automation only after all web/job/cable writers implement the new transaction boundary and backfill is verified. |
| I18 | No provider-specific dependency or execution loop is required to use the contract. |

## 4. Public API

Signatures below define the intended Ruby API. Code fences containing calls
are illustrative host integration, not currently runnable APIs. Tables define
keyword types/defaults without invalid Ruby “def x / x=” pseudo-signatures.

### 4.1 Configuration

`config.assistant(key, &block)` declares/reconfigures with a block; without a
block it reads the configuration or raises ConfigurationError. Keys normalize
to nonblank bounded strings internally; public examples use symbols. Repeated
declarations are deterministic; removed settings are removed on reload, not
silently retained from a previous initializer. `config.assistants` returns a
read-only map. `config.assistant?(key)` returns a boolean.

Use `config.default_assistant = :rose` for the default desk. Do not overload
`config.assistant` as both a declaration lookup and a default-desk getter.
`config.desk(:billing).assistant = :rose` chooses a persona; explicit nil
**disables** that desk and is distinct from inheriting the default. There is
no implicit single-assistant binding across every desk. `desk.assistant_key`
returns the effective key or nil; `desk.assistant` resolves its identity.

AssistantConfiguration setters/readers:

| Setting | Default/type and validation |
|---|---|
| name | nil -> humanized key; nonblank String when supplied |
| avatar | nil; String or callable(identity) returning displayable value/nil |
| autonomy | draft; member of LEVELS |
| disclosure | required; signature_and_notice / signature / notice / none |
| max_turns | 6; positive Integer or nil (unlimited is documented, doctor warning) |
| responds_within | 3.minutes; finite positive duration or nil; nil disables timeout only, not liveness diagnostics |
| may_open_conversations | false; strict boolean |
| triage | false; strict boolean; grants requests to change topic/attach subject subject to host authorization |
| identity | nil -> built-in Assistant; callable returning one persisted eligible kind: :ai record for this key |
| hand_off_when | nil or local callable(ticket, message) returning true/false/nil |
| cap | nil or local callable(ticket) returning LEVELS member/nil |
| policy_version | required nonblank String, changed whenever host semantic policy changes |
| hand_off_line | localized generic acknowledgement; String/Symbol/local callable/nil |
| human_requested_line | localized acknowledgement; same types |
| disclosure_line | localized disclosure; same types, must produce nonblank text when notice required |

Validate primitive settings at configuration time, deferred callable results
when used. Booleans cannot be truthy strings; durations reject NaN/infinity;
confidence is nil or finite numeric 0..1. Line interpolations are name, desk,
and optional human_reply_within; never promise a duration when absent.
No I/O/model/network calls in cap, authorization or phrase hooks. Dynamic
record lookups are allowed but documented as queries, never “zero-query.”

`config.authorize_support { |actor, action, ticket, resource:| ... }` is a
local per-operation host boundary. Return true/false; nil denies. Errors deny
and report; they do not grant permission. Called inside the mutation lock and
on read-context construction. It is an additional restriction, never a way to
override gem invariants. A ticket can be nil only for collection outreach;
resource is the validated recipient/subject request then. Defaults preserve
human eligibility; AI additionally requires configured identity/desk match.
Hosts must wire tenant/role policy here; existing authorize_console remains
an additional HTTP boundary and cannot protect job calls by itself.

`config.assistant_context { |ticket, actor| ... }` optionally returns bounded,
JSON-safe host facts. Default {}. This is separate from support_context meant
for human console display. Errors fail that work attempt, not the requester’s
message. `config.assistant_context_version { |ticket| ... }` optionally returns
an opaque host data version to invalidate answers when product state changes.

Topic `assistant:` is an inherited **ceiling**. Effective cap is the minimum
of all ancestor and leaf values; a child cannot raise a parent’s restriction.
Unknown topic caps at observe. Host hard restrictions are separately applied
and are not removed by reclassification. For trusted human correction, an
explicit cap-resolution operation is required (§4.5), with evidence.

### 4.2 Identities and historical rendering

`SupportDesk.assistant(key)` returns the configured principal (built-in or
identity resolver); unknown key raises ConfigurationError. With no argument,
resolve the explicit default key, returning nil when absent. The built-in
record is created lazily through `find_by || create_or_find_by!`; context/UI
reads of historic identity must not create missing rows.

`Assistant` has key, active, settings plus persisted presentation snapshots.
Methods: configured?, name, avatar, display_name, support_agent_name,
support_agent_avatar, support_agent_kind (= :ai), support_agent?, on_duty?,
support_assistant_key, desks, held_tickets. `deactivate!(by:, reason:)` updates
active/control version and invalidates work; `activate!(by:)` does not remove
case restrictions. Both require authorized human operations; no record delete
through public APIs. Configuration removal makes it ineligible, not unreadable.

A host identity uses `acts_as_support_agent kind: :ai`, implements
`support_assistant_key`, and is returned by that key’s identity resolver.
Checks compare persisted polymorphic identity, not names or Ruby object
identity. `SupportDesk.assistant_actor?(record)` tests the declared AI role;
`SupportDesk.assistant_configuration_for(record)` validates the key/binding.
An unbound AI actor raises AssistantNotAllowed for every support mutation,
including approval, reopen and outreach. This is a documented behavior change
for pre-existing custom AI models. Unknown kind values fail macro validation.

`SupportDesk.reset_assistants!` clears identity caches, never database state.
Eligibility/active state is read freshly before committing; a memoized record
is never authority. Deactivation and commits use the common lock protocol in
§5.1. Authentication and selecting the principal are the host’s job. The
model must never supply by:, assistant key, tenant or approved_by fields.

Message presentation is snapshotted at publication: assistant key, actor key,
kind, display name, signature mode and notice version. Later renames or mode
changes apply to future messages. Historic rows continue rendering if a
configuration disappears. Disclosure choices are honored on all requester
surfaces (bubbles, list rows, notices, exports, avatars), not just one helper.
`notice` and `none` suppress personal signatures while retaining internal
provenance. `notice` copy may identify the assistant, per host configuration.
Staff always see the real provenance. AI draft approval yields a human-authored
message with separate immutable drafting/review metadata (#20).

### 4.3 Policy

Public constants: `AssistantPolicy::LEVELS = %i[off observe draft reply resolve]`
and `RANK = LEVELS.each_with_index.to_h.freeze`. The preset table below is the
source for potential actions; executable state checks determine allowed_actions.
Do not destructure `Hash#min_by` as level/rule: it returns a key/value pair.

`AssistantPolicy.for(ticket, actor:)` produces an immutable evaluated object:
level, constraints, reason_codes, because (localized explanation), policy_version,
allowed_actions, `may?(action, resource: nil)`, `to_h`, null?. Convenience
may_observe?, may_draft?, may_reply?, may_close? call that same decision logic.
`level` alone never answers whether an operation is allowed in this state.

Presets:

| Level | Potential operations before state/host checks |
|---|---|
| off | none |
| observe | read allowed context, note, request human intervention |
| draft | observe + propose/revise draft |
| reply | draft + conditional take/reply/release |
| resolve | reply + conditional close |

Triage is a separate opt-in capability; no “observe” preset silently permits
refiling money cases or attaching another customer’s record. Assistants never
approve/reject human review, resolve human requirements, resume themselves,
reopen, assign another actor, or edit their own binding/configuration.
Escalating to a pool is supported; assigning a named human is a human decision.

Decision inputs: actor binding/current eligibility, desk activation epoch,
configured level, topic ancestor caps, host cap/action authorization, persisted
case caps, pause state, open/closed/requester availability, human requirements,
holder, response opportunity, max_turns and claim freshness. Human-held cases
cap independent AI publication at draft. Human requirements default to draft
assistance but forbid AI holding/publishing/closing; a requirement can forbid
assistance too. Closed cases permit authorized context reads only; no automated
notes, drafts or closure loop on a closed ticket. Inactive/unbound actors have
no actions. Off-duty human restrictions for review match console rules.

Record **all** applicable restrictions and the decision code, not just the
first minimum. Ties have no semantic effect. Reason text is presentation, never
parsed as an enum. Policy errors suppress automation and produce durable
operational failure/intervention evidence; they never silently proceed.

### 4.4 Work, turns and receipts

Ticket readers:

```ruby
ticket.assistant
ticket.assistant_policy(actor: rose)
ticket.assistant_turn                 # opaque token or nil; NOT a message id
ticket.assistant_revision             # integer, monotonic
ticket.pending_assistant_work
ticket.assistant_paused?
ticket.human_required?
ticket.held_by_assistant?
ticket.assistant_turns_left
ticket.assistant_in_play?             # historical/current participation, not permission
ticket.human_request_available_to?(requester)
```

A Turn binds ticket ID, assistant actor/key, requester message ID (nullable
only for explicit outreach or human-requested private draft), ticket revision, activation epoch, policy
version, evaluated permission fingerprint and optional host context version. Treat it as an opaque serialized value.
It is not a bearer credential. Actor authorization remains independent.

`SupportDesk::AssistantWork` fields/methods:

| API | Result |
|---|---|
| `.pending`, `.overdue`, `.for_assistant(actor)` | Relations scoped by host before exposing remotely |
| `claim!(by:, lease_for: 2.minutes)` | WorkClaim or WorkUnavailable; atomic persisted lease |
| `status`, `attempts`, `due_at`, `result`, `turn` | Readable state |
| `claim.to_h` | Authorized transport envelope containing work_id + lease token; never include in model context/logs |
| `claim.turn` | Current accepted turn after its own committed operation; never refreshes across another actor |
| `claim.current?` | Advisory early check; never substitutes for commit checks |
| `claim.renew!(lease_for:)` | Extends only a live claim; finite positive lease <= 5 minutes, bounded by work deadline when present |
| `claim.context(include_internal: false, limit: 50)` | Authorized immutable Context (§4.8) |
| `claim.complete!(reason:, idempotency_key:)` | Persist deliberate no-action outcome; reason required |
| `claim.fail!(code:, retryable:, details: {})` | Record failure and release claim or require human intervention |

Claims include an unguessable fencing token; reclaiming work invalidates the
old token. The host controls retries/scheduling. Lease expiry is separate from
due_at: repeated retries cannot extend the customer’s wait forever.
Read-only/draft work does not take the ticket away from a human.

Every assistant mutation accepts `turn:`, `claim:`, `idempotency_key:`.
They are REQUIRED for automated actors, even where legacy human signatures
use nil defaults for compatibility. Missing data is InvalidInput, not a bypass.
For a remote adapter, claim: accepts the validated WorkClaim object or its
transport envelope. Look up the work from its ID and validate the stored
claim digest, actor and scope; the envelope does not authenticate the actor.
Turn serializes to an opaque string and never embeds private context.
Keys identify a logical action, stay the same on retries, and differ between
deliberate revisions. Receipt scope is ticket + actor + action + key. Payload
fingerprint includes content, attachments, expected revision and targets;
reuse with different inputs raises IdempotencyConflict. Successful replay
returns the original result before freshness checks, subject to current read
authorization; it cannot perform another side effect. Body/source validation
failures roll back the receipt too. Record terminal withheld outcomes once.

### 4.5 Ticket writes

New signatures:

```ruby
respond!(body = nil, by:, turn:, claim:, idempotency_key:, files: [],
         confidence: nil, sources: [], metadata: {}, request: nil)
draft!(body = nil, by:, turn:, claim:, idempotency_key:, files: [],
       confidence: nil, sources: [], metadata: {}, request: nil)
escalate!(by:, reason:, summary: nil, turn: nil, claim: nil,
          idempotency_key:, request: nil)
request_human!(by:, request: nil)
pause_assistant!(by:, reason: nil, idempotency_key:, request: nil)
resume_assistant!(by:, idempotency_key:, request: nil)
request_assistant_work!(by:, purpose: :draft, idempotency_key:, request: nil)
change_assistant_cap!(to:, by:, reason:, idempotency_key:, request: nil)
require_human!(by:, reason:, key:, allow_assistance: true, summary: nil,
               request: nil)
resolve_human_requirement!(requirement, by:, reason:, idempotency_key:,
                           request: nil)
resume_automation!(by:, resolve_requirements: [], lift_reopen_cap: false,
                   clear_pause: false, reason:, idempotency_key:, request: nil)
```

respond! returns Outcome; draft! returns Draft; escalate! returns
HumanRequirement; request_human! returns the active requester requirement;
require_human! returns the keyed requirement; request_assistant_work! returns
AssistantWork; other controls return Ticket. A human may request/regenerate a
proposal on an open case using request_assistant_work!, which creates a new
purpose: draft opportunity under current policy without granting send/close
permission. This is the explicit DX for “suggest a reply again” after rejection
or a plain human response. It cannot circumvent off/paused/context-read rules.
For a case with no requester text, it may prepare a human-reviewed outreach
draft only with host recipient/context authorization; it is never an inbound
answer opportunity. Turn purpose distinguishes manual draft, inbound response
and autonomous outreach.
The outcome contract in §4.7 defines which are terminal work results.

`request_assistant_work!`, draft review and restriction-resolution controls
are human-only; escalate! accepts an eligible human or a claim-bound AI.
It does not accept arbitrary Symbols. Recovery uses require_human! with the
specific trusted host path described below, not a loophole in escalate!.
Human-only controls require a persisted eligible authorized human; Symbols
are never humans. `require_human!(by: :system, ...)` is allowed ONLY as a
trusted host operation, with this exact symbol (no arbitrary symbol allowance)
and host action authorization. It can impose restrictions, never clear them.
Assistant escalation requires a current claim and observe+ policy. The
requester door requires this ticket’s freshly eligible requester.

`HumanRequirement` has stable key, reason_code, internal summary,
requested_by, requested_at, allow_assistance, resolved_by, resolved_at,
resolution_reason and optional host reference. Multiple active requirements
can coexist; resolving one does not clear others. No universal “clear flag.”
Readers/scopes: `ticket.human_requirements`, `HumanRequirement.unresolved`,
`.resolved`, `requirement.resolved?`, `requirement.allow_assistance?` and
`requirement.to_h` (staff-safe summary, not raw actor objects). Resolve through
the ticket method so every state change uses its locks/policy. There is no
public destructive delete or raw resolved_at setter.
Human-required cache columns, if used, are derived from unresolved rows.
Repeated requester clicks return the active requester-request row without
another page or priority bump; a later explicit request after resolution can
create a new requirement. Eligibility/authentication and usual request rate
limits still apply. A valid human request is not classified by an LLM.

Pause has its own state. Resume clears only pause. Reopen cap is separate.
Hand-back through assign!/hand_off! requires an explicit human and invokes
resume_automation! with specified restrictions, not implicit wildcard clearing.
The common no-restrictions hand-back stays one operation. Unresolved host hard
requirements cannot be lifted by reassignment; their host resolver must allow it.
change_assistant_cap! is an authorized human correction of the persisted
case cap from automated triage: to: is a level or nil to clear that one cap,
with a required reason. It cannot lift topic/host hard ceilings, reopen cap,
pause or human requirements. It returns Ticket. A model cannot call it to
undo the restriction it inherited. Each control operation persists old/new
state and invalidates existing work.

Existing verbs gain the optional automation envelope
`turn: nil, claim: nil, idempotency_key: nil`; nil remains valid only for
legacy human/system operations where already supported. reply! also accepts
metadata: {}. close!, note!, change_topic!, attach_subject!, assign!, hand_off!,
release! and reopen! MUST all route AI actors through the same gateway.
No public AI write is exempt because it is “internal.”

Assistant-specific rules:

- reply!: open, contactable, latest unanswered requester opportunity, live
  claim, reply permission and available turn budget. Return Chats::Message; the live
  claim exposes its committed successor turn for an optional conditional close.
- close!: resolve permission; currently assigned to this assistant; no
  unresolved human requirement or pending customer input. Typically follows
  its reply using the successor token returned by that operation. Never close
  a fresh unanswered case just because level is resolve.
- assign!(to: self): unassigned, eligible to hold, open and awaiting support;
  no assignment to another principal, no hand-back impersonation.
- release!: only its own current seat; a trusted recovery operation may
  release a now-ineligible assistant without granting it other actions.
- hand_off!: AI must use escalate! instead; human handoff works as before.
- change_topic!/attach_subject!: triage opted in, host authorizes target and
  requester/tenant relationship; retain preexisting restrictive case cap so
  the actor cannot move itself into a more permissive category.
- reopen!: AI refused. Human/requester reopen obeys #21 based on the recorded
  closer’s kind, not merely the last assignee.
- approve/reject/resume/resolve requirement: AI refused even if a host AI
  object passes every other agent predicate.

`actions_for(actor)` remains the console offer/refusal projection, composed
with authorize_console for HTTP. It uses the same domain permission service;
resource-specific approval/target checks occur at the actual write. It never
returns every preset verb regardless of state or resolves arbitrary GIDs.
`agents_to_notify` includes eligible humans only, not every non-Assistant
class. Custom AI identities are excluded too. Assigned eligible human gets
notified; otherwise use the desk’s eligible human pool and existing duty rules.

### 4.6 Drafts and review

`ticket.review_context(for: human, draft:)` returns an immutable ReviewContext:
current draft revision, current ticket transcript/controls, reviewed_turn and
allowed review actions. Its serialized token binds the human, ticket, draft
revision, current ticket revision and review-policy version. It is independent
of AI work leases and never grants authority by possession. The console and
alternative UIs use this token for approve!/send!. Compare current authorized
review policy again at publication; an assistant work token is not a human
review token.

`Draft` is the proposal identity. `DraftRevision` is immutable body, attachment
set, source references, author/editor, base ticket revision/context digest,
policy snapshot and created_at. `DraftReview` records reviewer, exact revision,
reviewed ticket revision, decision, reason, time and approval expiry (optional
host policy). Original machine content is never overwritten.

Statuses: pending, approved, sent, rejected, superseded, expired. At most one
current proposal (pending OR approved) per ticket, enforced under the ticket
lock and partial unique index where supported. Creating an intentional new
proposal supersedes the old only after validation succeeds. Replaying an old
operation never supersedes a human’s current work. Human editing uses a new
immutable revision; it is part of draft review, not a general saved-drafts
product. A future “save human draft” feature can use the same schema.

```ruby
draft.revise!(body:, by:, expected_revision:, files: nil,
              idempotency_key:, request: nil)
draft.approve!(by:, revision:, reviewed_turn:, idempotency_key:, request: nil)
draft.send!(by:, revision:, reviewed_turn:, idempotency_key:, request: nil)
draft.publish!(by:, approval:, idempotency_key:, request: nil)
draft.reject!(by:, revision:, reason: nil, idempotency_key:, request: nil)
```

revise! returns DraftRevision; approve! returns DraftReview; send! is atomic
approve-and-send and returns Chats::Message; publish! publishes a still-valid
approval and returns that message; reject! returns Draft. In this release
publish! requires a human publisher, so author is always the human who sends
(#20); a queue may execute the authenticated human command after rechecking
that human’s eligibility/authority. An AI cannot supply a human ID to publish.
SupportDesk records reviewer and publisher independently if they differ.

There is **no even_if_stale boolean**. The reviewer renders the current
conversation and submits reviewed_turn plus the exact draft revision. Under
the lock the token must still be current. This permits a deliberate send of
an older proposal after reviewing new context, but cannot preapprove unknown
future messages. A new edit or publication of any reply invalidates a pending
approval. Merely creating the approval row does not increment the input/control
revision and invalidate itself. Review audit entries are evidence, not new
customer/context facts. A revised draft does invalidate the approval by revision. Plain human reply supersedes the current draft; the reviewer may
explicitly create a new proposal if a follow-up is wanted.

Sending an approved proposal after changed context requires renewed approval.
The compound send! may review and send in one click after a fresh page render.
Concurrent send/reject/revise/close outcomes serialize on ticket then draft;
same key returns same result, conflicting operation returns InvalidTransition
or StaleDraft, never a duplicate message. Closed ticket sends are explicitly
refused even when legacy human reply! allows a final word on closed cases.

Draft attachments follow Chats type/size/count policy, are validated on the
model and accessed only through an authenticated staff endpoint. No public
blob URL in a draft/event/brief. Default ActiveStorage signed blob URLs are
bearer URLs, not proof of current staff authorization. Do not emit them for
private drafts; staff controller routes stream/proxy authorized attachments.
Hosts exposing alternate blob routes must preserve the same access boundary;
the gem cannot claim privacy for a host that publishes those URLs elsewhere. Attachment changes make a new revision and
invalidate review. Uploaded blob references must be authorized for this
principal/ticket; a valid signed blob ID alone is not tenant authorization.
Pin checksum/version in the revision and revalidate before publication so a
mutable backing object cannot substitute content after approval. Publishing copies authorized attachment associations in
the transaction; blob storage upload itself is outside the transaction and
must be validated before approval. Failure leaves the proposal/review intact
and no message/notice/assignment. Pure attachment drafts are supported; no
fallback silently drops files supplied to respond! at draft level.

Readers/scopes: drafts, pending_draft (current pending/approved proposal),
Draft.pending/.approved/.sent/.rejected/.superseded/.expired/.reviewed/.by(actor),
Draft.verbatim/.edited (compare published revision with first proposal),
draft.current_revision, revisions, reviews, published_message, stale?,
final_body, confidence_percent. State changes use domain methods; direct AR
updates are not a supported way to approve or publish.

### 4.7 Outcome and errors

Outcome is immutable: action (sent/drafted/withheld), message, draft, policy,
reason_code, requirement, operation_id, successor_turn, replayed?. Predicates
sent?, drafted?, withheld?, escalated? inspect fields, not English prefixes.
to_h serializes IDs and decision, not AR objects. Max-turns can be drafted AND
escalated. Explicit reply! raises rather than silently drafting.

| Error | Meaning |
|---|---|
| NotAnAssistant < NotAnAgent | Automated operation has no valid bound principal |
| AssistantNotAllowed < NotAllowed | Current permission forbids action; carries action and decision |
| StaleTurn < InvalidTransition | Revision/policy/activation/ownership changed |
| WorkUnavailable < InvalidTransition | Completed, leased, expired or revoked work |
| StaleDraft < InvalidTransition | Revision or reviewed context changed |
| ApprovalRequired < NotAllowed | No valid human approval for publication |
| IdempotencyConflict < InvalidTransition | Key reused with different inputs |
| InvalidInput < SupportDesk::Error | Domain argument schema invalid (distinct from console-private InvalidInput) |

Existing Locked, ConfigurationError, RecordInvalid and Chats errors retain
their meaning. Current policy refusal after a model call is an expected race,
not automatically a harness bug. Do not blindly retry permanent refusals.

### 4.8 Context, transcript and brief

`ticket.agent_context(for:, include_internal: false, limit: 50)` returns an
immutable Context with turn, policy, brief, transcript, generated_at and
`to_h`/`to_text`. Claim#context binds it to the work turn. This is the normal
integration entry point; independent reads can otherwise mix revisions.
Read under a short lock or read/verify revision before returning; never call
a provider there. Enforce host read authorization and requester data policy.

Transcript is Enumerable, chronological, with bounded newest page (default
50, configurable bounded maximum), cursor-based before/after traversal and
stable message IDs. Transcript roles are requester/human/assistant/system;
they are **not provider system/developer instruction roles**. Keep lifecycle
`Ticket#role_of` requester/agent/system unchanged; use a separate serializer
so assistant messages still update ordinary reply clocks. Message view:
`{id, role, actor_key, name, body, at, edited_at, deleted, assisted,
attachments: [{id, filename, content_type, byte_size}]}`. No download URL or
hidden original text for tombstones. Order using the authoritative serialized
message sequence for managed tickets (§5.2), not timestamp assumptions.

Brief.to_h has schema_version, ticket {id, reference, status, awaiting, topic,
opened_by_kind, closer_kind, assignment, intervention summaries, pause/caps},
desk {key, name}, assistant {key, allowed_actions, constraints, turns_used,
turn_limit}, requester {display_name}, subject {type, label, status},
host_context {}, transcript_page {items, cursors, truncated}, and optional
internal {notes, draft_outcomes}. Each list is bounded and reports truncation.
Notes/drafts are excluded by default; include_internal requires separate host
authorization and explicit choice. Context for AI is NOT automatically the
human console’s support_context or every event payload.

`ticket.transcript(for:, limit: 50, before: nil, after: nil)` and
`ticket.brief(for:, include_internal: false, transcript_limit: 50)` expose the
same serializers independently for staff tools; they document that only
agent_context/claim.context binds a consistent proposal turn.
`Requester#support_context` defaults {} and feeds human ContextCard only.
The host explicitly allowlists fields into assistant_context. No “redacted”
claim without an actual implemented filter. User/AI text remains untrusted
content even if it contains imperative sentences; a regex checking “You are”
does not establish prompt-injection protection.

### 4.9 Desk, queue, metrics and tasks

Desk.humans filters the configured pool to currently eligible human-kind
records; Desk.agents combines that with its configured eligible assistant,
deduplicated by actor key. Off-duty eligibility remains separate. Reads may
include inactive/historic actors for display; assignment choices cannot.

New ticket scopes: held_by_assistants, held_by_humans, needs_human,
with_pending_draft, assistant_paused, assistant_capped, resolved_by_assistant.
Use persisted actor-kind snapshots or resolved configured identities for
custom AI models; no hardcoded assignee_type == SupportDesk::Assistant test.
Resolved_by_assistant means currently closed with recorded closer_kind ai;
it does not itself prove containment or absence of earlier human work.

Queue adds needs_human and review tabs when the desk uses the feature (or has
matching records). Existing default human-only tabs/count semantics remain.
Human intervention and overdue work are visible even while unassigned or
assigned to an assistant. next is still a read, never an atomic claim. Claim
work through AssistantWork; do not infer exclusivity from Queue#next.

Desk activation/control API (authorized human or trusted deployment principal,
never an AI agent):

```ruby
desk.enable_assistant!(by:, policy_version:, idempotency_key:)
desk.disable_assistant!(by:, reason:, idempotency_key:)
desk.assistant_enabled?
```

enable_assistant! refuses schema/backfill/version mismatch, validates binding,
records an activation epoch and creates outstanding work only after managed
state initialization. disable_assistant! changes the shared epoch immediately,
fences claims and exposes outstanding work for human handling; it does not
hide the door/history or discard drafts. These methods return the desk.
A host changes configured policy only with a new policy_version and enables
that version after deploying it to all relevant processes. A process whose
local version disagrees with the persisted active version cannot claim/commit
work. There is no silently successful mixed-policy fleet.

Public maintenance operations/tasks:

- `SupportDesk.reconcile_assistants!` / `support_desk:reconcile_assistants`:
  recover abandoned claims, timeout work, fence obsolete workers, release
  invalid seats, ensure overdue work has an unresolved human requirement.
- `SupportDesk.dispatch_assistant_work!` / `support_desk:dispatch_assistant_work`:
  re-emit durable pending work signals; bounded batch; at-least-once semantics.
- `support_desk:backfill_assistant_state`: explicit pre-activation catch-up;
  resets existing non-null stale pointers too, resumable and idempotent.
- `support_desk:assistant_status`: pending/overdue/leased/failed counts,
  oldest age and unresolved human requirements; read-only.

Reconcile returns structured counts (released, timed_out, recovered,
requirements_created, failed), not an increment for every scanned candidate.
A host schedules reconcile and dispatch; task absence is an observable warning.
Automatic failure handling uses trusted internal recovery, not an AI symbol
pretending to be a human. Runtime desk pause/activation epoch is persisted so
all processes see emergency disable without a rolling configuration deploy.

### 4.10 Events and internal evidence

Preserve existing event argument contracts (especially agent_replied).
Additional metadata belongs on the message or a new event; do not change
existing callbacks’ arity. All public notifications occur after the outermost
transaction commits. Required work/audit rows are written in the transaction.

| Event | Arguments |
|---|---|
| assistant_work_available | work |
| draft_proposed | ticket, draft |
| draft_revised | ticket, draft, revision, by: |
| draft_approved | ticket, draft, review, by: |
| draft_sent | ticket, draft, message, by: |
| draft_rejected | ticket, draft, by:, reason: |
| human_required | ticket, requirement |
| human_requirement_resolved | ticket, requirement, by: |
| assistant_paused / assistant_resumed | ticket, by: |
| assistant_work_failed | work, code: |
| assistant_withheld | ticket, assistant, reason:, policy: |

Choose one human_required fan-out for requester, assistant and timeout paths;
hosts must not page twice by subscribing to both its umbrella and a duplicate
specialized event. Existing ticket_released still fires when a seat is
released; hosts use the requirement event for paging. Capture immutable IDs
and decision snapshots for subscribers; reloaded Ticket may reflect later
state. Errors in subscribers are reported and isolated; work replay handles
failed enqueue, not a promise that arbitrary notification callbacks are durable.

Event kinds include these draft/control decisions. Every decision row carries
actor key/kind, turn/revision, policy version + constraints, operation ID,
reason code and permitted request metadata. Store summaries as explicitly
internal fields. Export uses a positive allowlist and per-kind field mapping,
not “exclude note and hope future event types are public.”

### 4.11 Chats seams

The original “two one-line seams” estimate is invalid. Required changes:

1. Messager#message! accepts metadata: {}, normalized as bounded JSON; caller
   may not overwrite gem-reserved provenance fields.
2. A **generic subject message-write wrapper** surrounds create/edit/delete
   in the same database transaction, before conversation/message locks.
   `subject.around_chat_message_write(message, operation:) { persist }`
   is the proposed duck contract. A subject without the method keeps existing
   behavior. Implement against actual callback ordering and prove §12 races.
   Ticket uses it to serialize requester writes, invalidate revisions and
   reject assistant/desk writes outside the authorized domain gateway.
3. A message-aware presentation hook consults immutable publication metadata
   before a mutable author signature fallback. Default signed-message behavior
   for non-support messages remains. A generic author chat_signature? veto
   alone is insufficient for stable historical disclosure.
4. A composable thread slot lets a subject render an authorized human door
   in the shipped thread as well as ejected host views; no mandatory copy of
   the entire Chats conversation template.

No direct conversation.messages.create! fallback bypassing validations.
Supported create/update/destroy APIs must enter the wrapper; raw SQL,
update_columns and arbitrary host code running with DB privileges are outside
the authorization sandbox and documented as unsupported bypasses.

The wrapper must not call network code. Both gems’ rows must share the same
transactional database connection for the stated atomicity; cross-database
support is out of scope. Existing after-commit message notifications still
fire once; support’s after-commit registration becomes an idempotent fallback
for unmanaged/legacy tickets, never the authority for managed ticket turns.

### 4.12 Test helpers

These are public helpers in SupportDesk::TestHelpers, documented in the README.
They construct valid operations rather than bypass model rules:

```ruby
support_assistant(key = nil)
claim_assistant_work(ticket, by:)
respond_as(assistant, ticket, body = nil, files: [], **options)
draft_as(assistant, ticket, body = nil, files: [], **options)
assert_pending_draft(ticket, body: nil)
refute_pending_draft(ticket)
assert_needs_human(ticket, reason: nil)
refute_needs_human(ticket)
assert_held_by_assistant(ticket, assistant = nil)
refute_assistant_spoke(ticket)
assert_assistant_policy(ticket, level, actions: nil, reasons: nil)
with_assistant_config(key = nil, **overrides) { }
```

support_assistant returns a real persisted configured identity.
claim_assistant_work returns a live WorkClaim for existing current work, or
raises when there is none. respond_as/draft_as acquire that work, fetch context
and supply a fresh logical operation key by default; callers may supply an
explicit key/claim/turn for retry/stale tests. They return Outcome/Draft and
never treat stale refusal as a successful assertion. assert_pending_draft
returns the current Draft and accepts body String/Regexp. Policy assertions
check reason codes, not translated prose. Configuration helper restores config,
identity caches and test activation state in ensure; it never leaks state into
the next test. Event capture uses the existing capture_support_events helper.
Do not stub the permission service for tests claiming to cover its invariants.

## 5. Algorithms and transaction boundaries

These are normative ordered algorithms, not copy/paste Ruby implementations.
Internal record helpers run under the already-acquired locks; do not recursively
call public transitions which resolve/reload the actor or acquire locks in a
new order. Write/publish halves follow the existing register! split.

### 5.1 Common mutation gateway

Lock order for managed tickets: assistant principal/control record when the
operation involves its activation or assignment; desk automation-control row;
ticket; work/receipt/draft/requirement rows; Chats conversation/message rows.
Take multiple same-type locks in stable primary-key order. Requester messages
and human takeovers take desk then ticket, without locking an AI record. They
read its configuration, not a locking reload. No operation may lock a
conversation first and then ask for the ticket. Build a lock-order test from
the actual callbacks before adopting a specific Rails around_* callback.

1. Validate input shape and identify trusted actor. Resolve the desk from the
   ticket, never from model-supplied parameters. Prepare external file uploads
   before opening this transaction.
2. Start a whole-operation savepoint (`requires_new: true`) on the shared
   connection; obtain locks and reload the ticket/current actor eligibility.
3. Recheck the authenticated principal and current host read access to this
   ticket/result. Never trust console read-time permission.
4. Find a committed operation receipt for the supplied scope/key. Matching
   fingerprint returns its result without running policy or writes again;
   read authorization still applies. A mismatch raises IdempotencyConflict.
   For collection outreach, resolve its receipt before selecting/reusing an
   open case: its stable collection scope cannot change when that case closes.
5. For a new effect recheck current eligibility, host action authorization,
   binding and requester write availability. For automated actions validate
   turn, live claim token/deadline, activation epoch, policy version,
   evaluated permission fingerprint, optional host-context version, input
   revision and current state. Resolve the current policy under the lock.
   A changed dynamic decision is stale even if its named policy_version did
   not change; cap/authorization results may depend on live account state.
6. Execute record-only helpers: state, draft/review/message, counter, events,
   next work or intervention, receipt. All-or-nothing. Keys use a DB unique
   index as well as serialization. Unique violations are handled only after
   rollback to a savepoint; never query inside an aborted PostgreSQL transaction.
7. Commit; then broadcast and dispatch callbacks. If an outer transaction
   rolls back, no notification/work visibility survives. Dispatcher failure
   does not undo committed work and is recoverable through its durable row.

An assistant can carry the same key across queue retries without creating a
second draft, second note, second escalation, or second message. Withheld
outcomes write one bounded receipt/decision event, not one event per retry.

Config blocks run locally. The gem does not claim to serialize arbitrary
changes to host account/subject records. Hosts needing atomic coupling with a
business action must use that domain’s lock/version contract. At minimum
freshly recheck recipient/actor predicates at commit and compare an explicit
host_context_version when facts can change outside the ticket.

### 5.2 Incoming messages, revisions and work creation

For a managed support conversation the Chats subject wrapper owns:

1. Desk/ticket lock before message persistence and conversation denormalization.
2. Original Chats validations (membership, blocked state, attachments, locks).
3. A trusted support gateway context for any desk-authored assistant message.
   Without it a raw `desk.message!(..., author: rose)` or direct model create
   is refused. No boolean metadata or public `approved: true` grants this.
4. Message persistence, ordinary support clock folding and managed revision
   bookkeeping before the transaction commits.
5. For a new requester message: monotonic message sequence, last requester ID,
   incremented input/control revision, previous work invalidation and creation
   of at most one work row for the new opportunity. Newer input supersedes
   unstarted work; old running claims become obsolete.
6. Run deterministic hand_off_when before creating usable work. True imposes
   the requester requirement; false/nil proceeds. Invalid return/exception
   records a failed-hook requirement and suppresses autonomous sending. Run
   hook code in a savepoint so an error cannot poison the message transaction;
   preserve the requester’s message and leave a visible human task.
7. Emit the durable work signal after commit. No qualifying assistant => no
   automated work; an outstanding human requirement may allow draft-only work.

Exactly-once registration is by persisted message identity/receipt, not
created_at <= last_clock. Two distinct messages at the same timestamp, UUID
IDs, attachment-only messages and replay of older committed IDs all have
specified tests. Replayed message notifications do not increment revision or
create work again. Edits/deletes of context messages increment revision and
revoke pending approvals/claims; they do not reconstruct deleted text or count
as a new requester answer. Edits can create a replacement opportunity when
there is still an unanswered requester message.

Do not extend lifecycle role_of with human/assistant: clock folding still
sees desk messages as agent. Rich transcript roles are a different reader.
For managed tickets, incoming message order is transactionally serialized;
awaiting must reflect that order even under frozen timestamps. Timestamp SLA
fields remain timestamps; the sequencing/replay mechanism must not depend on
them. Preserve unmanaged ticket behavior until explicitly activated.

A successful domain command updates its own claim's accepted revision/token
through record helpers; the command's internal assignment, notice and reply
must not invalidate that same claim midway through the transaction. Only the
final committed revision is exposed. Other claims are revoked. No claim may
refresh across a different actor's committed change simply by fetching context.

The input/control revision covers externally relevant changes. An assistant's
own successful internal note/triage updates context and returns a successor
revision through its live claim without creating a new model-work signal.
`claim.context` after that operation advances only to its own recorded
successor; it cannot refresh past a different actor's intervening mutation.
A human note may invalidate AI context, but automatic work creation remains
conditioned on a genuine outstanding reply/assistance opportunity. No loop of
assistant note -> new work -> note. A claim's operations must sequence; two
parallel tools with the same old revision cannot both mutate unchecked.

Human assignment/reply, draft editing/rejection, pause/resume, requirement creation/resolution,
reopen/close, topic/subject/context change, identity change and desk activation
also increment revision/invalidate work. Duplicate no-op transitions do not.
A hand-back or resume on an awaiting case creates a fresh work opportunity;
merely waiting for another customer message would strand it.

A control-only revision without any requester input cannot invent an inbound
answer opportunity. Outreach has its separate operation (§5.9).

### 5.3 respond!, reply! and draft!

After the common gateway:

- If the opportunity has already been answered, refuse a new key; replay an
  existing key’s recorded result. A shared claim is not permission to produce
  an unlimited sequence of replies.
- off/observe without permission to draft => terminal withheld outcome.
- draft permission without independent sending => create proposal and mark
  work completed. No assignment, notice, unread change or SLA reply credit.
- reply/resolve plus remaining budget => guarded reply: claim own seat if
  needed, post required disclosure immediately before the message, send with
  authoritative provenance, fold clocks and increment the persisted lifetime
  assistant-turn counter once. Mark work answered and return Outcome.
- Budget exhausted => create the last proposal if permitted AND impose a
  max_turns human requirement, releasing AI ownership. Even an explicit
  reply! path enforces the budget (it refuses; cannot bypass respond!).

A reply result carries successor_turn for the state just committed. While the
same claim is live, it can perform one conditional close! using that token and
a separate key if policy is resolve and no new requester input has arrived since the
assistant’s answer. An answered claim permits finalization only, not another reply,
triage or new proposal. When its lease expires, finalize work as completed;
it is never retried as an unanswered turn. claim.turn supplies the same
successor for callers using direct reply! rather than Outcome-returning respond!. A closure race cannot erase a
committed reply or close a case after new requester input/human takeover.

Direct draft! uses the same validation, file handling, key and receipt logic
as respond!. It cannot accept missing tokens, supersede a newer proposal on
retry, or bypass access restrictions because the output is private. Explicit
private assistance on an unavailable requester requires host permission; it
never implies that publication is possible.

Before any proposal change, validate all body/files/sources/metadata. Then
supersede the old current proposal and create the new immutable revision
inside the same savepoint. Do not rescue RecordNotUnique and return nil or an
unrelated winner as “the draft.” Serialization gives deterministic outcomes;
conflicts are explicit errors. SQLite lock errors need bounded whole-operation
retry; do not assert that SELECT FOR UPDATE provides PG locking on SQLite.

### 5.4 Human review and publication

1. Authenticate fresh eligible human and authorize review/publish on this
   ticket. Off-duty console-equivalent restrictions apply to the new review
   API. Approval credentials are never model inputs.
2. Under common locks find draft scoped through ticket, then exact revision.
   Check operation receipt; then status, open ticket, contactable requester,
   target revision and reviewed_turn.
3. For send!, persist the human review and publish as the human atomically.
   For approve!, persist review only. For publish!, require that approval’s
   revision/context remains current and the reviewer still satisfies host
   authorization. Require publisher authorization separately.
4. Apply ordinary human reply policy; on an AI-held case authorized humans
   take over under every reply_policy, including assignee_only. On another
   human’s case assignee_only still applies.
5. Store immutable drafting/edit/review/publishing provenance in reserved
   message metadata and the review rows. Mark sent with message ID. Do not
   recompute stale? after changing status and mistakenly persist false.
6. Supersede other current proposals, invalidate obsolete AI work, update
   reply clocks and emit events only after commit.

Approved does not mean immutable forever: edit makes a new pending revision;
new input invalidates approval and shows review-needed. Background jobs may
publish an approved revision as the authenticated human command only after
rechecking current reviewer/publisher permission, context and availability.
A failed attachment/moderation/message validation leaves no partial approval
for send!, and preserves a pre-existing approval for publish!.

### 5.5 Human requirements, pause and explicit hand-back

Creating a requirement is one savepoint: validate actor, create/reuse the
active keyed requirement, bump priority once for that requirement, invalidate
AI publishing claims, release AI seat, persist decision, optionally post a
safe acknowledgement, enqueue human notification evidence. A missing or
failing optional acknowledgement must not lose a customer’s request; store a
rendering diagnostic and commit the requirement. It never asserts that a
human is online, assigned or about to reply if those facts are unknown.

The acknowledgement is a gem-controlled lifecycle system line, not arbitrary
AI output, and is explicitly permitted as part of imposing a human requirement
even at observe/draft level. It never contains the internal summary by default
and does not count as a support reply or reset a human wait clock.

A human-held case keeps its human holder. Several reasons remain separate.
Customer-button repeat is idempotent by active requirement key. A distinct
new specialist/policy requirement cannot be discarded because a generic
human_required flag was already true.

request_human! authenticates this requester, locks, rechecks contactability,
and if permitted reopens then imposes the requirement in the same transaction.
On locked closed cases, do not reopen: present the existing authorized route
to a new support case/contact path. The door does not promise an action the
model will refuse. Requester cannot resolve requirements or alter autonomy.

pause_assistant! disables AI on the case and fences work; it does not erase
previous drafts or evidence. Their publishability is decided by review policy,
not by whether generation is currently paused. resume_assistant! clears only
pause and, if eligible/awaiting, records fresh work. It does not clear the
reopen cap or any human requirement.

resume_automation! is the explicit human hand-back command. Validate the
requested changes against a hypothetical resulting policy BEFORE mutating,
then apply them and assignment atomically. This avoids the original deadlock
where a paused/human-required policy refused assignment before it could be
cleared. It also avoids clearing every restriction just to make assignment
pass. Require named requirements and a resolution reason; no wildcard clear.
A failed topic/host ceiling check rolls back all attempted relaxations.

### 5.6 Triage and closure

An AI may propose reclassification through its harness; applying it requires
the explicit triage capability and host target authorization. Compare both
old and resulting policy. Persist the old restrictive cap on the case until
an authorized human resolves that restriction, so moving money -> app cannot
make the next reply autonomous. The host should also derive hard restrictions
from subject/account facts rather than only a mutable label.

If resulting policy cannot hold a case, release the AI seat in the same
transaction and record why. Private drafts can remain. Configuration changes
and external host-fact changes are detected on commit and reconciliation; do
not promise an immediate invariant merely from a Ruby initializer edit.

close! explicitly checks automation envelope, assignee, no unanswered input,
no human requirement and resolve permission. Any close expires current drafts
and invalidates work/approvals. Historical closed_by_kind records the actual
closer even if the assignee was different. Reopening after an AI close sets a
separate draft ceiling (never raises an existing off/observe cap), leaves the
case unassigned, preserves lifetime max_turns and unresolved requirements.
Human close/reopen retains legacy human assignment semantics.

### 5.7 Liveness, retries and timeout recovery

Work is persisted at input registration, before an assistant has a seat.
Due_at is based on the first unanswered work in the current wait episode;
new customer messages/retries do not continually postpone that deadline.
A new episode after a real support answer receives a fresh deadline. A
manual private-draft request has its own deadline without resetting an
outstanding requester episode. When responds_within is nil, lease expiry
still works and pending age is reported, but there is no implied timeout
fallback; the host deliberately chose to supervise that backlog itself.

The maintenance scan supplies candidates only. Under each candidate’s locks,
re-read work status, deadline, claim token, current awaiting state, current
principal, assignment ID and eligibility. Release only the matching AI seat
when it is still the affected case. A human takeover or answered message
between scan and lock makes that candidate a no-op. Increment result counts
only when a transition committed.

Overdue pending/running work, invalid active seats, or a permanently failing
harness produce a human requirement, invalidate claims and release AI
ownership. This also covers unassigned draft-only cases. Merely releasing a
seat is insufficient: a delayed worker could otherwise take it back.
Deactivation/config removal is handled even with responds_within nil.
Paused/inactive work cannot be claimed; expired claims may be reclaimed only
while their opportunity remains current and before the original deadline.

Re-dispatch reads durable pending work even if every original enqueue callback
failed. Signals are at least once; claims and receipts suppress duplicate
effects. A successful enqueue is not proof of execution; pending age remains
observable. Host scheduling interval adds to timeout latency: default three
minutes plus up to one sweep interval, not an exact three-minute guarantee.

### 5.8 Disclosure and metadata

Create notice and first message in the same transaction. Use a stable
message sequence on managed tickets, so opening line -> disclosure -> reply
is deterministic even with frozen timestamps and UUIDs. A notice receipt is
keyed by ticket, assistant identity and disclosure version, not a single
boolean for every persona forever. Replays never duplicate it. Required notice
rendering failure refuses the autonomous send and leaves recoverable work;
it does not publish an undisclosed message silently.

Signature modes are historical snapshots. All requester templates consult the
presentation seam; staff-only robot/proposal/confidence marks stay staff-only.
Do not reintroduce identity through assignment announcements on unsigned modes.
Human-reviewed content uses the human signature and internal provenance.

Reserved metadata namespace: support_desk. The gateway writes actor kind/key,
assistant key, disclosure snapshot, turn, operation ID, draft/revision/review
IDs and policy decision. Host metadata nests under host; reject attempts to
supply reserved keys. Metadata is JSON with explicit size/depth limits; sources
are bounded objects with title and optional http/https URL and document/version
reference. Concrete defaults: at most 20 sources, title <= 500 characters,
URL <= 2,048 characters, host metadata <= 32 KiB serialized UTF-8 and depth <= 8.
Host context defaults to <= 64 KiB and transcript page maximum 200 messages;
reject explicit oversized requests rather than silently deleting content.
A transcript reaching the bound returns cursors/truncated. Draft body/files
use the existing Chats limits. Policy/context serialization has its own
allowlisted keys, not the arbitrary host metadata budget. No javascript/data URLs; escape titles/notes in every template.
Confidence is untrusted reported metadata, never an authorization threshold or
an “accuracy” badge. No hidden reasoning/prompt required in stored notes.

### 5.9 Outreach

No-message requester cases do not create an artificial turn. Assistant
outreach is a separate authorized collection operation, default disabled.
`Ticket.open!`/agent sugar gain `idempotency_key:` for AI outreach and run the
same policy gateway; an internal gateway-generated outreach token is bound to
requester, desk, topic and subject. A caller cannot use nil turn on reply! as
an outreach escape hatch.

Validate collection authorization, current AI/recipient eligibility, desk
binding, contextual topic/subject caps and may_open_conversations before any
insert. Then under the existing create-or-reuse serialization, re-evaluate
policy on the actual target. A reused human-held or restricted ticket cannot
be contacted independently by exploiting the new-case path. AI outreach into
an existing awaiting-requester case requires a separately authorized outreach
opportunity; the public default refuses it rather than bypassing one-reply
semantics. Return existing receipt on retry, even if the original ticket was
subsequently closed; never create another outreach case for that key.

New-case outreach seats the AI with the existing opened reason, records
provenance and counts its autonomous message toward max_turns. Required opening
and disclosure lines are serialized before the text/files. Entire operation
rolls back on failure. No requester-turn event fires until the requester speaks.

## 6. Schema and migrations

The earlier “exact template” was unsafe: it used today’s generator PK setting
for existing foreign keys, silently adopted colliding columns/tables, put an
object default on an array field, and left non-null stale pointers untouched.
Use this schema contract plus executable adapter migration tests; do not copy
that template from commit d9ff5c5.

### 6.1 Persistent structures

All ordinary rows have PK/timestamps; immutable revisions/events have created_at
only where appropriate. Actor pairs are all-null or complete; constrain both
halves. JSON object defaults are {}, array defaults are []; on MySQL use Ruby
defaults where SQL JSON defaults are unsupported. All ID types below come from
the referenced existing column, not current generator flags.

| Table | Required fields / constraints |
|---|---|
| support_desk_assistants | key unique/nonblank, active, control_version bigint default 0, settings object, persisted presentation fallback |
| support_desk_automation_controls | desk_id unique FK, enabled default false, epoch bigint, policy_version, assistant actor pair/key; runtime disable visible cross-process |
| support_desk_assistant_work | ticket FK, actor pair/key, input revision, requester message ID, purpose, trigger_type/trigger_id, generation, activation epoch, policy/context versions, permission fingerprint, turn digest, status, due_at, attempts, claim digest/expiry, accepted revision, result receipt ID, last failure code; unique opportunity identity |
| support_desk_operations | ticket nullable only for outreach, actor key, action, idempotency key digest, request digest, outcome/result references, decision snapshot; unique actor/action/scope/key; collection scope includes validated recipient/desk |
| support_desk_drafts | ticket FK, original author pair/key/kind, status, current_revision_id, sent_message_id, sent_review_id, published_by actor pair, published_at, created_at; one current pending/approved per ticket where partial indexes supported |
| support_desk_draft_revisions | draft FK, number, author/editor pair, body, base ticket revision/turn digest, confidence decimal, sources array, metadata object, policy snapshot; unique draft/number; immutable; attachments through ActiveStorage |
| support_desk_draft_reviews | draft/revision FKs, reviewer pair, reviewed ticket revision/context, decision, reason, policy snapshot, expiry, created_at; immutable; publication references exact review |
| support_desk_human_requirements | ticket FK, key, generation, reason_code, internal summary, requested_by pair/key, requested_at, allow_assistance, resolved_by pair, resolved_at, resolution_reason, host reference; one active key per ticket under lock/index |
| support_desk_chat_registrations | ticket FK, message ID unique for create, sequence bigint, created_at; unique ticket/sequence; identity receipt for replay/timestamp ties |

Ticket additions: assistant_managed boolean false, assistant_revision bigint 0,
last_requester_message_id (Chats PK type), assistant_turns_count nonnegative
integer 0, assistant_paused_at/reason, assistant_reopen_cap nullable enum,
assistant_case_cap nullable enum + reason, cached human_required_at nullable,
assignee_kind and closed_by_kind snapshots. If a separate human wait clock is
stored, human_waiting_since derives from unresolved requirements and clears
only on their explicit resolution, not on an automated acknowledgement.

Presentation/provenance snapshots live in reserved Chats message metadata.
Existing assignment reason values remain; use release_reason released or
escalated and record recovery reason in its event. Do not add
assistant_silent merely to encode a timeout; the reason detail belongs in the
new operation/event. Work statuses: pending, running, answered (finalization
only), completed, superseded, failed. Claim tokens are stored hashed; return
plaintext only to the authorized claimant. Raw model text is not a key.

Receipts and review evidence use restrict/durable references rather than
cascade-destroying history through ticket associations. Retention/export is a
host policy with explicit tasks; deactivating an assistant never deletes its
messages/drafts. Failed temporary uploads follow host cleanup policy and do
not purge attachments referenced by published messages.

Automatic work opportunity identity is ticket + assistant actor + purpose +
trigger_type/trigger_id (a requester message or control-operation receipt).
Intentional human regeneration uses its unique request receipt as the trigger;
a retry returns that work, a new key creates another generation and supersedes
the older opportunity. Generation and accepted revision are not conflated.
All IDs compare as stable opaque values; no monotonic UUID assumptions.

Indexes include ticket+status/created_at on drafts/work, pending due_at on work,
actor key/status for metrics, unresolved requirements by desk/ticket, and the
unique receipt identities. Add MySQL fallback lookup indexes. All supported
writes serialize using the existing parent ticket row; a uniqueness error is
not a “belt” on an adapter without that unique index. PG and SQLite must have
race tests; do not claim tested MySQL concurrency until it has a matrix leg.

### 6.2 Migration ownership and compatibility

- Install and upgrade copy one additive owner migration, plus its tested
  catch-up task. Keep generator/dummy/schema assertions in agreement.
- Preflight names before any DDL. Preexisting partial tables/columns with
  unknown ownership cause a descriptive MigrationError; never silently skip
  them and later drop them in down. Rails schema_migrations provides normal
  once-only execution. For nontransactional DDL document reconciliation after
  a partial failure, including validating types/indexes before marking applied.
- Derive ticket FK from support_desk_tickets.id, message FK from
  chats_messages.id and polymorphic actor type from existing agent/author
  columns. Verify compatibility for a built-in persona with the host’s
  polymorphic storage; reject unsupported mixed UUID/bigint actor storage
  rather than guessing or coercing IDs. New internal PKs can follow the
  existing gem PK convention after this verification.
- Backfill in bounded SQL batches with no current model callbacks. Newest
  message lookup uses ORDER BY created_at,id, never MAX(uuid). This is a
  deterministic historical approximation, not inferred real-time causality
  for old frozen timestamps. Initialize sequence receipts from that order;
  all future managed writes have authoritative transactional order.
- Catch-up repairs non-null stale pointers after old writers drain, locks
  candidates and never rewinds a newer managed registration. Include text
  with files/no body, missing/deleted message references, empty conversations,
  legacy closed cases and older rows. Compare full observed state, not just
  WHERE last_requester_message_id IS NULL.
- Before enabling a desk, validate the full schema and backfill generation;
  initialize managed state/receipts and queued unanswered opportunities in
  batches. Activation must cover existing tickets and future opens without a
  gap. No old code may be live when activation begins.
- Down is schema-only rollback before feature activation. After messages,
  approvals or work exist, raising IrreversibleMigration is preferable to
  destroying evidence. Code rollback is §13; dropping tables is not a rollback
  strategy for deployed autonomous support.

### 6.3 Locking and migration test requirements

Test fresh install + real 0.2 schema upgrade on bigint and UUID, including
changing generator primary_key_type since install. Assert column SQL types,
FKs, object/array defaults, indexes and whole actor pairs. Test collision
refusal before destructive writes, repeated generator invocation, batch
resume, old-process writes after schema expansion and final catch-up. Run
PostgreSQL transactions after intentionally injected uniqueness violations
to prove savepoint recovery, not just source-text assertions.

## 7. Console, requester and queue surfaces

### 7.1 Console contract

Existing authentication, visible_desks_for, authorize_console and scoped ticket
lookup remain mandatory. The model’s authorize_support adds protection for
jobs and alternative UI, and is composed rather than substituted. New actions
are send_draft, approve_draft, publish_draft, revise_draft, reject_draft,
pause_assistant, resume_assistant, resolve_human_requirement, resume_automation.
Map routes and OFFERED_AS from one table as the current console does.

All mutations are POST/PATCH with CSRF protection, scalar/type validation and
explicit strong parameters. by/reviewer/actor/desk is server-resolved. Draft,
revision, approval and requirement are scoped through the authorized ticket.
No arbitrary GlobalID lookup from a model response or browser parameter.

| Action | Required input |
|---|---|
| send_draft | draft_id, revision, reviewed_turn, idempotency_key |
| approve_draft | same; optional host expiry policy, never caller-defined bypass |
| publish_draft | draft_id, approval_id, idempotency_key |
| revise_draft | draft_id, expected_revision, body, explicit attachment edits, idempotency_key |
| reject_draft | draft_id, revision, idempotency_key; optional reason |
| pause/resume | idempotency_key; reason for pause optional |
| resolve requirement | requirement_id, reason, idempotency_key |
| resume automation | named requirement IDs, explicit cap/pause choices, reason, idempotency_key |

Generate stable per-form keys; a double submit uses the same key. A deliberate
new action uses a new key. On a stale context/refusal preserve text and explain
what changed; browser file inputs require reattachment. Do not auto-set a
stale override hidden input based on the old page. For new review endpoints,
success is 303, recoverable validation/conflict renders 422 with the draft,
unauthorized is 403/404 according to host policy. Existing legacy transition
flash behavior remains unchanged. A replayed send resolves the sent draft
through ticket.drafts, not a pending-only lookup that rejects every retry.

Partial contracts:

| Partial | Inputs and behavior |
|---|---|
| _draft | draft, current revision, review state, current context token, actions; staff-only body/files/sources; show stale reason; edit/reject/approve-send |
| _composer | optional draft revision; editing saves a revision then sends that exact revision, never silently falls back from blank text |
| _review | pending/approved/stale decisions, reviewer identity, exact content revision and current conversation |
| _actions | pause vs resume separate from return-to-automation; explicit unresolved requirements and allowed resolutions |
| _assignment | actor-key values; validated eligible targets; no personal AI signature leakage on requester surfaces |
| _context_card | staff support_context plus effective policy/reasons, not a claim those fields go to AI |
| _timeline | immutable draft revisions/reviews/interventions and ordinary events; internal only |
| _ticket_row | human-required/review-ready/automation-overdue badges; preloaded associations, no policy query per row |

Add Timeline::Entry#draft?, #review?, #requirement? plus referenced object and
stable sequence. Existing #message?/#event? stay compatible. New entries are
staff-only; requester export remains separate. Summary gains human-required
and review state without replacing actual awaiting requester/desk semantics.

Picker values are existing SupportDesk.actor_key (GlobalID parameter, not a
new hand-built encoding). Resolve by exact key from the authorized eligible
pool. Accept legacy bare IDs for one release only when exactly one scoped
candidate matches; support UUID as well as numeric IDs. An inactive actor is
historically renderable but not selectable. Reject an ambiguous or unlisted
key even if it is a valid global ID elsewhere in the application.

### 7.2 Requester door

`POST /tickets/:id/request_human` in the engine scopes through the current
requester’s tickets, rechecks eligibility, invokes the domain method and
redirects 303 into the authorized thread. Same request twice returns success
without duplicate notice/page. Foreign ticket ID yields 404.

Render the door from `human_request_available_to?`, not may_draft? or
assistant_policy. Pausing/removing/deactivating AI cannot hide the exit from a
customer who has interacted with it. Default: show on configured desks and
historically assisted cases where the requester has an actionable support
path. While a requirement is pending, show its status rather than silently
rendering nothing. Closed locked cases show the permitted alternative support
route; no fake button that can only raise Locked.

The shipped Chats thread gets the composable subject slot (§4.11). Ejected
views use the same helper and policy. Test both, plus Turbo and native redirect
behavior; do not assume a new POST is covered by an old native route fixture.
A visible door is available independently of phrase recognition. The phrase
hook is optional; translated “type human” promises must not appear when no
phrase handler is installed. Generic copy says to use the displayed button.

### 7.3 Review and human queues

Show pending/approved review work, unresolved human requirements and overdue
assistant work independently of who owns the ticket. Preload current draft and
requirement summaries; aggregate counts portably without PG-only JSON SQL.
Keep default human-only tabs unchanged; feature tabs appear when configured or
when persisted work still exists after config removal. A disabled assistant
cannot make pending reviews/requirements disappear. Pagination/tenant scope
applies to every relation and count. Human wait age is not reset by an AI note,
draft or acknowledgement. Queue#next orders urgency but does not claim work.

## 8. Localization and rendering

Both en and es ship the same key set and interpolation variables. Names,
reason codes and action labels are separated from English policy descriptions.
Persist machine reason codes + parameters; localize because at render time.
No special exception permitting an English error inside every Spanish flash.

Required key families:

- assistant identity/disclosure modes and unknown/deactivated historical actor;
- generic human request acknowledgement, already-requested status, no available
  person promise, unknown response-time variant;
- draft revision/review, stale due to context vs edits, approval/publish/reject;
- pause/resume and independent human/reopen restrictions;
- conflict/retry/claim/stale/policy/input errors;
- queue tabs/badges and operational timeout/failure descriptions;
- internal timeline decisions and source/attachment labels.

Reference Spanish copy (English equivalent required):

```yaml
es:
  support_desk:
    assistant:
      disclosed_name: "%{name} · asistente virtual"
    system:
      assistant_disclosure: "%{name} es el asistente virtual de %{desk}. Puedes solicitar atención de una persona con el botón de esta conversación."
      human_requested: "Hemos recibido tu solicitud de atención de una persona del equipo."
    console:
      draft:
        stale: "La conversación o la propuesta ha cambiado. Revisa la versión actual antes de enviar."
        reported_confidence: "Confianza declarada por el asistente: %{percent} %"
      actions:
        send_draft: "Aprobar y enviar"
        approve_draft: "Aprobar sin enviar"
        resume_assistant: "Quitar pausa"
        resume_automation: "Devolver al asistente"
```

No default confidence quality indicator in the requester UI. Staff confidence
is optional/clearly labeled uncalibrated metadata. Source titles, summaries,
filenames and bodies use ordinary escaping/sanitization. Accept only safe URL
schemes; do not fetch source URLs while rendering. Attachment thumbnails test
renderability, not merely presence. Built-in views are accessible (button
labels, errors associated with fields, focus after validation) and usable on
mobile without hover-only information.

## 9. Host integration and generator

### 9.1 Contract

1. Subscribe to durable work signals and/or poll pending work; enqueue a work
   ID, never serialize an AR object or a prompt into the event.
2. Atomically claim current work. A completed/leased/stale opportunity is a
   normal no-op, not an excuse to steal its lease.
3. Fetch authorized bounded context bound to that claim. The host chooses
   whether to include internal information and what provider receives it.
4. Run any harness outside locks. Host tools authenticate as the fixed agent
   principal; model arguments cannot change actor, scope, approval or policy.
5. Commit explicit actions using the claim, turn and stable per-action keys.
   The host may use several tools; each must return successor context when
   it changes relevant state. Re-read when needed. There is no “exactly one
   tool call per run” requirement.
6. Handle stale/revoked/denied outcomes without retrying an obsolete answer.
   Record retryable execution failure or deliberate no-action through claim
   APIs. Let the original deadline control escalation.

A generated adapter is an example, not a required Answer superclass or a
protocol every external workflow must adopt. Ruby, JSON transports or tool
adapters can all use the same domain surface. Human approvals persist in the
gem even when a provider process restarts. Model trace/checkpoint storage stays
in the harness.

### 9.2 Generated job shape

The generator emits a name-specific job/service (RoseTurnJob and Rose), avoids
overwriting existing files, and binds the job to the expected assistant key.
Multiple configured desks may share it. Example body:

```ruby
module Support
  class RoseTurnJob < ApplicationJob
    queue_as :support

    def perform(work_id)
      work = SupportDesk::AssistantWork.find(work_id)
      rose = SupportDesk.assistant(:rose)
      claim = work.claim!(by: rose)
      context = claim.context
      answer = Support::Rose.answer(context)
      ticket = work.ticket
      key = "work:#{work.id}:answer:v1"

      case answer.kind
      when :answer
        ticket.respond!(answer.text, by: rose, turn: context.turn,
                        claim: claim, idempotency_key: key,
                        sources: answer.sources, metadata: answer.metadata)
      when :hand_off
        ticket.escalate!(by: rose, reason: answer.reason,
                         summary: answer.summary, turn: context.turn,
                         claim: claim, idempotency_key: key)
      when :nothing
        claim.complete!(reason: answer.reason, idempotency_key: key)
      else
        raise ArgumentError, "unsupported answer kind"
      end
    rescue SupportDesk::WorkUnavailable, SupportDesk::StaleTurn
      # No current work remains for this attempt; the durable row explains why.
    rescue SupportDesk::AssistantNotAllowed, SupportDesk::Locked => error
      claim&.fail!(code: :no_longer_allowed, retryable: false)
    rescue StandardError => error
      claim&.fail!(code: :harness_failed, retryable: true)
      raise
    end
  end
end
```

Generator tests must exercise the rescue paths against completed/revoked
claims: fail! on a no-longer-current claim is a no-op that cannot overwrite a
new owner’s result. Preserve/report original exception; reporting failure
cannot replace it. Active Job does not promise automatic retries merely because
a job raises; the template explains where hosts configure retry_on/queue
policy. Idempotency keys remain stable across queue retry attempts. If the
provider can produce different text on replay, retrieve an existing committed
result or cache the proposal before retrying that mutation; do not send a
new payload under an old key and ignore IdempotencyConflict.

Provider-blank service returns an application-owned object with kind, text,
sources, metadata, reason and summary. Default implementation raises
NotImplementedError; no empty-success stub that strands work. Generated test
stubs it, verifies draft/send modes, lost enqueue recovery, stale/human-takeover
refusal and same-operation replay. Tests never call a live model.

### 9.3 Generator options and initializer

`rails g support_desk:assistant Rose --desk default --disclosure signature`
requires an explicit disclosure option before modifying files. Missing option
prints choices and exits without inserting a nil setting that breaks boot.
Options include autonomy (draft default); validate name/constant/key/desk and
all enums before writes. Render fragments only inside a known configuration
block or print a standalone configure block; never blindly append Ruby to an
unknown initializer scope. Do not copy the gem’s locale catalog into the host;
write only deliberate host overrides to a separate namespaced locale file.

Generated subscription uses the existing module API and reload-safe key:

```ruby
SupportDesk.on(:assistant_work_available, key: "support.rose.work") do |work|
  Support::RoseTurnJob.set(wait: 20.seconds).perform_later(work.id)
end
```

`config.on(event, &block)` already exists and delegates to SupportDesk.on,
but currently does not forward key:. The keyed module form above is available
today. If adding `key:` forwarding to config.on, test and document that
backward-compatible extension. Durable dispatch/reconcile recurring
jobs are shown using wrappers around the task methods; the host selects its
scheduler. Supply both Solid Queue and cron examples with actual task names.

## 10. Disclosure, privacy and authorization

### 10.1 Disclosure

Preserve explicit disclosure choice (#22). No legal assertion, effective date
or compliance guarantee is hardcoded into a gem README. The host determines
its obligations in its legal process. The gem documents exact visible behavior
and data provenance. None mode causes no warning and no automatic robot marks
in requester-facing templates; staff still see the actor’s kind. Historical
presentation remains stable; explicit retroactive redaction/migration is a
separate host action, not a side effect of a config edit.

### 10.2 Authorization boundary

Authorize reads and writes using authenticated principal, tenant/desk/ticket
and action/resource, including approval and attachment download. Configured
agent pool is not tenant authorization. Human approval cannot grant a tool
permission to refund money or modify a ride; those belong to the host domain.
External action approvals may be linked through host_reference, but the gem
never executes arbitrary approved JSON. An approved reply promising a refund
is still not evidence that a refund happened.

Prevent AI from reaching human/system-only tools in host adapters. The library
is not a sandbox for arbitrary Ruby/SQL with application credentials. Do not
claim that hiding a button or omitting an AI tool alone enforces the domain
policy; model methods and supported Chats writes enforce it too.

### 10.3 Private content and exports

Context payloads do not themselves leave the application. The host sends only
explicitly selected fields to its chosen provider. Human console facts are
not automatically provider context. Internal notes, drafts, source metadata,
review reasons and escalation summaries are opt-in for model context and
excluded from requester exports, public broadcasts and notifications by default.

Requester export uses stable publication provenance for assistant vs support,
including deleted/deconfigured actor fallbacks; human-approved drafts remain
support under #20. Export lifecycle events through a positive allowlist and
per-kind safe mapping (kind/at plus intentional user-visible fields), never
raw summary/policy/request metadata. No full internal timeline serialization
through the public thread slot or unscoped attachment URL.

Metadata size limits and structured source validation protect persistence/UI;
they do not prove factual accuracy. Host retrieval must scope product records
to the authenticated requester and allowlist published documentation. No
automatic filesystem/repository ingestion. HTML escaping, URL filtering and
file authorization are mandatory for reviewer UI as well as requester UI.

### 10.4 Moderation and audit

Chats reported_owner is author || sender; an assistant author is not a User.
CarHey’s host bridge must provide a valid accountable moderation subject under
its actual Moderate contract, not assume nil is accepted or impersonate an
arbitrary human. Test report creation, staff rendering, review and takedown.
Do not silently exempt assistant messages from reporting/moderation.

Every stateful assistant/review action stores its decision within the same
transaction. ticket_transitioned is a post-commit notification, not durable
external audit delivery. A host requiring guaranteed audit mirroring polls
operation/event rows with its own acknowledgement cursor or an outbox consumer;
subscriber exception isolation alone is insufficient. Do not store provider
secrets, unredacted request headers or a required model reasoning trace.

## 11. Evidence and operations

### 11.1 Persistent decisions

| Object | Evidence |
|---|---|
| Operation receipt | actor/action/key digest, payload digest, policy/version/constraints, exact result |
| Work | trigger, original deadline, attempts, claims, supersession, failure/outcome |
| Draft revision | original content/files, sources, context revision, author/editor |
| Review/publication | exact revision/context, human reviewer and publisher, sent message |
| Requirement | reason, requesting principal, internal summary, resolution and authority |
| Message | author/sender plus immutable attribution/disclosure, drafting/review provenance |
| Ticket transition | prior/resulting state, why permitted and what work was invalidated |

`claim.complete!` records a bounded reason code plus optional host detail.
For observe/manual-draft work, an intentional no-action may complete while the
case stays in the human queue. For an autonomous inbound opportunity still
awaiting a reply, no-action must leave a human requirement (or an already
existing one), never mark the customer's need answered. “Already handled” is
accepted only when current persisted state shows it was handled. Notes alone
do not finish inbound work; the host explicitly completes/escalates it. This
prevents a provider's :nothing from removing the only timeout/recovery signal.

Keys, tokens and IDs are distinct: never use a timestamp, model confidence or
current message count as a “unique run.” Actor keys use the existing helper;
model class IDs alone collide. Structured telemetry contains IDs/reason codes,
not full message bodies by default.

### 11.2 Health checks

Doctor is diagnostic and may query. It cannot certify prompt accuracy or the
presence of an external worker merely because a callback exists.

| Check | Failure/warning conditions |
|---|---|
| schema/activation | Missing columns, incompatible types, activation with unfinished backfill or policy-version mismatch: fail |
| identity/binding | Unbound AI, wrong desk binding, invalid fallback rendering, removed active principal: fail for new actions; history remains readable |
| authorization/door | Missing host integration checklist/door coverage: warn; invalid local contract: fail |
| pending work | Overdue unclaimed/running work even on unassigned cases: fail |
| dispatcher/reconciler | Last successful sweep/dispatch beyond configured monitoring interval: fail; no registered dispatch and no declared polling integration: warn |
| seats | AI holds human-required/paused/unavailable/restricted case: fail |
| drafts/reviews | Multiple current proposals, current draft on closed case, approval referencing wrong revision/message: fail |
| receipt integrity | Duplicate opportunities/operations or result reference corruption: fail |
| configuration | Unlimited turns/disabled deadline: warn with consequence; disclosure none never warns |

A sweep releasing work does not erase the unresolved human requirement or
failure evidence. Doctor/status should distinguish recovered automation failure
from still-unhandled human work. Schedule health checks independently from the
harness they monitor.

### 11.3 Metrics

Document definitions rather than call two raw counts “containment.” Minimum:
reviewed proposals, verbatim/edited/rejected outcomes, denominator-zero => nil;
time to first published support reply, time to first human reply when required,
oldest unresolved human request, pending/overdue work, stale/revoked commits,
reply duplicates prevented and timeout recoveries.

A containment cohort needs explicit observation window and no human takeover,
intervention or reopen within that window; closed_by_ai alone is only a count
of AI closures. Draft acceptance is a workflow signal, not factual accuracy.
Human review of a draft is not an autonomous resolution. Do not choose an
80% acceptance threshold as a production safety guarantee. Correctness and
customer outcomes need a host-owned evaluation set and review process.

Avoid PG-only payload->> aggregation in public “portable” snippets. Date windows
and cohorts are explicit. Existing Ticket.closed_between(range) is usable,
but does not itself supply a containment cohort or observation window.
Counter increments are transactional and idempotent; budgets survive reopening
and reconfiguration unless an explicit authorized policy change says otherwise.

## 12. Acceptance tests

Tests below are executable implementation gates, not assertions that this
review has run runtime tests for unimplemented features. Use current repository
CI matrix when implementing; do not freeze an old test count, coverage value,
PR number or “one hour” estimate as acceptance evidence.

### 12.1 Compatibility / I01

No assistant configured: full request/reply/assign/close/reopen scenario,
ordinary Chats and support exports, exact existing human offered-action sets,
no AI tables read on hot paths unless persisted feature state requires it,
no extra default tabs, no notices/work/events. Explicit new human requirement
works without a persona. Record documented SQL/schema changes separately.
Existing human-only hosts with UUID picker IDs remain usable.

### 12.2 Policy / I02–I03, I09–I10

Exhaustively test all five presets × relevant state/holder × topic ancestry ×
host cap × pause/reopen/requirements, including unknown topic and null desk
binding. Verify all constraints/reason codes, not prose fragments. Parent cap
cannot be raised by child; moving payment to app cannot lift case restriction.
Custom AI model, unbound AI, inactive assistant, wrong desk identity and symbol
actors hit every verb. Off-duty/revoked human cannot approve/resume. Host
read/write/tenant authorization applies outside HTTP and through console.
A host allow result cannot override gem safety invariants. Mixed configurations
with one disabled desk must not resolve the default persona accidentally.

### 12.3 Transactional messaging / I04–I07, I15

PostgreSQL multi-connection barrier tests, SQLite busy/retry tests:

- Requester commits message while AI is generating, and while AI commit waits
  for the lock: old result refused, new work discoverable.
- Human takes/releases/replies then returns case: old work remains fenced even
  when final assignee/input ID happens to match the old values.
- Distinct same-timestamp requester messages, UUID ordering and redelivery of
  old callbacks: every new input observed once, no clock/token rewind.
- Edit/delete context through normal Chats APIs invalidates approvals/work.
- Raw desk.message!(author: ai), conversation.messages.create!, update/delete
  and alternative Ticket verbs cannot bypass policy/provenance.
- Two workers claim same opportunity: one live claim; expiry/reclaim fences old
  token; same key replays same result; different payload conflicts.
- AI reply max_turns budget on respond!, reply! and outreach; no duplicate
  budget increments on retries or callbacks.
- Failed send/files/moderation/notice/receipt creation rolls back all effects,
  including inside an outer transaction that rescues the error and commits.
- Rollback emits no callback; failed callback leaves durable work to redispatch.
- Actual lock-order test exercises requester, AI, human review and takedown,
  with bounded timeout and assertion of no deadlock rather than indefinite join.

### 12.4 Review / I08, I14

Attachment-only proposal, invalid files preserve previous draft; immutable
revisions and all review states. Edit invalidates approval; blank edit does
not silently resend original. Send/reject/revise/close races have one valid
outcome. Double send with same key returns same message; foreign draft/review
IDs rejected. New context after review rejected; explicit review of current
context may send old text deliberately. Human plain reply supersedes proposal.
Paused generation does not delete a human’s pending review. Off-duty/cross-tenant
reviewer/publisher and AI pretending human denied. Direct send on closed
reopen_on_reply case refused. Export and every requester surface lack draft
content, private files, source metadata, notes and internal summaries.

### 12.5 Intervention/control / I09–I11

Multiple independent requirements, repeated button vs new reason, resolve one
without clearing others. Hand-back refusal leaves flags intact; explicit
allowed hand-back can clear named soft restrictions but cannot clear host hard
caps. Pause/resume preserves reopen cap, which preserves stricter observe/off.
AI cannot clear its own restriction by reclassifying, altering metadata,
reopen, symbol actor or selecting a human recipient. Reopen uses closer kind,
including AI closer with non-AI assignee and deleted/deconfigured closer.
Requester request plus reopen is one atomic operation. AI timeout acknowledgement
does not count as human reply. Door remains visible when paused/deactivated or
configuration removed; closed locked route offers actionable alternative.

### 12.6 Reliability / I12

Fail initial enqueue and kill a worker after model call, before domain commit,
after commit before acknowledgement, and during finalization. Polling discovers
work; receipt replay yields no duplicate. Unassigned draft work times out.
Continuous customer messages and retries do not reset first-unanswered deadline.
Sweep candidate then human takes/replies before lock: no release/counter/page.
Inactive/removed principal recovered even with no timeout. Old worker after
recovery cannot retake case. Reconcile/dispatch repeat with no extra pages.
Hook exception preserves requester message, creates diagnostic/human fallback
and never proceeds autonomously. Config cap error is observable on a pending
opportunity even if no callback succeeds. No subscriber is not proof of failure
when a documented poller is active; oldest work is the evidence.

### 12.7 Identity, presentation, outreach / I13, I16

Every disclosure mode across bubbles, rows, assignment announcements, notices,
exports and staff UI. Rename/remove config/deactivate actor keeps old messages
readable and correctly attributed. Required blank notice refuses autonomous
send. Frozen timestamps preserve opening/disclosure/message order. New identity
or disclosure version gets its intended notice once. Human-approved content
has actual human author and AI provenance. Custom kind: :ai behaves identically.
Outreach hard caps, host recipient/subject authorization, old-ticket reuse,
insert-loser path, idempotent retry after closure and counter/disclosure parity.

### 12.8 Context/UI/generators / I14, I18

Snapshot revision consistency under concurrent edits, bounded lists/cursors,
tombstones, no tokens/secret URLs/private facts by default. include_internal
requires authorization. Transcript system role is not promoted into provider
instructions; user text containing “You are” is preserved as untrusted data.
Safe source URLs and escaped content; attachment renderability failures do not
crash review pages. Locale key/interpolation parity, Turbo 303/422 draft
round-trip, CSRF, stale form, mobile/native requester door. Actor-key collision
with User#1/Assistant#1 and UUID bare IDs. Generator idempotence, no malformed
initializer/YAML appends, missing required option causes no writes, multiple
assistant names do not overwrite another job. README examples execute against
stub harnesses; API signatures are checked against implementation.

### 12.9 Migrations/rollout / I17

§6.3 plus a mixed-version process test: expand with automation disabled;
0.2 writer adds message; catch-up repairs pointer; 0.3 activation creates work
for outstanding cases. Reject activation before drain/catch-up. Test nil vs
explicit disabled desk, policy version change and obsolete queued job args.
Code rollback rehearsal retains schema/evidence and disables old queued AI
jobs; no claim that adding nullable columns makes mixed AI writers safe.

### 12.10 Repository gates

Run current supported SQLite/PG × Rails Appraisals, rubocop/security checks and
system suites appropriate to each implementation PR. Report actual versions,
heads, database isolation and commands. Tests are required for policy/control
mutations and races; no implementation-mirroring tests merely to raise counts.
For MySQL, explicitly list untested guarantees until a real adapter leg passes.
Package inspection proves required runtime files ship and internal docs do not.

## 13. Compatibility and rollout

### 13.1 Observable changes

Assistant features are opt-in per desk with persisted activation. Changes
independent of activation: new schema, actor-key picker values (legacy
unambiguous IDs accepted temporarily), validated kind enum and fail-closed
unbound custom AI actors. Human transitions retain existing behavior unless
interacting with assistant ownership/review/intervention as specified.
Existing callbacks keep their argument signatures. No renaming awaiting_reply?
in this release; context documentation explains it means waiting on the desk.

### 13.2 Upgrade

1. Pin tested Chats/support_desk candidate versions; build and inspect packages.
2. Run additive migration with automation disabled; old 0.2 code may continue
   writing ordinary human/requester traffic during this **expansion** stage.
3. Deploy the new code to ALL writers: web, jobs, cable/console workers,
   scheduled tasks and imports. Drain old jobs/processes. Configuration code
   using new methods cannot boot old versions.
4. Run catch-up/initialize managed state on candidate desks, including existing
   non-null pointers; verify schema/doctor and policy versions. Do not enqueue
   live model work as a migration side effect.
5. Configure identity, explicit disclosure, tenant/action/context policy,
   authenticated review, human door, safe moderation ownership and recovery
   scheduler. Test enqueue failure and human takeover in staging.
6. Activate the desk using persisted control epoch, initially draft/observe.
   Initialize outstanding unanswered work. Poll/dispatch/reconcile must all
   see activation consistently. Verify no old writer remains.
7. Enable autonomous actions only after host evaluation and explicit policy
   change, bumping policy version/activation epoch as required.

“Rolling-safe” applies only to disabled schema expansion. Once automation is
active, old writers bypass revision/policy constraints; running them alongside
new workers is unsupported. If the host cannot stage these steps, drain all
writers for the cutover rather than claim a zero-downtime guarantee.

### 13.3 Rollback

Disable automation centrally, revoke claims, drain/cancel queued AI commands
and expose unresolved cases to humans. Roll back to a tested compatible code
release retaining schema and historical models/readers. Older 0.2 lacks the
Assistant constant, provenance rendering and control boundary; a bare gem pin
back to it is not a safe runtime rollback once AI rows exist. No down migration
to erase provenance. Re-enable only through the activation/catch-up checks.

### 13.4 CHANGELOG requirements

State actual version and behavior changes above, new errors/keywords, AI macro
binding requirement, approval/replay semantics, migration/catch-up order,
durable-work scheduling, default context exclusions and presentation modes.
Separate current implemented APIs from roadmap. No “late answers harmless”
claim without the complete §12 concurrency gate.

## 14. README contract

The README must contain the practical workflow and the public reference, not
just a link to this internal PRD. Include:

- Small configure -> claim/context -> draft/review -> send example, fully
  executable with a stub harness; no provider required.
- Responsibility table; fixed principal; arbitrary harness integration.
- Level presets plus independent permissions, restrictions and authorization.
- Identity, custom AI binding, disclosure modes and historical presentation.
- Work/claim/turn/receipt lifecycle, every error and retry guidance.
- Draft revisions, files, approval/publication and reviewer/publisher roles.
- Human door, requirements, pause vs hand-back, reopen behavior.
- Context schema/version/limits/internal opt-in and source/metadata contracts.
- Every public method/keyword/default/return, config setting, event, queue,
  task, generator/helper and intentional limitation.
- Durable scheduling/recovery, monitoring and honest metric definitions.
- Upgrade/rollback/package instructions and verified adapter matrix.

Generated examples and API inventory checks are release gates; matching method
names by grep is useful but insufficient to prove examples behave correctly.
No internal business-repo content or host-specific legal claim in public docs.

## 15. Delivery gates

Do not preassign real PR numbers or one-hour estimates. Required sequence:

| Unit | Scope | Gate |
|---|---|---|
| Chats boundary | metadata, transactional subject wrapper, historical presentation and thread slot | Ordinary Chats regression suite + support integration race prototype green |
| SupportDesk A: reliable kernel | identity/config, permission, managed message registration, work/claims/receipts, migration/activation | I01–I07, I10–I12, I15–I17 |
| SupportDesk B: review/control | drafts/revisions/files/reviews, requirements, pause/resume/hand-back, conditional close/outreach | I08–I16, full mutation matrix |
| SupportDesk C: surfaces/DX | console/door/context/locales/generator/README/doctor/tasks | Context/UI tests, stub harness, all public APIs documented |
| Integration rehearsal | real host with isolated DB; lost enqueue, worker crash, revoked agent, human takeover, staged activation/rollback | Current full host CI and scenario tests; no live provider required for gem correctness |
| Release | complete tested candidate; no partly enabled feature release | Complete matrix and package manifest/installed runtime inspection |
| CarHey | host-owned integration/evaluation and staged opt-in | §16 host acceptance and owner-chosen disclosure/activation |

No unit release advertises full AI readiness before downstream write-boundary
and review tests pass together. Publish/merge/deploy decisions remain separate
from this documentation work.

## 16. CarHey integration

This is a concrete integration checklist, not authorization to deploy an agent
or copy business documents into product content. CarHey source is the truth;
method names below that are not yet in source must be implemented/tested, not
assumed available.

### 16.1 Policy and context

Rose uses default draft autonomy initially. Explicit default-desk binding,
policy_version and host access callback are required. CarHey chooses disclosure
before generation/activation; signature_and_notice is a proposal, not a
recorded fifth owner decision. Payments remain draft-only; verification remains
observe-only unless the owner later changes that policy. A hard host cap also
checks the actual subject/domain risk, so topic reclassification cannot remove
money restrictions. No shadowban policy invented by this gem PRD: preserve
CarHey’s current requester eligibility and choose further restrictions in the
host deliberately.

Build Support::AssistantContext from verified model readers and bounded
queries. Start with requester display name, safe account/KYC status, selected
ride/withdrawal state and links to explicitly published help material. Do not
paste unverified wallet.balance.format, kyc_status_label or rides_completed_count
methods into a generator. Authorize requester-scoped lookup independently of
whatever IDs the model proposes. Human console context may be richer; the
assistant context must be an explicit allowlist with host versioning for
financial/ride state changes.

### 16.2 Harness

Use existing app/services/ai/client.rb as the host’s client construction seam
if CarHey chooses that provider; model/provider choice is host configuration,
not a baked-in speculative model name in the gem PRD. This client’s timeout is
per attempt and it has retries; choose/test a total turn budget including all
attempts, retrieval and queue delay, below the work deadline.

Retrieve only from a reviewed published help corpus in CarHey. Do not point a
tool at carhey-business, its legal files or arbitrary repository paths. Content
from business planning must pass an explicit publication process before it
becomes customer-support knowledge. FAQ references carry document/version IDs;
model self-confidence and presence of a citation do not prove factual support.

Tools initially read only, scoped to the authenticated requester: published
help search, selected ride state and selected withdrawal state. No refunds,
identity decisions, account mutations or raw SQL. Those require separate
host-owned action authorization/review if added later. Multi-step retrieval is
allowed; the gem does not require exactly one model call. Bound execution in
the harness and map exhaustion/failure to durable human intervention.

### 16.3 UI, notifications and moderation

Integrate the shipped draft/review and human-door seams into ejected madmin
and Chats views. Actor-key values throughout. All requester views honor the
chosen disclosure; do not add a robot mark that defeats none/notice behavior.
Staff views show provenance/sources; public thread does not show draft data.

Subscribe with SupportDesk.on and stable keys. One needs-human notifier handles
human_required from requester/escalation/timeout, deduplicated by requirement
ID. Draft notifier uses proposal/revision identity. Existing ticket_opened and
requester_replied fan-out must avoid double-paging the same work. Audit delivery
is separate from notification delivery. Test subscription reloads.

Moderate: inspect current reported_owner/flag schema and choose a valid
accountable owner representation. A nil owner is not a plan. Prove reporting,
review, user visibility and takedown against a Rose-authored message and an
unsigned mode in staging. AuditLog must preserve AI actor identity, not cast it
to User. Legal/disclosure decisions live in the host legal process; no private
content copied here or to a public PR.

### 16.4 Rollout

1. Ship disabled infrastructure, migrate/drain/catch-up, verify rollback.
2. Enable Rose at draft globally, with verification observe; staff review real
   proposals and evaluate a curated set of difficult/wrong-topic cases.
3. To permit FAQ topics to reply, raise Rose’s **global ceiling** to reply and
   explicitly leave EVERY other topic/ancestor/unknown/default cap at draft or
   observe. Merely changing a leaf to reply while global autonomy stays draft
   does nothing. Bump policy version, invalidate old work, test effective
   permissions by actual topic/subject and account state.
4. Monitor factual support, stale/refused actions, human requests, unresolved
   review backlog, recovery latency and measured customer outcomes. Acceptance
   percentage alone is not a promotion gate; define sample/window and evaluate
   correctness independently. Never count resolved_by_assistant at reply level
   as containment: it cannot close.
5. Resolve level is a separate deliberate promotion with conditional closure
   tests and explicit max_turns. Payments/verification caps persist; ensure
   every overlooked/default topic remains conservative.

## 17. Adversarial scenario register

This register maps concrete failures to tests; the fuller obligations are §12.

| # | Scenario | Required result | Test |
|---|---|---|---|
| 1 | Three requester messages, frozen timestamp/UUID | Three observed inputs; latest opportunity only | I04/I05 |
| 2 | New message commits before AI obtains lock | Stale result cannot send | I04/I06 |
| 3 | Human takes then releases during generation | Old token still fenced | I06/I11 |
| 4 | Pause then resume while old job runs | New revision; old job never revived | I09/I11 |
| 5 | Account/agent becomes ineligible | Commit refused; work recovered appropriately | I02/I06 |
| 6 | Human send double-click | One message, same recorded result | I05/I08 |
| 7 | Approval then body/file edit | Prior approval unusable | I08 |
| 8 | Approval then another requester/human message | Re-review current context required | I08 |
| 9 | Host catches validation failure inside transaction | No partial seat/draft/notice/receipt | I15 |
| 10 | Initial enqueue callback crashes | Pending work discovered by redispatch | I12 |
| 11 | AI never had a seat and harness dies | Work overdue; human requirement | I12 |
| 12 | Sweep selects AI; human takes before lock | Human seat never released | I12 |
| 13 | Old worker returns after timeout/reclaim | Fence/requirement refuses reply | I06/I12 |
| 14 | Paused + reopened + human-required | Relaxing one keeps other restrictions | I09 |
| 15 | AI reclassifies payments as app | No authority increase | I10 |
| 16 | Custom kind: :ai class tries draft approval | Refused as AI, never human fallback | I02/I08 |
| 17 | Assistant A calls ticket on desk B | Binding refusal | I02 |
| 18 | Direct desk.message! bypass | Subject wrapper refuses automated write | I03/I04 |
| 19 | Draft has files but no text at draft level | Files retained/reviewable, or explicit validation error | I08/I14 |
| 20 | Customer door after AI config removed | Exit/status remains accessible | I11/I13 |
| 21 | Phrase hook or cap crashes | Customer message kept, automation suppressed, visible failure | I12 |
| 22 | Empty requester-created case | No invented inbound opportunity | I07 |
| 23 | AI outreach about capped money subject | Contextual policy refuses | I16 |
| 24 | Retried outreach after ticket closed | Same operation result, no new contact | I05/I16 |
| 25 | Model changes response on retry with same key | Explicit IdempotencyConflict | I05 |
| 26 | AI reply then close races requester input | Close refused if context changed | I06 |
| 27 | Historic AI identity renamed/deconfigured | Correct stable rendering/export | I13 |
| 28 | Source is javascript URL / script title | URL refused, text escaped | I14 |
| 29 | nil disclosure / required notice blank | Configuration/send refusal, no undisclosed fallback | I13 |
| 30 | Human plain reply while draft pending | Supersede/revoke approval; no duplicate follow-up offer | I08 |
| 31 | UUID host changed generator ID setting | Existing referenced types respected | I17 |
| 32 | Old writer updates non-null pointer after migration | Final catch-up corrects before activation | I17 |
| 33 | Historical closer AI, assignee human | Reopen capped based on closer, not holder | I09 |
| 34 | Approver revoked before delayed publication | Publication refused | I03/I08 |
| 35 | New human reason while one already active | Separate requirement, no lost restriction | I09 |
| 36 | Reply budget bypass via direct reply! or outreach | Same budget enforced | I07/I16 |
| 37 | Constant names / callback arities in examples wrong | Executable docs fail release gate | I18 |
| 38 | Current work completed but callback retried | No repeat notes/drafts/events | I05/I12 |
| 39 | Human-only host upgrade | No unexpected extra tabs/notices | I01 |
| 40 | Chat edit/delete uses alternate model path | Revision changes or supported path refused; no bypass | I04 |

## 18. Explicit deferrals

These are product/runtime choices, not holes in required guards:

- General human “save as draft” composer UX (human editing/review of AI
  proposals is included); multiple simultaneous current proposal threads.
- Multiple autonomous responders on one desk; a persona per topic; routing,
  shifts and capacity algorithms. Hosts can orchestrate tools behind one
  accountable configured responder without model identity proliferation.
- Streaming generation; partial customer-visible AI output. Private complete
  draft/review works independently of streaming.
- Model runner, provider adapters, prompt library, retrieval engine,
  vector store, confidence calibration, evaluations and cost accounting.
- Generic executable tool approvals/refund engine; link host records instead.
- CSAT, saved replies/macros and expanded metrics product.
- Cross-database atomic transactions, raw-SQL interception and sandboxing host
  application code; external transport exactly-once delivery.

Draft attachments, freshness, replay protection, lost-enqueue recovery, tenant
hooks, custom-AI fail-closed behavior and a functioning shipped human door are
NOT deferred. If a release omits them it must reduce the advertised scope and
revisit this contract before implementation proceeds.

## Appendix A — configuration example

This is a generic Rails example; classes/callbacks named Support::* belong to
the host. A source checker must validate the DSL against the implementation.

```ruby
SupportDesk.configure do |config|
  config.assistant :rose do |rose|
    rose.name = "Rose"
    rose.autonomy = :reply
    rose.disclosure = :signature_and_notice
    rose.policy_version = "support-v1"
    rose.max_turns = 6
    rose.responds_within = 3.minutes
    rose.may_open_conversations = false
    rose.triage = false
  end
  config.default_assistant = :rose
  config.desk(:billing) { |desk| desk.assistant = nil }

  config.topics do
    topic :payments, assistant: :draft
    topic :verification, assistant: :observe
    topic :app, assistant: :reply
    other assistant: :draft
  end

  config.authorize_support do |actor, action, ticket, resource:|
    Support::Authorization.allowed?(actor, action, ticket, resource: resource)
  end
  config.assistant_context do |ticket, actor|
    Support::AssistantContext.for(ticket, actor)
  end
end

SupportDesk.on(:assistant_work_available, key: "support.rose.work") do |work|
  Support::RoseTurnJob.perform_later(work.id)
end
```

Global reply is intentional here so the app leaf can actually reply. A draft
soak changes the global ceiling to draft; promoting later also preserves every
other cap. The owner’s real disclosure choice is supplied explicitly, not
inferred from this illustrative example.

## Appendix B — sequences

```text
B1 Input -> answer
  requester write -> desk/ticket lock -> Chats validations/persist
    -> fold clocks + revision + durable work -> commit -> work signal
  host claims work -> bounded authorized snapshot -> provider outside locks
  respond! -> receipt lookup -> claim/turn/policy checks -> message + clocks
    + counter + receipt -> commit -> broadcasts

B2 Draft -> review
  respond! at draft -> revision + proposal + receipt -> commit
  human reads proposal revision R and current turn T
  send!(revision: R, reviewed_turn: T, key: K)
    -> human permission + revision/context checks -> review + human message
    + provenance + sent state + receipt -> commit
  repeated K -> same message; new input before commit -> StaleDraft

B3 Human request during generation
  request_human! -> active keyed requirement + revision + revoke claim
    + release AI seat + acknowledgement -> commit -> one human notification
  old respond! -> stale/revoked; cannot publish or take the seat back
  later private assistance -> new permitted draft work, separate authority

B4 Lost enqueue / silent work
  requester transaction persists work; enqueue callback fails
  dispatcher discovers pending work; host may claim it
  deadline passes -> reconcile locks/rechecks -> requirement + revoke
  a human who took the seat in between is never released

B5 Explicit hand-back
  human names requirements/cap/pause to resolve
  validate resulting policy -> atomic resolutions + assignment + new revision
    + fresh work if awaiting -> commit
  any remaining host hard cap refuses; all attempted changes roll back
```

## Appendix C — implementation file map

Names indicate responsibilities, not permission to duplicate domain logic:

```text
support_desk/configuration.rb + macros.rb    assistant config/binding/host hooks
support_desk/assistant_policy.rb            shared permission decisions
support_desk/models/assistant.rb            optional identity, activation
support_desk/models/automation_control.rb   persisted desk control/epoch
support_desk/models/assistant_work.rb       work/claim/deadline/recovery
support_desk/models/operation.rb            idempotency receipt
support_desk/models/chat_registration.rb    managed sequence/replay receipt
support_desk/models/{draft,draft_revision,draft_review}.rb
support_desk/models/human_requirement.rb
support_desk/models/ticket/...              shared write gateway + record helpers
support_desk/{context,transcript,brief,outcome}.rb
support_desk/{events,errors,queue,timeline,summary,context_card,doctor,test_helpers}.rb
support_desk/{console,console_routes}.rb     scoped review/control operations
support_desk/engine.rb                      reload/spine registration
lib/tasks/support_desk.rake                 activation/catch-up/reconcile/dispatch
lib/generators/support_desk/...             migration + named host templates
app/controllers + app/views                 console and requester surfaces
config/locales/{en,es}.yml                  matching keys/interpolations
README.md + CHANGELOG.md + tests            public contract and gates
chats/models/message + messaging concern    generic transactional subject seam
chats presentation/helpers + thread slot    stable presentation and human door
```

New configuration/policy classes referenced at boot must be deliberately
required in the spine or handled by Zeitwerk without double-loading. Register
built-in Assistant in to_prepare; do not create DB rows while booting a fresh
unmigrated app. Development reload, eager-load production and generator boot
are separate acceptance cases.
