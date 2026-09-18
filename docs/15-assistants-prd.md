# PRD — Assistants: AI agents as a first-class use case of `support_desk` (0.3.0) — v3

*2026-09-18. v1 (d9ff5c5) was the first contract; v2 (e9adfa7) was an
adversarial rewrite. v3 is the contract to implement: it keeps every real bug
v2 found and drops the machinery that a gem with zero production tickets does
not need. The disposition of all 46 v2 findings is in
[15-assistants-review-2.md](15-assistants-review-2.md). Owner decisions 12
#19–22 stand. Design rationale: [14](14-assistants.md).*

**One sentence:** the gem owns the guardrails, the host owns the model — and
the guardrails are one integer column, one row lock and the transitions that
already exist.

---

## Contents

0. Status, scope, decisions
1. Goals
2. Vocabulary
3. Invariants
4. Public API (complete)
5. Algorithms
6. Schema and migration
7. Surfaces
8. Locales
9. Harness contract and generator
10. Compliance and safety
11. Evidence and operations
12. Test plan
13. Compatibility, upgrade, CHANGELOG
14. README
15. Delivery
16. CarHey integration
17. Edge-case register
18. Deferred
Appendix A — configuration example · B — sequences · C — file map

---

## 0. Status, scope, decisions

**Target:** `support_desk` 0.3.0. **No chats change required** (§4.21).

**Decisions taken (12 #19–22), not to be reopened:**

| # | decision |
|---|---|
| 19 | The persona is `SupportDesk::Assistant`, a gem-shipped record (Desk pattern). 04's `Bot` + `responder_class` are superseded. |
| 20 | An approved draft is **authored by the human who sent it**; provenance in message metadata (`support_desk.drafted_by`, `draft_id`, `edited`). |
| 21 | A case the assistant closed that the requester reopens comes back **unassigned with the assistant capped at `:draft`** on that case; an explicit human hand-back lifts it. |
| 22 | **Disclosure has no default.** `disclosure=` is required on every assistant; omitting it fails boot; `:none` is explicit and silent. |

**Defaults taken by recommendation:** autonomy `:draft`; `max_turns` 6;
`responds_within` 3 minutes; `may_open_conversations` false; levels
`off / observe / draft / reply / resolve`; `hand_off_when` is an optional
host block that runs before the model and **fails closed**.

**In scope:** identity + disclosure; policy; the turn (revision-based);
`respond!` / `draft!` / policy-gated existing verbs; drafts with human review
(send verbatim / edited / reject) and attachments; the two exits; pause;
context (`transcript`, `brief`); events; console + engine surfaces; doctor;
maintenance tasks; generator; test helpers; docs.

**Out of scope (deferred, §18):** work/claim/lease tables and idempotency
receipts; draft revision/review tables and a separate approve/publish step;
multiple simultaneous human requirements; AI triage (`change_topic!` /
`attach_subject!` by an assistant); a host authorization hook for domain
writes; activation epochs / policy versions; a transactional chats write
wrapper; several assistants per desk.

**Hard requirement:** a host that configures no assistant sees no behaviour
change on any existing path (new nullable columns aside). §12.1 proves it.

---

## 1. Goals

| who | wants |
|---|---|
| host developer | one job: read `ticket.brief`, call a model, hand the answer to `ticket.respond!(text, by: rose, turn:)`, never encode policy in a prompt |
| human agent | the proposal waiting in the case with Enviar / Editar / Descartar; who wrote every bubble; Pausar on a delicate case; escalated cases first |
| requester | to know when it is an assistant; a way to a person that always works; never two answers to one message |
| owner / compliance | disclosure as an explicit choice; the export says what a machine wrote; every machine action in the audit chain with the rule that allowed it; money topics human-sent by construction |
| operations | a dead harness surfaces within minutes and turns `doctor` red; a late or redelivered job never double-posts |

Success: a ≤ 30-line harness (§9) runs an assistant at every level; every
refusal is deterministic and named; the concurrency tests in §12.6 pass on
PostgreSQL and SQLite; CarHey runs "Rose" at `:draft` and moves topics up
with a config change.

---

## 2. Vocabulary

| term | meaning |
|---|---|
| **assistant** | a `SupportDesk::Assistant` record: `acts_as_support_agent kind: :ai, if: :active?`, behaviour from `config.assistant :key`. One per desk; the same one may serve several desks. |
| **level** | `:off < :observe < :draft < :reply < :resolve` — the most the assistant may *produce*. |
| **ceiling** | a rule that lowers the configured level: topic cap (min over ancestors), `cap` block, the persisted case cap (`assistant_cap`), pause. |
| **floor** | a rule that lowers the effective level because of case state: inactive, closed, human required, a human holds the case. |
| **policy** | `ticket.assistant_policy` — ceilings then floors, with `because`. |
| **revision** | `ticket.assistant_revision`, an integer bumped by every registered message and every transition. |
| **turn** | `ticket.assistant_turn`, an opaque String derived from the revision. Every assistant action requires it and consumes it. |
| **stale** | a turn that no longer matches: somebody (requester, human, the assistant itself) changed the case since. |
| **speak** | write a message the requester sees, sent by the desk, attributed to the assistant. |
| **draft** | a proposed reply a human sends (verbatim or edited) or rejects. One pending per case. |
| **hand-off** | `escalate!` (assistant → humans) or `request_human!` (requester → humans); both set **human required**. |
| **pause** | a per-case human override to `:off` (`assistant_paused_at`). |
| **case cap** | `assistant_cap`, a persisted per-case ceiling (today: `"draft"` after a reopen of an AI-closed case). |
| **hold** | an open `Assignment`: who owes the next word. An assistant holds a case only at `:reply`+. |

---

## 3. Invariants (each is a test family in §12)

| # | invariant |
|---|---|
| I1 | No assistant configured ⇒ no new event, message, tab, seat or column write on any existing path. |
| I2 | Every AI-kind actor is either the desk's configured `SupportDesk::Assistant` or refused (`NotAnAssistant`). A host `kind: :ai` model never inherits human authority. |
| I3 | Policy is enforced inside every transition, under the ticket lock, from fresh state. `actions_for` is a projection of the same decision. |
| I4 | Every assistant action requires the current turn and consumes it. A stale, retried or redelivered action writes nothing (`StaleTurn`). |
| I5 | Before an assistant speaks, requester messages that chats committed but the gem has not folded in yet are folded in under the lock — so the turn reflects everything the customer said. |
| I6 | One assistant reply per requester message, never into a closed case, never past `max_turns`, never while a human holds the case, never while a person is required. |
| I7 | One pending draft per case (partial unique index where the adapter allows; the model + `doctor` elsewhere). |
| I8 | Humans outrank assistants: a human reply on an assistant-held case takes it over under every `reply_policy`; only an explicit human hand-back returns it. |
| I9 | Pause, case cap and human-required are independent columns; resume clears only pause; hand-back is the one action that clears all three, explicitly. |
| I10 | An assistant cannot widen its own authority: no topic/subject change, no assignment of others, no reopen, no approval, no resume. |
| I11 | A silent assistant never hides a case: after `responds_within` its seat is released *and* a person is required; `doctor` fails meanwhile. |
| I12 | Authorship is accountability: autonomous ⇒ attributed to the assistant (author or metadata); approved draft ⇒ `author:` the sending human, provenance in metadata. |
| I13 | Every machine decision is persisted where it was made (message metadata, draft row, event payload) with the policy that allowed it. |
| I14 | Requester-facing surfaces and `export` honour the disclosure mode; staff surfaces always show real provenance. Drafts, notes and sources never reach the requester. |
| I15 | A refused operation rolls back everything it touched, even when the caller rescues inside an outer transaction (`requires_new: true` everywhere). |
| I16 | The gem calls no model, stores no prompt, depends on no provider gem. |

---

## 4. Public API (complete)

Signatures are exact. `:nodoc:` marks internals.

### 4.1 Configuration

```ruby
config.assistant :rose do |rose| … end     # declare / reconfigure (block yields an AssistantConfiguration)
config.assistant(:rose)                     # read; ConfigurationError when unknown
config.assistants                           # Hash{Symbol => AssistantConfiguration}
config.assistant?(:rose)
config.default_assistant = :rose            # the default desk's; implicit when exactly ONE assistant is configured
config.desk(:billing) { |desk| desk.assistant = :rose }   # per desk; an explicit nil DISABLES that desk (distinct from inheriting)
config.desk(:billing).assistant_key         # Symbol | nil
```

`Configuration#assistant(key)` never doubles as the default getter (v2 R38).
`DESK_SETTINGS` gains `assistant`; `DeskConfiguration#assistant=` stores the
key or an explicit nil; `#assistant_key` = own value if `own?(:assistant)`,
else `default_assistant`, else the single configured assistant, else nil.

#### `AssistantConfiguration`

| setting | type / validation (on assignment) | default |
|---|---|---|
| `name` | non-blank String; nil resets | humanized key |
| `avatar` | String \| callable(assistant) \| nil | nil |
| `autonomy` | one of `LEVELS` | `:draft` |
| `disclosure` | **required**: `:signature_and_notice` \| `:signature` \| `:notice` \| `:none`; the setter rejects nil | — |
| `max_turns` | positive Integer \| nil (unlimited; `doctor` warns) | 6 |
| `responds_within` | Duration/Numeric \| nil (disables the silent-release path; `doctor` warns) | 3 minutes |
| `may_open_conversations` | `true` \| `false` (strict) | false |
| `hand_off_line` | String (`%{name} %{desk} %{reply_within}`) \| Symbol (I18n key) \| block(ticket) \| nil | `:"support_desk.system.handed_off_to_humans"` |
| `human_requested_line` | same | `:"support_desk.system.human_requested"` |
| `disclosure_line` | same | `:"support_desk.system.assistant_disclosure"` |
| `hand_off_when` | block(ticket, message) → true/false/nil | nil |
| `cap` | block(ticket) → level \| nil | nil |

Predicates: `signs?` (`signature_and_notice`, `signature`), `notice?`
(`signature_and_notice`, `notice`), `disclosed?` (`!= :none`).
`line_for(setting, ticket)` and `line_problems` mirror `opening_line_for` /
`opening_line_problems` (String interpolation checked on assignment, Symbol
existence reported by `doctor`, blocks left alone). Interpolations: `name`,
`desk`, `reply_within` (nil when the desk has no `reply_within`; the default
copies avoid promising a duration when it is nil — two variants per key,
`_with_promise` / plain).

`validate!` (end of `SupportDesk.configure`): every assistant has
`disclosure`; every `desk.assistant` names a configured key;
`default_assistant` names a configured key; two or more assistants with no
`default_assistant` ⇒ error; `max_turns nil` / `responds_within nil` ⇒
warnings (surfaced by `doctor`).

#### Topic option `assistant:`

`topic :payments, assistant: :draft`. Validated ∈ `LEVELS`. **Not** in
`INHERITED_OPTIONS`: `Topic#assistant_cap` = the minimum over `own` and every
ancestor's own value (a child can only tighten). `Topic::Unknown#assistant_cap
= :observe`.

#### `acts_as_support_agent kind:`

`kind:` must be `:human` or `:ai` (`ConfigurationError` otherwise). A host
class declared `kind: :ai` is registered as AI-kind; unless it *is*
`SupportDesk::Assistant`, every support write by or to it raises
`NotAnAssistant` (I2). `doctor` warns about such classes.

### 4.2 Module functions

```ruby
SupportDesk.assistant(key = nil)      # Assistant record, memoised (find_by || create_or_find_by!); nil key → default_assistant/single; nil when none; ConfigurationError for an unknown key
SupportDesk.reset_assistants!         # forget the memo; reset! does it too
SupportDesk.ai_actor?(record)         # record.respond_to?(:support_agent_kind) && record.support_agent_kind == :ai
SupportDesk.release_silent_assistants!   # → Integer (§5.10)
SupportDesk.redispatch_assistant_turns!(older_than: 1.minute)   # → Integer (§5.11)
SupportDesk.report_error(error, context: {})   # :nodoc: Rails.error when present, else logger — the dispatcher's path, extracted
```

### 4.3 `SupportDesk::Assistant`

```ruby
class SupportDesk::Assistant < ApplicationRecord
  self.table_name = "support_desk_assistants"
  acts_as_support_agent kind: :ai, if: :active?
  attribute :settings, default: -> { {} }
  validates :key, presence: true
  scope :active, -> { where(active: true) }

  def self.for(key)                       # find_by || create_or_find_by!
  def config                              # SupportDesk.config.assistant(key)
  def configured?
  def name / avatar / autonomy / disclosure / max_turns / responds_within / may_open_conversations?
  def disclosed? / signs? / notice?
  def disclosed_name                      # disclosed? ? I18n.t("support_desk.assistant.disclosed_name", name:) : name
  def display_name = disclosed_name       # what chats' display-name lambdas read
  def to_s         = disclosed_name       # hosts whose lambda falls back to to_s
  def support_agent_name   = disclosed_name
  def support_agent_avatar = avatar
  def on_duty?          = active?
  def support_capacity  = nil
  def deactivate!(by:, reason: nil)       # active=false + event-less log line; held cases are released by the sweep (§5.10)
  def activate!(by:)
  def desks                               # Desk records whose config.assistant_key == key
  def held_tickets                        # Ticket.open.assigned_to(self)
  def inspect                             # "#<SupportDesk::Assistant rose \"Rose\" draft active>"
end
```

`active` is the cross-process kill switch: a DB column read fresh by
`ensure_agent_record!` on every transition. Rows are never destroyed.

### 4.4 `SupportDesk::AssistantPolicy`

```ruby
LEVELS = %i[off observe draft reply resolve].freeze
RANK   = LEVELS.each_with_index.to_h.freeze
VERBS_BY_LEVEL = {
  off:     [],
  observe: %i[note escalate release],
  draft:   %i[note escalate release draft],
  reply:   %i[note escalate release draft reply take],
  resolve: %i[note escalate release draft reply take close]
}.freeze   # each level's array is the previous plus its own verbs; frozen

AssistantPolicy.for(ticket, assistant = ticket.assistant, hand_back: false)   # → policy (Null when assistant nil or not this desk's)
policy.level / because / ceilings (Hash) / floors (Array of Symbols) / assistant / ticket
policy.at_least?(level) / may?(verb) / may_observe? / may_draft? / may_reply? / may_hold? (= may_reply?) / may_close?
policy.allowed_verbs / forbidden_verbs / to_h / to_s / null?
```

`Null`: `level :off`, `because "no assistant on desk #{key}"` (or `"rose is
not desk billing's assistant"`), every predicate false. `to_h` = `{
assistant:, level:, because:, ceilings: { assistant:, topic:, cap:, case:,
pause: }, floors: [...] }`.

### 4.5 `SupportDesk::Ticket` additions

**Columns** (§6): `assistant_revision` (bigint, 0), `last_requester_message_id`,
`assistant_turns_count` (integer, 0), `assistant_acted_at` (datetime),
`assistant_paused_at`, `assistant_paused_reason`, `assistant_cap` (string
level), `human_required_at`, `human_required_reason`.

**Associations:** `has_many :drafts` (dependent: :destroy), `has_one
:pending_draft, -> { pending }`.

**Scopes:**

```ruby
held_by_assistants   -> where(assignee_type: SupportDesk::Assistant.polymorphic_name)
held_by_humans       -> assigned.where.not(assignee_type: SupportDesk::Assistant.polymorphic_name)
needs_human          -> where.not(human_required_at: nil)
assistant_paused     -> where.not(assistant_paused_at: nil)
assistant_capped     -> where.not(assistant_cap: nil)
resolved_by_assistant -> closed.where(closed_by_type: SupportDesk::Assistant.polymorphic_name)
with_pending_draft   -> where(id: SupportDesk::Draft.pending.select(:ticket_id))
assistant_idle_since(time) -> awaiting_reply.where(last_requester_message_at: ..time).where("assistant_acted_at IS NULL OR assistant_acted_at < last_requester_message_at")
```

**Readers:**

```ruby
assistant                    # desk.assistant | nil
assistant_policy(assistant = self.assistant, hand_back: false)
assistant_turn               # "t#{id}-r#{assistant_revision}" — never nil
assistant_in_play?           # desk.assistant.present? || messages_from_assistant.exists?   (history counts: the door must not vanish)
held_by_assistant?           # assignee_type == Assistant.polymorphic_name
human_required?              # human_required_at.present?
assistant_paused?            # assistant_paused_at.present?
assistant_turns_left         # nil when unlimited
transcript(limit: nil) / brief(include_internal: false, transcript_limit: 50)
assistant_message?(message)  # author is an Assistant, or metadata["support_desk"]["assistant"] present
```

**New verbs:**

```ruby
respond!(body = nil, by:, turn:, files: [], confidence: nil, sources: [], metadata: {}, request: nil)  # → Outcome
draft!(body = nil, by:, turn:, files: [], confidence: nil, sources: [], metadata: {}, request: nil)    # → Draft
escalate!(by: nil, reason:, summary: nil, turn: nil, request: nil)   # → self; turn: REQUIRED when by: is an assistant
request_human!(by: nil, request: nil)                                # → self; by: must be this ticket's requester
pause_assistant!(by: nil, reason: nil, request: nil)                 # → self; human agents only
resume_assistant!(by: nil, request: nil)                             # → self; clears pause only
```

**Changed verbs (behaviour when an assistant is involved):**

| verb | assistant as `by:` | assistant as target / other |
|---|---|---|
| `reply!(body, by:, files:, request:, metadata: {}, turn: nil)` | needs `turn:`; `may_reply?`; `awaiting_reply?` (else `:not_your_turn`); budget left; consumes the turn | a **human** reply on an assistant-held case takes it over under every `reply_policy` and supersedes the pending draft |
| `close!(by:, request:, turn: nil)` | needs `turn:`; `may_close?`; `assigned_to?(assistant)`; `awaiting_requester?`; `!human_required?` | any close expires pending drafts |
| `assign!(to:, by:, …)` | may only take itself (`to == by`), unassigned case, `may_hold?` | `to:` an assistant ⇒ `ensure_assignable!` uses `hand_back: true` policy; on success **clears** `human_required_*`, `assistant_paused_*`, `assistant_cap` (payload `handed_back: true`); emits `:assistant_turn` if `awaiting_reply?` |
| `hand_off!(to:, …)` | refused (`AssistantNotAllowed`) — she escalates | same `to:` rules as `assign!` |
| `release!(by:, reason:, …)` | only her own seat; `may_observe?` | `reason:` may be `:escalated` (used by the silent-release path) |
| `note!(body, by:, …)` | `may_observe?`; needs `turn:`; consumes it | — |
| `change_topic!` / `attach_subject!` | **refused** in 0.3 (`AssistantNotAllowed`, verb `:triage`) | a human change that lowers the effective level below `:reply` while she holds the case releases her seat in the same transaction (`assistant_released: true`) |
| `reopen!` | refused | reopen of an AI-**closed** case (by `closed_by`) ⇒ unassigned + `assistant_cap = min(current, "draft")` (§5.8) |
| `Ticket.open!(by: assistant)` | outreach (§5.12) | — |

`actions_for(agent)` (§4.5.1) stays the boundary. `may_reply?(human)` is true
when `held_by_assistant?` regardless of `reply_policy`. `agents_to_notify`
returns humans only (`desk.humans`). `export` labels assistant messages
`from: "assistant"`.

#### 4.5.1 `actions_for`

```ruby
def actions_for(agent)
  return [] unless agent.respond_to?(:support_agent?) && agent.support_agent?
  return assistant_actions_for(agent) if SupportDesk.ai_actor?(agent)
  return [ :note ] if agent.respond_to?(:on_duty?) && !agent.on_duty?
  actions = [ :note ]
  if closed?
    actions << :reopen
  else
    actions << :reply if may_reply?(agent) && !requester_unavailable?
    actions << :assign
    actions << :hand_off if assigned_to?(agent)
    actions << :release if assigned?
    actions << :change_topic
    actions << :close
    if pending_draft
      actions << :send_draft if may_reply?(agent) && !requester_unavailable?
      actions << :reject_draft
    end
    actions << (assistant_paused? ? :resume_assistant : :pause_assistant) if assistant
  end
  actions
end

def assistant_actions_for(assistant)   # :nodoc:
  return [] unless assistant.is_a?(SupportDesk::Assistant) && assistant == self.assistant
  verbs = assistant_policy(assistant).allowed_verbs.dup
  verbs -= %i[escalate] if closed?
  verbs -= %i[reply draft take] if requester_unavailable?
  verbs -= %i[take] unless unassigned?
  verbs -= %i[release] unless assigned_to?(assistant)
  verbs -= %i[reply] unless awaiting_reply?
  verbs -= %i[close] unless assigned_to?(assistant) && awaiting_requester? && !human_required?
  verbs
end
```

### 4.6 `SupportDesk::Draft`

```ruby
class SupportDesk::Draft < ApplicationRecord
  self.table_name = "support_desk_drafts"
  STATUSES = %w[pending sent rejected superseded expired].freeze
  MAX_SOURCES = 20

  belongs_to :ticket, inverse_of: :drafts
  belongs_to :author, polymorphic: true                # the Assistant
  belongs_to :reviewed_by, polymorphic: true, optional: true
  belongs_to :sent_message, class_name: "Chats::Message", optional: true
  has_many_attached :files if defined?(ActiveStorage)

  attribute :sources,  default: -> { [] }
  attribute :metadata, default: -> { {} }
  validates :status, inclusion: { in: STATUSES }
  validates :confidence, numericality: { in: 0..1 }, allow_nil: true
  validate  :body_or_files_present, :sources_well_formed   # ≤ 20 entries of { "title" => String(≤500), "url" => http(s) String(≤2048) | nil }

  scope :pending / sent / rejected / superseded / expired / reviewed (sent+rejected) / verbatim (sent, sent_body nil) / edited (sent, sent_body present) / by(author) / chronological / newest_first

  def pending? / sent? / rejected? / superseded? / expired?
  def stale?              # pending? && proposed_turn != ticket.assistant_turn
  def edited?             # sent? && sent_body.present?
  def final_body          # sent_body || body
  def confidence_percent
  def author_key          # SupportDesk.actor_key(author)

  def send!(by:, seen_turn:, body: nil, request: nil)   # → Chats::Message (§5.5)
  def reject!(by:, reason: nil, request: nil)           # → self
  def supersede! / expire!   # :nodoc:
end
```

`proposed_turn` (column) is the ticket's turn when the draft was proposed;
`stale?` compares it with the current turn, so *anything* that happened since
— a customer message, a human note, a takeover — shows as stale. Sending a
stale draft is allowed **only** by re-rendering and resubmitting with the
current `seen_turn` (§5.5); there is no boolean bypass.

### 4.7 `SupportDesk::Outcome`

```ruby
Outcome = Struct.new(:action, :message, :draft, :policy, :reason, :turn, keyword_init: true)
  sent? / drafted? / withheld? / escalated? (reason == :max_turns) ; turn = the successor turn after this action ; to_h (ids + policy.to_h)
```

### 4.8 `SupportDesk::Transcript`

Enumerable of `Turn(role:, name:, body:, at:, attachments:, assisted:, message:)`,
roles `:requester | :human | :assistant | :system` (a **separate serializer**;
`Ticket#role_of` keeps returning `:requester | :agent | :system` for the
clocks). `assistant` = `ticket.assistant_message?(message)`; `assisted` =
`metadata.dig("support_desk", "drafted_by").present?`. `name`: requester →
`Chats.display_name_for`; assistant → the bare assistant name from metadata
(historical, survives renames); human → `author.try(:support_agent_name) ||
desk.name`. `to_a`, `to_h`, `to_text` (`"[2026-09-18 10:02] Alice: …"`,
attachments as `[archivo.pdf]`), `last(n)`, `since(message)`, `size`.
Tombstones render `[mensaje eliminado]`.

### 4.9 `SupportDesk::Brief`

`ticket.brief(include_internal: false, transcript_limit: 50)` →
`Brief#to_h` / `#to_text` / `#policy`:

```ruby
{ schema_version: 1,
  desk:      { key:, name:, reply_within: "1 día" | nil },
  assistant: { key:, name:, disclosure:, level:, because:, may: [...], may_not: [...], turns: { used:, max: } } | nil,
  case:      { reference:, status:, awaiting:, opened_at:, opened_via:, opened_by: "requester"|"support", reopened:, human_required: { at:, reason: } | nil, paused:, cap:, topic: { path:, label: }, subject: { type:, label:, status:, context: {} } | nil },
  requester: { name:, since:, open_cases:, context: requester.try(:support_context) || {} },
  internal:  { notes: [ { at:, by:, body: } ], drafts: [ { at:, status:, body:, confidence:, edited:, sent_body:, rejection_reason: } ] } | nil,   # only with include_internal: true
  transcript: transcript.to_h }
```

Facts only; no instructions. The README states in bold that `support_context`
(both the subject's and the requester's) is what the host is sending to a
model, and that internal notes/drafts are opt-in.

### 4.10 `SupportDesk::Requester#support_context`

New overridable reader, default `{}` — "what an agent sees about you", same
meaning as `Supportable#support_context`. Read by `Brief` and rendered by the
console's context card.

### 4.11 `SupportDesk::Desk`

```ruby
assistant        # SupportDesk.assistant(config.assistant_key) | nil
assistant?
humans           # config.agent_pool.to_a.reject { |a| SupportDesk.ai_actor?(a) }
agents           # humans + [assistant].compact   (pickers, routing)
on_duty_agents   # agents.select(&:on_duty?)   (unchanged expression)
```

### 4.12 Constants

- `Assignment::RELEASE_REASONS` unchanged (the silent path releases with
  `escalated`; the *reason* lives in the `escalated` event — v2 R33-ish).
- `Event::KINDS` += `human_requested assistant_paused assistant_resumed
  draft_sent draft_rejected assistant_withheld`.
- `Event.requester_visible` also excludes those five internal kinds
  (`escalated` and `human_requested` stay visible).
- `Event#summary` → `payload["summary"]`.

### 4.13 Errors

```ruby
class NotAnAssistant      < NotAnAgent           # an AI-kind actor that isn't this desk's SupportDesk::Assistant
class AssistantNotAllowed < NotAllowed           # attr_reader :policy, :verb — "rose may not reply on T-AB12CD: topic payments caps rose at draft"
class StaleTurn           < InvalidTransition    # the case changed since `turn`
```

### 4.14 Events (`Events::CATALOGUE` additions)

| event | args | when |
|---|---|---|
| `assistant_turn` | `ticket, assistant, message, turn:` | a requester message registered (opening included) on a desk whose assistant's effective level ≥ `:observe`; also re-emitted by hand-back/resume when `awaiting_reply?` (`message` nil then) and by `redispatch_assistant_turns!` |
| `draft_proposed` | `ticket, draft` | |
| `draft_sent` | `ticket, draft, message, by:` | |
| `draft_rejected` | `ticket, draft, by:, reason:` | |
| `assistant_withheld` | `ticket, assistant, reason:, policy:` | `respond!` wrote nothing (`:policy`, `:not_your_turn`) |
| `ticket_escalated` | `ticket, from:, reason:, by:` | `escalate!` flagged the case (incl. the silent-release path, `reason: :assistant_silent`) |
| `human_requested` | `ticket, by:, reason:` | `request_human!` (`:requester_request`), `hand_off_when` (`:phrase`), hook failure (`:hand_off_when_error`) |
| `assistant_paused` / `assistant_resumed` | `ticket, by:` | |

Every Event-row kind also reaches `ticket_transitioned`.

### 4.15 Console

```ruby
MEMBER_VERBS += %i[send_draft reject_draft pause_assistant resume_assistant]
OFFERED_AS   += { send_draft: :send_draft, reject_draft: :reject_draft, pause_assistant: :pause_assistant, resume_assistant: :resume_assistant }
```

| action | params | behaviour |
|---|---|---|
| `send_draft` | `draft_id` (String), `seen_turn` (String, required), `body` (optional edit) | `draft.send!(by: current_agent, seen_turn:, body:, request:)`; `StaleTurn` ⇒ 422 re-render of the case with the flash `stale_turn` and the current `seen_turn` in the form (text preserved) |
| `reject_draft` | `draft_id`, `reason` (optional) | |
| `pause_assistant` | `reason` (optional) | |
| `resume_assistant` | — | |

- `support_console_draft`: `@ticket.drafts.find_by(id: params[:draft_id])`
  (any status, so a double-submit reads "ya se envió"); nil ⇒
  `refuse(:unknown_draft)`; non-String ⇒ `InvalidInput :invalid_input`.
- `unavailable_reason` gains `"no_pending_draft"`.
- `RESCUED_ERRORS` unchanged (subclasses).
- **Picker values are `SupportDesk.actor_key(agent)`**; `support_console_agent`
  resolves by exact key, then a bare id only when exactly one pool member's
  `id.to_s` matches (UUID or integer). The `_assignment` partial emits keys.
- Helpers: `support_pending_draft`, `support_assistant`.

### 4.16 Requester engine

`post :request_human, on: :member` under `resources :tickets`.
`TicketsController#request_human`: `current_requester.support_tickets.find`
(404 otherwise) → `request_human!(by: current_requester, request:)` →
redirect 303 to `ticket_path(ticket)` with `notice` (`Locked` /
`InvalidTransition` ⇒ `alert`). Partial
`support_desk/tickets/_human_door.html.erb` (local `ticket`): the button when
`ticket.assistant_in_play? && !ticket.human_required? && !ticket.chat_locked?`;
the status line `thread.handled_by_humans` when `human_required?`; nothing
otherwise.

### 4.17 Queue

`TABS = %i[awaiting needs_human mine unassigned open snoozed closed]`;
`needs_human` relation; `counts` adds the portable
`CASE WHEN human_required_at IS NULL THEN 0 ELSE 1 END` grouping;
`visible_tabs` (instance) = `VISIBLE_TABS` minus `:needs_human` unless
`desk.assistant? || counts[:needs_human] > 0`; `tabs` uses `visible_tabs`.

### 4.18 Rake tasks

```
rake support_desk:release_silent_assistants        # SupportDesk.release_silent_assistants!
rake support_desk:redispatch_assistant_turns       # SupportDesk.redispatch_assistant_turns!  (OLDER_THAN=60 seconds)
rake support_desk:assistant_status                 # read-only counts: held by assistants, needs_human, pending drafts, idle turns
```

### 4.19 Doctor checks (added)

| check | verdict |
|---|---|
| `assistants (config)` | desk bindings resolve; names non-blank; `max_turns nil` / `responds_within nil` ⇒ warn |
| `assistant turn subscriber` | assistant configured and no `:assistant_turn` subscriber ⇒ warn |
| `assistant authorship` | `Chats.display_name_for(assistant)` blank ⇒ fail |
| `assistant silence` | any `open.held_by_assistants.awaiting_reply.waiting_over(responds_within)` ⇒ fail (names the task) |
| `assistant seats` | assistant holds a `needs_human` / paused case, or a case whose policy < `:reply` ⇒ fail |
| `assistant idle turns` | `assistant_idle_since(3 × responds_within)` on assistant desks non-empty ⇒ warn (harness may be down; names the redispatch task) |
| `drafts` | pending on closed cases ⇒ warn; > 1 pending per case ⇒ fail |
| `ai agents without policy` | a registered `kind: :ai` class other than `SupportDesk::Assistant` ⇒ warn "refused for every write" |

### 4.20 Generators

- `install` and `upgrade` copy `add_assistants_to_support_desk.rb` (§6) when
  absent (idempotent, like `opened_by`).
- `rails g support_desk:assistant Rose --disclosure MODE [--desk default]
  [--autonomy draft]`: `--disclosure` is **required** (prints the four modes
  and exits with no writes otherwise); writes
  `app/jobs/support/rose_turn_job.rb`, `app/services/support/rose.rb`,
  `test/jobs/support/rose_turn_job_test.rb` (name-specific, never
  overwrites), and **prints** the initializer stanza + subscription (never
  appends to an existing initializer). No locale copying.

### 4.21 chats

**No chats change.** `post_agent_message!` posts through
`conversation.messages.create!(sender: desk, author:, body:, files:, metadata:)`
— the same validations `message!` runs (`message!` is `create!` behind a
`chat_with` for non-conversation targets). Nameless modes (`:notice`,
`:none`) post with `author: nil` so chats prints no signature; provenance is
`metadata["support_desk"]` (I12/I14). `Chats.display_name_for(assistant)` is
still read for signed modes. gemspec stays `chats ~> 0.3, >= 0.3.2`.

### 4.22 `TestHelpers` additions

```ruby
support_assistant(key = nil)
respond_as(assistant, ticket, body = nil, turn: ticket.assistant_turn, **options)   # → Outcome
draft_as(assistant, ticket, body = nil, turn: ticket.assistant_turn, **options)     # → Draft
assert_pending_draft(ticket, body: nil)   # → Draft; String or Regexp
refute_pending_draft(ticket)
assert_needs_human(ticket, reason: nil) / refute_needs_human(ticket)
assert_held_by_assistant(ticket, assistant = nil)
refute_assistant_spoke(ticket)
assert_assistant_policy(ticket, level, because: nil)   # because: String or Regexp
with_assistant_config(key = nil, **overrides) { }
with_topic_assistant_cap(path, level) { }
```

---

## 5. Algorithms

All run under `with_lock(requires_new: true)` (reloads the row: every read
is fresh) and write through `write_transition!` / `record_transition!` /
`publish_transition`, so `ticket_transitioned`, the Turbo refresh and the
audit mirror come for free. "Event" = one Event row inside the transaction;
"emit" = `SupportDesk.emit_after_commit`.

### 5.1 Revision and turn

`bump_assistant_revision!` (`:nodoc:`, caller holds the lock):
`update_columns(assistant_revision: assistant_revision + 1)` — inside the
transaction, no callbacks, in-memory value updated. Called **once** per:

- `record_registration!` of a text message (requester or agent);
- `record_transition!` when it writes an Event (every real transition; a
  no-op transition bumps nothing);
- `propose_draft!` (drafts write no Event);
- `stamp_assistant_action!` (see below) is *not* a bump: the action's own
  transition/registration/draft already bumped.

`assistant_turn` = `"t#{id}-r#{assistant_revision}"`. `ensure_current_turn!
(turn)`: `raise ArgumentError, "turn: is required for an assistant"` when nil
and the actor is AI-kind; `raise StaleTurn, "#{turn} is stale on
#{reference}: the case has changed (now #{assistant_turn})"` unless equal.

`stamp_assistant_action!` sets `assistant_acted_at = Time.current` (same
`update_columns`) after any successful draft / reply / note / escalate /
withheld by the assistant — what `assistant_idle_since` and the redispatch
task read.

### 5.2 Registration changes

In `record_registration!`:

- `when :requester`: also `attributes[:last_requester_message_id] = message.id`.
- after `save!`: `bump_assistant_revision!`.
- after the bump, for `role == :requester`: `evaluate_hand_off_phrase!(message)` (§5.7).

`registered?` tightened (v2 R05): registered when `last_registered_message_id
== message.id`, or `message.created_at < clock`, or (`== clock` and
`message.id.to_s == same-role last id`) — for the requester role the same-role
id is `last_requester_message_id`; for the agent role it is
`last_registered_message_id` when that message was an agent message (store
nothing new: compare against `last_registered_message_id` only when
`last_agent_message_at == clock`). Two distinct messages at one timestamp are
both registered; a replayed message is still skipped.

`announce_registration`, `when :requester` (opening included):
`emit_assistant_turn(message)`:

```ruby
def emit_assistant_turn(message = nil)   # :nodoc:
  assistant = self.assistant
  return if assistant.nil?
  policy = assistant_policy(assistant)
  return unless policy.may_observe?
  SupportDesk.emit_after_commit(:assistant_turn, self, assistant, message, turn: assistant_turn)
rescue StandardError => e
  SupportDesk.report_error(e, context: { hook: :assistant_turn, ticket: id })
end
```

`reconcile_unregistered_messages!` (`:nodoc:`, under the lock, I5): load
`conversation.messages.where(kind: "text", sender_type: requester_type,
sender_id: requester_id)` newer than the requester clock (`created_at >
last_requester_message_at`, or `==` with a different id than
`last_requester_message_id`), `oldest_first`; `record_registration!` each.
Called at the start of every assistant speaking path (`respond!`, `draft!`,
`reply!(by: assistant)`, `close!(by: assistant)`) and of `Draft#send!` —
before `ensure_current_turn!`, so a message chats committed a millisecond ago
makes the turn stale instead of being answered around.

### 5.3 Policy — `AssistantPolicy.for(ticket, assistant, hand_back: false)`

```ruby
return Null.new(ticket, reason: "no assistant on desk #{ticket.desk.key}") if assistant.nil?
return Null.new(ticket, reason: "#{assistant.key} is not desk #{ticket.desk.key}'s assistant") unless assistant == ticket.assistant
config = assistant.config
ceilings = {
  assistant: config.autonomy,
  topic:     ticket.topic&.assistant_cap,             # min over ancestors; Unknown → :observe
  cap:       evaluate_cap(config, ticket),            # nil | level; other → ConfigurationError
  case:      (ticket.assistant_cap&.to_sym unless hand_back),
  pause:     (:off if ticket.assistant_paused? && !hand_back)
}.compact
rule, level = ceilings.min_by { |_rule, lvl| RANK.fetch(lvl) }   # Hash#min_by yields [key, value] — key first (v2 R01)
because = ceiling_sentence(rule, level, assistant, ticket)
floors = []
if !assistant.active?                                   then level, because = :off, "#{assistant.key} is inactive"; floors << :inactive end
if ticket.closed? && RANK[level] > RANK[:observe]       then level, because = :observe, "the case is closed"; floors << :closed end
if !hand_back && ticket.human_required? && RANK[level] > RANK[:observe]
  level, because = :observe, "a person was requested (#{ticket.human_required_reason})"; floors << :human_required end
if !hand_back && ticket.assigned? && !ticket.assigned_to?(assistant) && RANK[level] > RANK[:draft]
  level, because = :draft, "#{holder_name} holds the case"; floors << :held_by_human end
new(ticket:, assistant:, level:, because:, ceilings:, floors:)
```

`hand_back: true` is only used by `ensure_assignable!` (§5.6): it asks
"could she hold this case once the human-side flags are cleared?" — the
hard ceilings (autonomy, topic, `cap` block, inactive, closed) still apply.
`evaluate_cap` validates the block's return (nil or a level) and lets a
raise propagate, except from `emit_assistant_turn` (reported, no turn).

No query: `topic` is an in-memory lookup, `assignee` the loaded association,
the rest columns.

### 5.4 `respond!`, `draft!`, `reply!(by: assistant)`

```ruby
def respond!(body = nil, by:, turn:, files: [], confidence: nil, sources: [], metadata: {}, request: nil)
  assistant = resolve_assistant!(by)          # NotAnAssistant unless a SupportDesk::Assistant that is this desk's; ensure_agent_record! (fresh active?)
  raise ArgumentError, "respond! needs something to say" if body.blank? && files.blank?
  with_lock(requires_new: true) do
    reconcile_unregistered_messages!
    ensure_current_turn!(turn)
    ensure_writable!                           # Locked
    policy = assistant_policy(assistant)
    return withhold!(assistant, policy, :policy, request:)        unless policy.may_draft?
    return withhold!(assistant, policy, :not_your_turn, request:) unless awaiting_reply?
    left = assistant_turns_left
    if policy.may_reply? && (left.nil? || left.positive?)
      message = speak!(body, assistant, policy:, turn:, files:, confidence:, sources:, metadata:, request:)
      Outcome.new(action: :sent, message:, policy:, turn: assistant_turn)
    else
      draft = propose_draft!(body, assistant, policy:, turn:, files:, confidence:, sources:, metadata:)
      reason = nil
      if policy.may_reply? && left&.zero?
        flag_human_required!(actor: assistant, kind: :escalated, reason: "max_turns", summary: metadata["summary"], line: :hand_off_line, request:)
        reason = :max_turns
      end
      Outcome.new(action: :drafted, draft:, policy:, reason:, turn: assistant_turn)
    end
  end
end
```

`withhold!` writes Event `assistant_withheld` `{assistant, reason, policy}`
(bumps the revision, stamps `assistant_acted_at`), emits
`:assistant_withheld`, returns `Outcome(:withheld, reason:, policy:, turn:)`.

`speak!`:

```ruby
notice = post_disclosure_notice!(assistant) if assistant.notice? && !disclosure_posted?(assistant)
apply_reply_policy!(assistant, request:)                    # unassigned → assign!(to: assistant, by: assistant) [taken]; announce_assignment! skips assistants
stamped = { "support_desk" => { "assistant" => assistant.key, "kind" => "ai", "display_name" => assistant.disclosed_name,
                                "disclosure" => assistant.disclosure.to_s, "signed" => assistant.signs?, "turn" => turn.to_s,
                                "confidence" => confidence, "sources" => sources, "policy" => policy.to_h }.compact }
stamped["host"] = metadata if metadata.present?
posted = post_agent_message!(body, files:, by: (assistant if assistant.signs?), metadata: stamped)   # author nil in nameless modes (I12/I14)
pin_before!(notice, posted) if notice
record_registration!(posted)                                # clocks, first_agent_reply_at, :agent_replied, revision bump
update_columns(assistant_turns_count: assistant_turns_count + 1)
stamp_assistant_action!
posted
```

`draft!` = `resolve_assistant!` → lock → `reconcile_unregistered_messages!`
→ `ensure_current_turn!` → policy `may_draft?` else `AssistantNotAllowed` →
`propose_draft!`. `propose_draft!`: validate body/files/sources first (a
`Draft.new(...).validate!`-style check before touching the pending one), then
`drafts.pending.each(&:supersede!)`, `drafts.create!(author:, proposed_turn:
assistant_turn, body:, files:, confidence:, sources:, metadata: { "policy" =>
policy.to_h, "host" => metadata })`, `bump_assistant_revision!`,
`stamp_assistant_action!`, `broadcast_change`, emit `:draft_proposed`. No
`rescue RecordNotUnique` (v2 R07): the row lock serialises; on MySQL the
model rule stands and `doctor` checks.

`reply!(by: assistant, turn:)`: same preamble; `may_reply?` else
`AssistantNotAllowed(:reply)`; `awaiting_reply?` else
`AssistantNotAllowed(:not_your_turn)`; budget left else
`AssistantNotAllowed(:max_turns)`; then `speak!`. `note!(by: assistant,
turn:)`: `may_observe?`; writes the note; `stamp_assistant_action!`.

### 5.5 `Draft#send!` and `#reject!`

```ruby
def send!(by:, seen_turn:, body: nil, request: nil)
  human = ticket.send(:resolve_actor, by)
  raise NotAllowed, "an assistant can't approve a draft" if SupportDesk.ai_actor?(human) || human.is_a?(Symbol)
  ticket.send(:ensure_agent!, human)
  raise ArgumentError, "seen_turn: is required" if seen_turn.blank?
  raise ArgumentError, "an edited draft can't be blank" if !body.nil? && body.strip.empty? && !files.attached?
  message = nil
  ticket.with_lock(requires_new: true) do
    reload
    ticket.send(:reconcile_unregistered_messages!)
    raise InvalidTransition, "draft #{id} is #{status}, not pending" unless pending?
    raise StaleTurn, "the case changed since you read it (#{seen_turn} → #{ticket.assistant_turn}); read it again" unless seen_turn.to_s == ticket.assistant_turn
    final  = body.nil? ? self.body : body
    edited = final != self.body
    was_stale = stale?                                                     # computed BEFORE any status change (v2 R24)
    message = ticket.reply!(final, by: human, files: files.attached? ? files.blobs : [], request:,
                            metadata: { "support_desk" => { "drafted_by" => author_key, "draft_id" => id, "edited" => edited } })
    update!(status: "sent", reviewed_by: human, reviewed_at: Time.current, sent_message: message, sent_body: (final if edited))
    ticket.send(:write_transition!, :draft_sent, actor: human, request:) { { "draft" => id, "assistant" => author_key, "edited" => edited, "was_stale" => was_stale, "message" => message.id } }
  end
  SupportDesk.emit_after_commit(:draft_sent, ticket, self, message, by: human)
  message
end
```

`ticket.reply!(by: human)` inside runs the normal path: `ensure_writable!`,
`apply_reply_policy!` (takes the case over from the assistant, §5.6),
registration, `:agent_replied`; a human `reply!` also **supersedes any other
pending draft** (in `reply_under_lock!` for non-AI actors). `reject!`:
pending → `rejected` + `reviewed_by/at` + `rejection_reason`; Event
`draft_rejected`; emit.

### 5.6 Humans outrank; hand-back

`apply_reply_policy!(actor, request:)`, held-case branch:

```ruby
elsif !assigned_to?(actor)
  if held_by_assistant? && !SupportDesk.ai_actor?(actor)
    assign!(to: actor, by: actor, reason: :drop_in_takeover, request:)    # under every reply_policy
  elsif SupportDesk.ai_actor?(actor)
    raise AssistantNotAllowed.new(assistant_policy(actor), verb: :reply)  # belt; the floor already made this a draft
  else
    case policy … (unchanged)
```

`ensure_assignable!(agent)`: AI-kind ⇒ must be `self.assistant`
(`NotAnAssistant`), then `assistant_policy(agent, hand_back: true).may_hold?`
else `AssistantNotAllowed(:take)`. Inside `assign!` / `hand_off!` when `to`
is the assistant: `update!(human_required_at: nil, human_required_reason:
nil, assistant_paused_at: nil, assistant_paused_reason: nil, assistant_cap:
nil)`, payload `"handed_back" => true`; after the transition, if
`awaiting_reply?` ⇒ `emit_assistant_turn`. An assistant `by:` may `assign!`
only `to: itself`, only when `unassigned?` and `may_hold?`; anything else
⇒ `AssistantNotAllowed`.

A human transition that lowers the effective level below `:reply` while the
assistant holds the case (`change_topic!` onto a capped topic,
`pause_assistant!`, `request_human!`, `escalate!`) releases her seat inside
the same transition (`release_assistant_if_unfit!`, payload
`"assistant_released" => true`).

### 5.7 Hand-offs

```ruby
def flag_human_required!(actor:, kind:, reason:, summary:, line:, request:)   # :nodoc:, caller may or may not hold the lock (write_transition! locks)
  from = nil
  event = write_transition!(kind, actor:, request:) do
    raise InvalidTransition, "can't #{kind} a closed case — reopen it first" if closed?
    next false if human_required?
    from = assignee
    if held_by_assistant?
      assignments.open.each { |a| a.release!(reason: :escalated) }
      update!(assignee: nil)
    end
    update!(human_required_at: Time.current, human_required_reason: reason.to_s,
            priority: [ priority.to_i, Topic::PRIORITIES[:high] ].max)
    { "reason" => reason.to_s, "summary" => summary.presence, "from" => SupportDesk.actor_key(from) }.compact
  end
  return nil unless event
  post_assistant_line!(line) unless requester_unavailable?     # a nil/blank line posts nothing; a rendering error is reported, never raised
  event
end
```

`escalate!(by: nil, reason:, summary: nil, turn: nil, request: nil)`:
`resolve_actor`; `ensure_agent!` (a Symbol passes — `:system` is the
silent-release path); AI-kind ⇒ `resolve_assistant!`, `ensure_current_turn!
(turn)` (required), `may_observe?`; `reason` non-blank; core with `kind:
:escalated`, `line: :hand_off_line`; `stamp_assistant_action!` for an
assistant; emit `:ticket_escalated (self, from:, reason:, by:)`.

`request_human!(by: nil, request: nil)`: `resolve_actor`; must be
`same_actor?(actor, requester)` else `NotAllowed`; **one** `with_lock`:
`reopen!` if `closed? && closed_tickets == :reopen_on_reply` (a `:locked`
desk ⇒ `Locked`), `ensure_writable!`, core with `kind: :human_requested`,
`reason: "requester_request"`, `line: :human_requested_line`; emit
`:human_requested (self, by:, reason: :requester_request)`.

`evaluate_hand_off_phrase!(message)` (in `record_registration!`, requester
role, under the lock): skip when no assistant / `human_required?` /
`!assistant_in_play?` / no block. `result = block.call(self, message)`;
`true` ⇒ core with reason `"phrase"`; `false`/`nil` ⇒ nothing; **anything
else or a raise** ⇒ `SupportDesk.report_error` + core with reason
`"hand_off_when_error"` (fail closed, v2 R28). The core's `write_transition!`
nests inside the registration lock as `announce_assignment!` does today.

### 5.8 Pause, resume, reopen cap, close

`pause_assistant!`: human agents only (`NotAllowed` for AI-kind or Symbol);
transition `assistant_paused`: `InvalidTransition` when closed; no-op when
paused; release her seat if held (`release!(reason: :released)`,
`assignee: nil`); supersede pending drafts; `update!(assistant_paused_at:
now, assistant_paused_reason: reason)`; emit. `resume_assistant!`: clears
the two pause columns only; emit; `emit_assistant_turn` if `awaiting_reply?`.

`restore_assignment!(by:)` (both reopen paths):

```ruby
return if unassigned?
if closed_by_was_assistant                                     # captured from closed_by BEFORE the reopen update cleared it
  cap = [ assistant_cap&.to_sym, :draft ].compact.min_by { |l| RANK[l] }
  update!(assignee: nil, assistant_cap: cap.to_s)              # payload "assistant_capped" => true
elsif assignee.respond_to?(:support_agent?) && assignee.support_agent?
  Assignment.open!(ticket: self, agent: assignee, by:, reason: :reopened)
else
  update!(assignee: nil)
end
```

`close!` by an assistant: `turn:` required and current; `may_close?`;
`assigned_to?(assistant)`; `awaiting_requester?`; `!human_required?`. Any
close: `drafts.pending.each(&:expire!)`, payload `"expired_drafts" => n`.

### 5.9 Disclosure

`announce_assignment!` returns early for AI-kind agents (the disclosure line
is her announcement). `post_disclosure_notice!(assistant)`: `line_for
(:disclosure_line)`; blank ⇒ `raise ConfigurationError` ("a notice mode
needs a disclosure line") — an undisclosed autonomous message is never
posted silently; stamps `metadata["assistant_disclosed"] = { key => version
}` where version is `disclosure.to_s` (a new mode gets its notice once);
`pin_before!(notice, message)` reuses the opening-line tick logic.

### 5.10 Silent release — `SupportDesk.release_silent_assistants!`

For each configured assistant with `responds_within`: candidates =
`Ticket.open.assigned_to(assistant).awaiting_reply.where(waiting_since:
..bound.ago)`; for each, `escalate!(by: :system, reason: "assistant_silent",
summary: "no answer in #{humanized}")` — `flag_human_required!` re-checks
under the lock (`human_required?` ⇒ no-op; a human who took over ⇒
`held_by_assistant?` false ⇒ the seat is not touched, but the requirement is
still recorded — a case that waited that long deserves a person). Count only
committed transitions. Returns the count; logs one line. `:ticket_escalated
(reason: :assistant_silent)` is what a host pages on.

### 5.11 Redispatch — `SupportDesk.redispatch_assistant_turns!(older_than: 1.minute)`

For each desk with an assistant: `Ticket.open.for_desk(key)
.assistant_idle_since(older_than.ago)` (awaiting the desk, last requester
message older than the bound, and no assistant action since it) whose policy
`may_observe?` ⇒ `emit_assistant_turn` (message nil). At-least-once: a
duplicate turn is harmless (I4). Returns the count.

### 5.12 Outreach — `Ticket.open!(by: assistant)`

`ensure_opener!`: AI-kind ⇒ `resolve_assistant!`-style checks against
`desk.assistant`, `may_open_conversations?`, `RANK[autonomy] >= RANK[:reply]`,
`max_turns` budget (`assistant_turns_count` is per ticket, so the check is
against a fresh ticket: always passes unless `max_turns` is 0 — documented).
After `resolve_topic!`: `node.assistant_cap` ≥ `:reply` and `cap` block ≥
`:reply` on the would-be ticket else `AssistantNotAllowed(:open)`. When the
call turns into a **reply into an existing case**, the reply goes through
`reply_under_lock!` with the assistant's full rules (`turn:` is nil here ⇒
the outreach path passes `turn: ticket.assistant_turn` it just read under
the lock — the one place the gem supplies the turn itself, because there is
no prior turn to hold). `post_opening!` posts the disclosure notice before
her message in a notice mode; she is seated `opened`; `assistant_turns_count
= 1`; message metadata as in `speak!`.

---

## 6. Schema and migration

### 6.1 Tables

```
support_desk_assistants
  id, key (string, unique), active (bool, default true, not null), settings (json/jsonb), created_at, updated_at

support_desk_drafts
  id, ticket_id (fk → support_desk_tickets), author_type/author_id (not null),
  reviewed_by_type/reviewed_by_id (null), sent_message_id (chats_messages.id type, null),
  proposed_turn (string, not null), body (text, null — attachment-only drafts), sent_body (text, null),
  status (string, default "pending", not null), confidence (decimal 4,3, null),
  sources (json/jsonb), metadata (json/jsonb), rejection_reason (string), reviewed_at (datetime),
  created_at, updated_at
  indexes: (ticket_id, created_at) · (author_type, author_id, status) · UNIQUE (ticket_id) WHERE status = 'pending' [partial-index adapters]

support_desk_tickets (+)
  assistant_revision (bigint, 0, not null), last_requester_message_id (chats_messages.id type),
  assistant_turns_count (integer, 0, not null), assistant_acted_at (datetime),
  assistant_paused_at (datetime), assistant_paused_reason (string), assistant_cap (string),
  human_required_at (datetime), human_required_reason (string)
  index: (desk_id, human_required_at)
```

### 6.2 Migration template — `add_assistants_to_support_desk.rb.erb`

Idempotent like `add_opened_by_…` (`table_exists?` / `column_exists?` /
`index_exists?` guards on every statement). **Column types are derived from
the columns they reference** (v2 R33): `ticket_id` from
`support_desk_tickets.id`, message ids from `chats_messages.id`, polymorphic
ids from `support_desk_assignments.agent_id`, via a private
`sql_type_of(table, column)` (`connection.columns(table).find { … }.sql_type`)
— never from the current generator setting. New PKs use
`primary_and_foreign_key_types` as every gem migration does. JSON defaults via
the existing helpers; `sources` gets its `[]` default in Ruby.

```ruby
# backfill: the requester pointer for existing cases (ORDER BY, not MAX — uuids)
execute <<~SQL
  UPDATE support_desk_tickets SET last_requester_message_id = (
    SELECT m.id FROM chats_messages m
     WHERE m.conversation_id = support_desk_tickets.conversation_id
       AND m.sender_type = support_desk_tickets.requester_type AND m.sender_id = support_desk_tickets.requester_id
       AND m.kind = 'text'
     ORDER BY m.created_at DESC, m.id DESC LIMIT 1)
   WHERE last_requester_message_id IS NULL AND conversation_id IS NOT NULL
SQL
```

`down`: removes the columns/indexes and drops the two tables — **only**
meaningful before any assistant row exists; the CHANGELOG says a code
rollback keeps the schema.

The migration lives in the three places 12 #15 names (template, dummy copy,
generator test source assertions).

### 6.3 Rolling deploy

Additive columns and tables; no new `Assignment::REASONS` or
`RELEASE_REASONS` value; Event kinds only written by new code. **Rolling-safe
for the schema expansion.** `config.assistant` must be added only after
every process runs 0.3.0 (an old process would `NoMethodError` at boot) —
CHANGELOG step 3.

---

## 7. Surfaces

### 7.1 Console (`app/views/support_desk/console/tickets/`)

| partial | renders |
|---|---|
| `_draft.html.erb` (new; locals `ticket, draft, actions`) | disclosed author name + "Propuesta"; body (pre-wrap); confidence pill; sources (title → url, `rel="noopener"`, http(s) only); attachments (filenames via `console_file_path`); `stale?` block; **Enviar** (`send_draft` with hidden `draft_id` + `seen_turn`), **Editar** (`?compose=reply&draft=ID`), **Descartar** (`reject_draft` + optional `reason`). Buttons only when offered. |
| `_composer.html.erb` | when `params[:draft]` names the pending draft and `:send_draft` is offered: textarea prefilled, hidden `draft_id` + `seen_turn`, posts to `send_draft`, submit "Enviar propuesta editada", "cancelar" link. |
| `_message.html.erb` | staff marks: robot + confidence tooltip when `ticket.assistant_message?(message)`; "propuesta de %{name}" when `metadata.dig("support_desk","drafted_by")`. |
| `_actions.html.erb` | Pausar / Reanudar asistente. |
| `_assignment.html.erb` | option values `SupportDesk.actor_key(agent)`; "%{name} se ocupa · %{used}/%{max} turnos" when `held_by_assistant?`. |
| `_context_card.html.erb` | requester `support_context` pairs; "Asistente: level — because". |
| `_timeline.html.erb` | `Entry#draft?` entries (non-pending drafts, greyed, status + reviewer); new kinds; `escalated` shows `summary` as a callout. |
| `_ticket_row.html.erb` | badges "Necesita persona" / "Propuesta lista"; disclosed assignee name. |

`Index#support_queue_tickets` adds `:pending_draft` to `includes`. `_tabs`
renders `queue.tabs` (data-driven; `visible_tabs` decides `needs_human`).

### 7.2 Requester engine

`_human_door.html.erb` (§4.16); `_ticket_row`: "Atendida por %{name}" when
`held_by_assistant?` (disclosed name — nameless modes show the desk name),
"Una persona del equipo seguirá con tu consulta" when `human_required?`.

---

## 8. Locales

Added to `es.yml` / `en.yml` (Spanish shown). Every key exists in both files
with identical interpolation names; `test/locales_test.rb` asserts parity.

```yaml
es:
  support_desk:
    assistant:
      disclosed_name: "%{name} · asistente virtual"
    system:
      assistant_disclosure: "%{name} es el asistente virtual de %{desk}. Si prefieres hablar con una persona, usa el botón de esta conversación."
      handed_off_to_humans: "Te paso con una persona del equipo."
      handed_off_to_humans_with_promise: "Te paso con una persona del equipo. Normalmente contestamos en menos de %{reply_within}."
      human_requested: "Una persona del equipo seguirá con tu consulta."
      human_requested_with_promise: "Una persona del equipo seguirá con tu consulta. Normalmente contestamos en menos de %{reply_within}."
    thread:
      human_door: "Prefiero hablar con una persona"
      human_requested_notice: "Hecho. Una persona del equipo seguirá con tu consulta."
      handled_by_assistant: "Atendida por %{name}"
      handled_by_humans: "Una persona del equipo seguirá con tu consulta"
    queue:
      tabs:
        needs_human: "Necesitan persona"
    summary:
      needs_human: "necesita una persona"
    console:
      draft:
        title: "Propuesta de %{name}"
        confidence: "confianza declarada %{percent} %"
        sources: "Fuentes"
        attachments: "Adjuntos"
        stale: "La conversación ha cambiado desde esta propuesta. Léela antes de enviar."
        editing: "Editando la propuesta de %{name}"
        cancel_edit: "cancelar"
        reason_placeholder: "¿Por qué la descartas? (opcional)"
      actions:
        send_draft: "Enviar"
        send_edited_draft: "Enviar propuesta editada"
        edit_draft: "Editar"
        reject_draft: "Descartar"
        pause_assistant: "Pausar asistente"
        resume_assistant: "Reanudar asistente"
      badges:
        needs_human: "Necesita persona"
        pending_draft: "Propuesta lista"
        assistant_holds: "%{name} se ocupa · %{used}/%{max} turnos"
        assistant_holds_unlimited: "%{name} se ocupa"
      context:
        assistant: "Asistente"
        requester_context: "Sobre la persona"
      timeline:
        escalated: "%{actor} pasó el caso a una persona: %{reason}"
        human_requested: "El cliente pidió hablar con una persona"
        assistant_paused: "%{actor} pausó el asistente"
        assistant_resumed: "%{actor} reanudó el asistente"
        draft_sent: "%{actor} envió la propuesta de %{assistant}"
        draft_sent_edited: "%{actor} envió la propuesta de %{assistant} (editada)"
        draft_rejected: "%{actor} descartó la propuesta de %{assistant}"
        assistant_withheld: "%{assistant} no respondió: %{reason}"
        draft_superseded: "Propuesta sustituida"
        draft_expired: "Propuesta caducada al cerrar"
      flashes:
        draft_sent: "Propuesta enviada."
        draft_rejected: "Propuesta descartada."
        assistant_paused: "Asistente pausado en este caso."
        assistant_resumed: "Asistente reanudado en este caso."
      errors:
        unknown_draft: "Esa propuesta ya no existe."
        draft_already_reviewed: "Esa propuesta ya se %{status}."
        no_pending_draft: "No hay ninguna propuesta pendiente en este caso."
        stale_turn: "La conversación ha cambiado. Léela y vuelve a enviar."
        assistant_not_allowed: "El asistente no puede hacer eso en este caso."
        not_an_assistant: "Esa acción es solo para el asistente."
      withheld_reasons:
        policy: "la política de este caso no se lo permite"
        not_your_turn: "no era su turno"
```

`because` is internal (staff) prose in English by construction; the console
shows the localized generic sentence and the `because` as a `title=` detail,
never inside the flash (v2 R? — no English-in-Spanish exception).

---

## 9. Harness contract and generator

### 9.1 Contract

1. Subscribe to `:assistant_turn`; enqueue `(ticket.id, assistant.key, turn)`
   — never an AR object, never a prompt.
2. **Check `ticket.assistant_turn == turn` before spending money.** A
   mismatch means the case moved on; the newer turn's job exists.
3. Read `ticket.brief` / `ticket.transcript` — never the chats models.
4. Hand the answer to exactly one of `respond!` (let policy decide),
   `draft!`, `reply!`, `escalate!`, `note!` — all `by: assistant, turn:`.
   Each consumes the turn and returns the successor (`Outcome#turn`,
   `ticket.assistant_turn`); a second action in the same run uses that.
5. Rescue `StaleTurn` and `Locked` as normal outcomes. Let
   `AssistantNotAllowed` surface as a harness bug (the brief said `may_not`).

### 9.2 Generated `app/jobs/support/rose_turn_job.rb`

```ruby
module Support
  class RoseTurnJob < ApplicationJob
    queue_as :support
    discard_on SupportDesk::StaleTurn, SupportDesk::Locked, ActiveRecord::RecordNotFound

    def perform(ticket_id, assistant_key, turn)
      ticket = SupportDesk::Ticket.find(ticket_id)
      return unless ticket.assistant_turn == turn          # the case moved on while we waited
      rose = SupportDesk.assistant(assistant_key)
      return unless ticket.assistant_policy(rose).may_observe?

      answer = Support::Rose.answer(ticket.brief, ticket.transcript)
      case answer.kind
      when :answer   then ticket.respond!(answer.text, by: rose, turn: turn, confidence: answer.confidence, sources: answer.sources, metadata: answer.metadata)
      when :hand_off then ticket.escalate!(by: rose, turn: turn, reason: answer.reason, summary: answer.summary)
      when :note     then ticket.note!(answer.text, by: rose, turn: turn)
      when :nothing  then nil                              # the case stays in the humans' queue; nothing was consumed
      else raise ArgumentError, "unsupported answer kind #{answer.kind.inspect}"
      end
    end
  end
end
```

Retries: the template's comment tells hosts where `retry_on` goes and that
a retry after a committed action is a `StaleTurn` (harmless). `:nothing` is
documented: the assistant did not act, so the idle-turn doctor check will
notice a harness that always returns it.

### 9.3 Generated `app/services/support/rose.rb`

`Answer = Struct.new(:kind, :text, :confidence, :sources, :reason, :summary,
:metadata, keyword_init: true)` with defaults; `self.answer(brief,
transcript)` raises `NotImplementedError` pointing at the README.

### 9.4 Generated test

Stubs `Support::Rose.answer`; opens a case; performs with
`ticket.assistant_turn`; asserts `assert_pending_draft` at the default
`:draft`, `assert_awaiting_requester` under `with_assistant_config(autonomy:
:reply)`, and that a stale turn writes nothing.

### 9.5 Printed initializer stanza

```ruby
  config.assistant :rose do |rose|
    rose.name       = "Rose"
    rose.autonomy   = :draft
    rose.disclosure = :signature_and_notice     # from --disclosure; REQUIRED, no default
    rose.max_turns  = 6
    rose.responds_within = 3.minutes
    # rose.hand_off_when { |_ticket, message| message.body.to_s.match?(/\b(persona|humano|agente)\b/i) }
    # rose.cap { |ticket| :draft if ticket.requester.try(:vip?) }
  end
  config.default_assistant = :rose

  SupportDesk.on(:assistant_turn, key: "support.rose.turn") do |ticket, assistant, _message, turn:|
    Support::RoseTurnJob.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn)
  end
```

Plus the two scheduler lines (solid_queue `recurring.yml` and cron) for
`release_silent_assistants` (every minute) and `redispatch_assistant_turns`
(every 5 minutes).

---

## 10. Compliance and safety

- **Disclosure** (12 #22): required config; four modes; `:none` silent. The
  README describes the visible behaviour of each mode and points hosts to
  their own legal process; the AI-Act reading stays in 14 as rationale, not
  as a gem claim. Nameless modes post `author: nil` with metadata provenance,
  so a customer sees the desk and staff see the truth; `export` says `from:
  "assistant"` in every mode.
- **Bounded authority** (I2, I6, I10): no speaking below `:reply`, no close
  below `:resolve`, no seat below `:reply`, no seat on a human-required or
  paused case, no takeover of a human's case, no assignment of others, no
  triage, no reopen, no approval, no resume, one reply per requester message,
  budget on every path, nothing while inactive.
- **Money and identity**: topic caps by construction (CarHey: `payments
  :draft`, `verification :observe`). Because caps are ancestor-minimums and a
  reopen cap is persisted, a human re-filing a case cannot accidentally hand
  it back to autonomy without a hand-back.
- **What the model sees**: `support_context` is host-authored; the README
  warns in bold; internal notes/drafts are opt-in (`include_internal`).
- **Moderation / audit**: a reported nameless assistant message has
  `reported_owner = sender` (the desk); a signed one has the Assistant author
  — CarHey's Moderate bridge must accept both (§16). `ticket_transitioned`
  fires for every new kind with the assistant as `by:`.
- **Abuse**: `request_human!` is idempotent and scoped to the requester's own
  case; nothing requester-reachable makes the assistant speak.

---

## 11. Evidence and operations

| where | what |
|---|---|
| message `metadata["support_desk"]` (autonomous) | `assistant`, `kind`, `display_name`, `disclosure`, `signed`, `turn`, `confidence`, `sources`, `policy` (+ `metadata["host"]`) |
| message `metadata["support_desk"]` (human-sent draft) | `drafted_by`, `draft_id`, `edited` |
| draft row | body/files, confidence, sources, `metadata.policy`, `proposed_turn`, status, reviewer, `sent_body`, `rejection_reason` |
| Events | `assistant_withheld {assistant, reason, policy}`; `escalated` / `human_requested {reason, summary, from}`; `assistant_paused {reason}` / `assistant_resumed`; `draft_sent {draft, assistant, edited, was_stale, message}` / `draft_rejected {draft, assistant, reason}`; `reopened {assistant_capped}`; `closed {expired_drafts}`; `assigned {handed_back}`; `topic_changed {assistant_released}` |

Scopes for the day-one numbers (definitions in the README, denominators
explicit): reviewed drafts and their verbatim / edited / rejected split;
`resolved_by_assistant.where(reopen_count: 0)` within a window as a
*containment* proxy (labelled as such); escalations by reason (`Event
.of_kind(:escalated)` grouped in Ruby by `payload["reason"]`).

---

## 12. Test plan

The suite is 804 tests on SQLite + PostgreSQL × Rails 7.2/8.0/8.1. Additions:

### 12.1 I1 — nothing changes without an assistant
Full story (open → reply → assign → close → reopen → export), asserting: no
Assistant/Draft rows; no new Event kinds; `capture_support_events(*NEW)`
empty; no system line beyond 0.2's; `desk.agents == desk.humans`;
`actions_for(lucia)` = the 0.2 set; `queue.visible_tabs` = the 0.2 tabs;
`assistant_revision` bumps are the only new column writes.

### 12.2 Configuration
Every setter (good / bad / nil); `disclosure` missing ⇒ `ConfigurationError`
naming the modes; two assistants without `default_assistant` ⇒ error;
`desk.assistant = :nope` ⇒ error; explicit `desk.assistant = nil` disables
while the default desk keeps hers; implicit single default; line settings;
topic `assistant:` validation and **ancestor-minimum**; `Unknown → :observe`;
`kind: :bot` ⇒ error.

### 12.3 Policy table
autonomy(5) × topic cap(nil+4) × `cap` block(nil, :draft) × case cap(nil,
"draft") × pause(no, yes) ⇒ level + `because` names the deciding ceiling
(ties: Hash order); floors alone and stacked; `hand_back: true` ignores
pause/case cap/human_required/holder but not autonomy/topic/cap/inactive/
closed; Null for no assistant and for the wrong desk's assistant; `to_h`.

### 12.4 Verb matrix (assistant actor)
Each level × each verb of `VERBS_BY_LEVEL[:resolve]` + `change_topic!`,
`attach_subject!`, `hand_off!`, `reopen!`, `assign!(to: lucia)`,
`assign!(to: self)` on a human-held case, `Draft#send!`, `pause/resume` ⇒
allowed or `AssistantNotAllowed` with `because`/`verb`; a host `kind: :ai`
model ⇒ `NotAnAssistant` on every verb; desk B's ticket with desk A's
assistant ⇒ `NotAnAssistant`; `actions_for(rose)` equals the adjusted verbs
state by state (extension of `console_offered_actions_test`).

### 12.5 `respond!` matrix
level(observe/draft/reply/resolve) × holder(none/rose/lucia) ×
awaiting(agent/requester) × budget(some/zero/nil) ⇒ sent / drafted /
withheld(reason); zero budget at `:reply` ⇒ drafted + escalated (seat
released, `human_required`, priority high, line once); `sent` ⇒
`assistant_turns_count` +1, metadata complete, seated `taken`, no
announcement, notice once and pinned before the bubble under frozen time,
`first_agent_reply_at`, `:agent_replied`, `Outcome#turn` == new
`assistant_turn`; nameless modes ⇒ `author nil`, metadata provenance,
`assistant_message?` true, no signature in `Chats.message_signature_for`;
`drafted` supersedes the previous pending; `withheld` writes the Event;
`by:` a User ⇒ `NotAnAssistant`; blank ⇒ `ArgumentError`; closed account ⇒
`Locked`; `turn: nil` ⇒ `ArgumentError`.

### 12.6 Turn, revision, concurrency
Revision bumps on: requester message, agent message, each transition (not a
no-op), draft; `assistant_turn` changes accordingly; a redelivered job (same
turn after a committed action) ⇒ `StaleTurn`, nothing written;
`reconcile_unregistered_messages!`: a requester message inserted directly
(bypassing the subscriber) is folded in and makes the turn stale; same-
timestamp distinct messages both register; replay of an older id skipped;
`:assistant_turn` emitted for the opening message, later messages, on
hand-back/resume when awaiting, by redispatch; not at `:off`/paused/desk
without assistant; still at `:observe` when human required. **PostgreSQL
threads:** two `respond!` with the same turn ⇒ one message; `respond!`
racing a requester `message!` ⇒ either one reply that precedes the message
(then a new turn) or `StaleTurn` — never two assistant messages; two
`draft!` ⇒ one pending; sweep vs takeover ⇒ human seat untouched. SQLite:
the same scenarios sequentially plus busy-timeout tolerance.

### 12.7 Drafts
Statuses/scopes; `stale?` (turn-based, incl. a human note making it stale);
`send!` verbatim / edited (metadata, `sent_body`, takeover of her seat,
`draft_sent` payload incl. `was_stale`); `send!` with an old `seen_turn` ⇒
`StaleTurn`; with the current one after a stale proposal ⇒ allowed;
`body: ""` ⇒ `ArgumentError`; by an assistant/Symbol ⇒ `NotAllowed`;
non-pending ⇒ `InvalidTransition`; `reject!`; attachment-only draft and
attachments copied to the sent message; invalid sources refused (javascript:
URL, > 20, long title); `close!` expires; pause supersedes; a human plain
`reply!` supersedes; `pending_draft` preload; Timeline entries.

### 12.8 Hand-offs
`escalate!` by rose (turn required; seat released `escalated`; flags;
priority; pending draft kept; line; event with summary; emit); idempotent;
on a human-held case flags without releasing; closed ⇒ `InvalidTransition`;
by a human / `:system` ⇒ allowed; `request_human!` by the requester (flag,
event, line, emit); by another user ⇒ `NotAllowed`; closed `reopen_on_reply`
⇒ reopen+flag atomically; `:locked` desk ⇒ `Locked`; no assistant on the
desk ⇒ flags, no line. `hand_off_when`: true ⇒ `phrase`; false/nil ⇒
nothing; `"yes"` or a raise ⇒ `hand_off_when_error` + `human_required`,
message preserved. Humans outrank: human reply under `:assignee_only` on an
AI-held case ⇒ takeover; `may_reply?(lucia)` true. Hand-back:
`hand_off!(to: rose, by: lucia)` clears all three columns, payload
`handed_back`, emits a turn when awaiting; refused by topic cap; `assign!
(to: rose, by: admin)` same; rose `assign!(to: lucia)` ⇒ refused.

### 12.9 Pause, cap, close, silent, redispatch, outreach
Pause releases her seat + supersedes drafts + floors to off + blocks turns;
by rose ⇒ `NotAllowed`; resume clears pause only (cap and human_required
stay) and emits a turn when awaiting; reopen after AI close ⇒ unassigned +
cap `draft` (+ `assistant_capped`), her next `respond!` drafts; reopen after
a human close restores the human's seat (regression); existing cap
`observe` is kept (min); `close!` by rose needs turn/held/awaiting_requester/
no human_required; expired drafts payload. `release_silent_assistants!`:
releases + requires a human only past the bound, count of committed
transitions, `responds_within nil` skipped, a takeover before the lock ⇒
seat untouched but requirement recorded. `redispatch_assistant_turns!`
emits only for idle turns (a proposed draft or a note counts as acted).
Outreach: refused unless `may_open_conversations` and autonomy/topic/cap ≥
`:reply`; when allowed: seated `opened`, notice before the message, turns
count 1, no turn emitted until the requester replies; reply into an existing
case obeys the full rules.

### 12.10 Console, engine, queue
Offered-actions table gains the four verbs (with/without pending draft,
paused, closed, requester unavailable, `:assignee_only` with an AI holder)
and the assistant table; both checked against the method and over HTTP;
routes test; `send_draft` verbatim / edited / stale (422 with text + new
`seen_turn`) / unknown / already sent (`draft_already_reviewed`) / non-String
id; reject with reason; pause/resume; picker actor keys, bare-id fallback
only when unique (User#1 vs Assistant#1 ⇒ "1" refused); `needs_human` tab
shown only with an assistant or rows; browser test: draft card, Enviar,
Editar prefill, Descartar, stale warning after `ask_again`; engine
`request_human` own/foreign; door partial states.

### 12.11 Context, export, locales, docs, generators, doctor, rake
Transcript roles (incl. `assisted`, nameless assistant via metadata,
tombstones, attachments, `since`, `last`, deterministic `to_text`); Brief
shape, `may`/`may_not`, `include_internal` gating, requester/subject
`support_context`; `export` `from: "assistant"` in every mode; locale parity
es/en; `docs_test` for the README snippets (config, job, `respond!`,
`Draft#send!`); install/upgrade copy once + type derivation asserted on the
dummy schema (bigint) and on a uuid dummy variant (Appraisal-style extra leg
or a migration unit test with a stubbed connection); assistant generator
(required flag, no writes without it, name-specific files, no overwrite);
doctor checks red/green; the three rake tasks.

### 12.12 Gates
`bundle exec rake test` on SQLite and PostgreSQL, the three Appraisals,
rubocop, `docs_test`; coverage ≥ current; the dummy schema dump removed
between legs as today.

---

## 13. Compatibility, upgrade, CHANGELOG

### 13.1 Changes regardless of configuration
Schema (§6); `acts_as_support_agent kind:` validated (`:human`/`:ai`); a
host `kind: :ai` model is **refused for every support write** (was: treated
as a human); console picker values are actor keys (bare ids accepted for one
release when unambiguous); `assistant_revision` is written by every
registration/transition; `Queue::TABS` gains `:needs_human` (hidden unless
relevant).

### 13.2 Changes only when an assistant is configured
`Desk#agents` includes her (page people with `agents_to_notify` /
`desk.humans`); `announce_assignments` never announces her; humans take over
her cases under every `reply_policy`; a human `reply!` supersedes pending
drafts; reopen after her close ⇒ unassigned + `draft` cap; `close!` expires
drafts; `Ticket#reply!` / `post_agent_message!` accept `metadata:` and
`turn:`.

### 13.3 Upgrade
1. `bundle update support_desk` (0.3.0). 2. `rails g support_desk:upgrade`
→ `db:migrate` (additive, rolling-safe). 3. Deploy **all** processes to
0.3.0 before adding `config.assistant`. 4. `rails g support_desk:assistant
Rose --disclosure …`, paste the stanza, wire the job, schedule the two tasks,
subscribe notifiers to `draft_proposed` / `ticket_escalated` /
`human_requested`. 5. Render `_human_door` in your thread. 6.
`SupportDesk.doctor` green. 7. Start at `:draft`; raise `autonomy` when the
acceptance rate on reviewed drafts says so, keeping topic caps on money and
identity.

### 13.4 Rollback
`rose.deactivate!` is the kill switch (cross-process, no deploy); a code
rollback to 0.2 keeps the schema (columns are nullable; the two tables are
ignored) but loses the provenance rendering of assistant messages — do it
only if 0.3 itself is broken.

### 13.5 CHANGELOG (draft, 0.3.0)
Added / Changed / Upgrading per §4, §13.1–13.3, in the CHANGELOG's existing
voice; explicitly lists the `kind: :ai` behaviour change and the picker
values.

---

## 14. README

New section **"🤖 Assistants"**: the two-minute story; levels table;
ceilings/floors; `respond!` outcomes; drafts in the console; the two exits;
disclosure — four modes, required choice, "your legal process decides";
the turn (why every action needs it, what stale means); the two maintenance
tasks and why; "What the model sees" (bold warning); "Before you launch"
(doctor, moderation owner, notifiers, the door, scheduler); reference tables
for every public name in §4; upgrade notes. `docs_test` pins the snippets.

---

## 15. Delivery

| PR | contents | gate |
|---|---|---|
| **A — kernel** | §4.1–4.5, 4.7, 4.11–4.14, 4.21; §5 all; §6; doctor; rake tasks; TestHelpers; tests §12.1–12.9, 12.11 (doctor/rake/migration) | invariant-1 test; policy/verb/outcome matrices; PG + SQLite concurrency; Appraisals |
| **B — surfaces** | §4.6 console parts, 4.15–4.17, §7, §8; tests §12.10 + locale parity | offered-actions both ways; browser test on the CI matrix |
| **C — context + DX** | §4.8–4.10, 4.20, §9, §14; CHANGELOG; VERSION 0.3.0; tests §12.11 (context, docs, generator) | docs_test; README covers every public name (grep audit) |
| **release** | tag `v0.3.0`, GitHub release, `.gem` built | rubygems push needs the owner's MFA |
| **D — CarHey** | §16 | `bin/ci` in an isolated-DB worktree; the PR pins the released gem |

---

## 16. CarHey integration — "Rose"

### 16.1 Configuration

```ruby
config.assistant :rose do |rose|
  rose.name            = "Rose"
  rose.avatar          = "rose-avatar.png"                # brand mark, not a face
  rose.autonomy        = :draft                            # soak: every word human-sent. Later :reply — the GLOBAL ceiling; topics only cap DOWN
  rose.disclosure      = :signature_and_notice             # OWNER'S CHOICE — placeholder until confirmed; boot fails without one
  rose.max_turns       = 6
  rose.responds_within = 3.minutes
  rose.hand_off_when { |_t, m| m.body.to_s.match?(/\b(persona|humano|agente|alguien de verdad)\b/i) }
  rose.cap { |ticket| :observe unless ticket.requester.support_contactable? }
end
config.default_assistant = :rose

config.topics do
  topic :ride,         about: Ride,                icon: "map"
  topic :payments,     about: Payouts::Withdrawal, icon: "banknotes",           assistant: :draft    # money: never autonomous
  topic :verification,                             icon: "identification",      assistant: :observe  # identity: triage by humans
  topic :account,                                  icon: "user-circle"
  topic :app,                                      icon: "device-phone-mobile"
  other                                            icon: "lifebuoy"
end

SupportDesk.on(:assistant_turn,   key: "support.rose.turn")     { |t, a, _m, turn:| Support::RoseTurnJob.set(wait: 20.seconds).perform_later(t.id, a.key, turn) }
SupportDesk.on(:draft_proposed,   key: "support.rose.draft")    { |t, d| Support::DraftProposedNotifier.with(ticket: t, record: d).deliver(t.agents_to_notify) }
SupportDesk.on(:ticket_escalated, key: "support.rose.escalate") { |t, from:, reason:, by:| Support::NeedsHumanNotifier.with(ticket: t, record: t, reason:).deliver(t.agents_to_notify); Operations::SupportTicketAlertJob.perform_later(t.id, escalated: reason.to_s) }
SupportDesk.on(:human_requested,  key: "support.rose.human")    { |t, by:, reason:| Support::NeedsHumanNotifier.with(ticket: t, record: t, reason:).deliver(t.agents_to_notify) }
```

Note the global/topic relationship (v2 R42): topics can only cap **down**,
so promoting `app` to autonomous replies means `rose.autonomy = :reply` plus
`assistant: :draft` on every topic that must stay human-sent (`ride`,
`account`, `other` — decide each explicitly at that moment).

`User#support_context` (new): account age, KYC **status**, completed rides
count, withdrawals count, wallet balance as a formatted string — statuses and
counts only; no DNI, IBAN or document images. Each reader must exist in
`User` (verify names against source when implementing, not this doc).

### 16.2 Harness
`Support::RoseTurnJob` (generated), `queue_as :support` on solid_queue.
`Support::Rose.answer(brief, transcript)`: `Ai::Client.anthropic` (CarHey's
single client seam; model chosen in the host — `claude-sonnet-5` as the
starting point); Spanish; structured `Answer`; system prompt in
`app/prompts/support/rose.md.erb` reads `may`/`may_not` from the brief;
tools read-only and requester-scoped: `search_help` over **published** help
content in `app/content/help/` (curated from carhey-business through the
site's normal publication path, never the repo directly), `lookup_ride(id)`,
`lookup_withdrawal(id)` returning the same `support_context` maps the console
shows; confidence floored to 0.5 without a cited source; < 0.6 ⇒
`:hand_off` with a one-paragraph summary; total turn budget (retries +
retrieval + queue wait) kept under `responds_within`.

### 16.3 madmin and chats views
Eject/restyle `_draft`; `_message` shows the robot mark and "propuesta de
Rose" (staff only); `_actions` Pausar/Reanudar; `_ticket_row` badges;
`_assignment` actor keys; the door in the ejected
`chats/conversations/show.html.erb` when the subject is a ticket.

### 16.4 Before flipping on
Moderate bridge accepts an Assistant author and a desk-sender nameless
message (`reported_owner`); AuditLog handler keeps the assistant actor key;
legal repo records the disclosure choice; `User#support_context` PII review;
staging: report a Rose message, kill the job worker and watch the silent
release + doctor.

### 16.5 Rollout
1. Deploy 0.3.0 with no assistant (rolling). 2. Rose at `:draft` everywhere
(verification `:observe`); two weeks; watch verbatim/edited/rejected and
rejection reasons. 3. If `app`/`account` drafts are accepted verbatim ≥ 80 %
with no factual rejection: `autonomy = :reply` + explicit `:draft` caps on
`ride`, `other`; two weeks; watch escalations by reason, `needs_human`,
silent releases (must be 0). 4. `:resolve` only for `app`, `max_turns 4`,
after another soak. 5. `payments` / `verification` never move.

---

## 17. Edge-case register (each row → §12)

| # | scenario | expected |
|---|---|---|
| 1 | 3 requester messages in 10 s | 3 turns; the first two jobs exit on the cheap turn check |
| 2 | model answers after the requester wrote more | `StaleTurn`; nothing written; the newer job answers |
| 3 | requester message committed by chats but not yet registered when `respond!` locks | `reconcile_unregistered_messages!` folds it in ⇒ `StaleTurn` |
| 4 | human takes over mid-generation | floor `:draft` ⇒ draft for that human |
| 5 | human pauses mid-generation | withheld(`:policy`), `because` "paused on this case" |
| 6 | account closes mid-turn | `Locked`; job discards |
| 7 | Rose resolves; requester replies "no funcionó" | reopened, unassigned, cap `draft`, `assistant_capped` |
| 8 | harness dead | `awaiting` tab shows the case; after `responds_within` the sweep releases + requires a person; doctor red; redispatch re-emits idle turns |
| 9 | job retried after a committed action | `StaleTurn`; no duplicate draft/note/message |
| 10 | draft approved after somebody closed the case | expired; `send!` ⇒ `InvalidTransition` |
| 11 | Rose escalates a case Lucía holds | flag + summary + priority; Lucía keeps the seat |
| 12 | door pressed twice | idempotent |
| 13 | model says "close it" at `:reply` | `AssistantNotAllowed`; the brief said `may_not: [close]` |
| 14 | `hand_off_when` raises / returns `"yes"` | reported; `human_required` (`hand_off_when_error`); message kept |
| 15 | `cap` returns garbage | `ConfigurationError` in `respond!`; reported + no turn in emission |
| 16 | Rose deactivated | `on_duty?` false ⇒ no verbs, no turns; sweep releases + requires a person; rows stay |
| 17 | reported Rose message | signed: Assistant author; nameless: desk sender — host bridge handles both |
| 18 | User#1 and Assistant#1 in the pool | actor keys; bare "1" refused |
| 19 | human replies while a draft is pending | draft superseded |
| 20 | requester asks for a person while Rose is generating | flag first ⇒ `respond!` sees `:observe` ⇒ withheld; or reply first ⇒ then flag; never a reply after the flag |
| 21 | human moves `app` → `payments` while Rose holds it | her seat released (`assistant_released`); next turn drafts |
| 22 | desk A's assistant on desk B's ticket | `NotAnAssistant` |
| 23 | host `kind: :ai` model calls `reply!` / `Draft#send!` | `NotAnAssistant` / `NotAllowed` |
| 24 | frozen clock / UUID ids | notice pinned one tick before the bubble; same-timestamp messages both registered |
| 25 | requester-opened case with no message | no turn; the harness never runs |
| 26 | outreach on a capped topic | `AssistantNotAllowed(:open)` |
| 27 | MySQL host | supersede-then-create under the row lock; `doctor` checks the one-pending rule |
| 28 | mode changed from `:signature` to `:none` | old messages keep their author/signature (historical); new ones nameless |
| 29 | human hands back a case whose topic caps at `:draft` | refused, flags intact |
| 30 | `respond!` with files at `:draft` | attachment-only or text+files draft; files copied on send |

---

## 18. Deferred (explicit)

Work/claim/lease and receipt tables; draft revisions and approve/publish
split; multiple keyed human requirements; AI triage; host domain
authorization hook; activation epochs / policy versions; chats transactional
write wrapper and thread slot; several assistants per desk; human "save as
draft"; saved replies as `respond!(saved_reply:)` (0.4 macros); streaming;
CSAT; `Metrics`; `by: :system` as an opener.

---

## Appendix A — configuration example

```ruby
SupportDesk.configure do |config|
  config.requester_class = "User"
  config.agents { User.admin }
  config.name = "Soporte CarHey"

  config.assistant :rose do |rose|
    rose.name            = "Rose"
    rose.autonomy        = :reply
    rose.disclosure      = :signature_and_notice
    rose.max_turns       = 6
    rose.responds_within = 3.minutes
    rose.hand_off_line   = "Te paso con una persona del equipo. Normalmente contestamos en menos de %{reply_within}."
    rose.hand_off_when { |_t, m| m.body.to_s.match?(/\b(persona|humano|agente)\b/i) }
    rose.cap { |ticket| :observe if ticket.requester.try(:banned?) }
  end
  config.default_assistant = :rose
  config.desk(:billing) { |desk| desk.assistant = nil }      # explicitly no assistant here

  config.topics do
    topic :payments, about: Payouts::Withdrawal, assistant: :draft
    topic :verification,                         assistant: :observe
    topic :app                                              # inherits the global :reply
    other                                        assistant: :draft
  end
end

SupportDesk.on(:assistant_turn, key: "support.rose.turn") { |t, a, _m, turn:| Support::RoseTurnJob.set(wait: 20.seconds).perform_later(t.id, a.key, turn) }
```

## Appendix B — sequences

```
B1  requester message → autonomous reply (:reply, unassigned)
  requester.message! → chats commit → :message_created → register! (lock): last_requester_message_id, awaiting=agent, revision r→r+1, hand_off_when? no
  announce_registration: :requester_replied, :assistant_turn(turn "t1-r5")            [after commit]
  job (20 s): assistant_turn == "t1-r5"? → model → Answer(:answer, 0.9)
  respond!(text, by: rose, turn: "t1-r5") (lock): reconcile (nothing new) · turn ✓ · writable ✓ · policy :reply · awaiting_reply ✓ · budget 6
     speak!: notice (pinned) → assign!(to: rose) [taken, no announcement, revision +1] → messages.create!(sender: desk, author: rose, metadata) → register (awaiting=requester, +1) → turns=1 → acted_at
  after commit: :ticket_assigned, :agent_replied · Outcome(sent, turn "t1-r7")

B2  :draft → human sends edited
  … :assistant_turn → respond! → policy :draft ("topic payments caps rose at draft") → propose_draft!(proposed_turn "t1-r5") → revision +1 → :draft_proposed
  Lucía opens the case (renders seen_turn "t1-r6"); Editar → composer → POST send_draft(draft_id, seen_turn, body)
  Draft#send!(by: lucia, seen_turn: "t1-r6", body:) (lock): reconcile · pending ✓ · seen_turn == "t1-r6" ✓ · was_stale=false
     ticket.reply!(final, by: lucia, metadata{drafted_by, draft_id, edited: true}) → apply_reply_policy!: unassigned → assign!(to: lucia) [taken, announced] → register
     draft → sent(sent_body) · Event draft_sent · :draft_sent
  requester sees "— Lucía G."

B3  hand-off from the assistant
  respond!… Answer(:hand_off) → escalate!(by: rose, turn:, reason:, summary:) → flag_human_required! (lock): release rose (escalated) · human_required · priority high · Event escalated{summary}
     → hand-off line → :ticket_escalated → host pages humans; needs_human tab; first in next

B4  the customer asks for a person
  POST /support/tickets/:id/request_human → request_human!(by: alice) (one lock): reopen? · writable · flag (human_requested) · line · :human_requested
  next requester message → :assistant_turn at :observe (notes only)

B5  silent assistant
  rose holds T-1 awaiting since 10:00; harness down. 10:03 cron → release_silent_assistants! → escalate!(by: :system, reason: "assistant_silent") → seat released + person required → :ticket_escalated → paged; doctor red 10:03→then
```

## Appendix C — file map

```
lib/support_desk.rb                                  + assistant/reset_assistants!/ai_actor?/release_silent_assistants!/redispatch_assistant_turns!/report_error
lib/support_desk/configuration.rb                    + AssistantConfiguration, Configuration#assistant(s)/assistant?/default_assistant, DeskConfiguration#assistant(=)/assistant_key, validate! rules
lib/support_desk/topic.rb · topic_tree.rb            + assistant: option (ancestor-min cap), Unknown → :observe
lib/support_desk/macros.rb                           + kind validation
lib/support_desk/assistant_policy.rb                 NEW
lib/support_desk/outcome.rb · transcript.rb · brief.rb   NEW
lib/support_desk/models/assistant.rb · draft.rb      NEW
lib/support_desk/models/ticket.rb                    + columns, scopes, readers, verbs, gates (extract lib/support_desk/models/ticket/assistance.rb concern)
lib/support_desk/models/desk.rb                      + assistant/assistant?/humans/agents
lib/support_desk/models/event.rb                     + kinds, requester_visible, #summary
lib/support_desk/models/concerns/requester.rb        + support_context
lib/support_desk/events.rb · errors.rb               + catalogue · NotAnAssistant/AssistantNotAllowed/StaleTurn
lib/support_desk/console.rb · console_routes.rb      + verbs, actions, picker keys
lib/support_desk/queue.rb · timeline.rb · context_card.rb · summary.rb · doctor.rb · test_helpers.rb   + per §4
lib/support_desk/engine.rb                           + to_prepare reference to Assistant
lib/tasks/support_desk.rake                          + three tasks
lib/generators/support_desk/templates/add_assistants_to_support_desk.rb.erb   NEW
lib/generators/support_desk/{install,upgrade}_generator.rb                     + copy it
lib/generators/support_desk/assistant_generator.rb + templates/assistant/*     NEW
app/controllers/support_desk/tickets_controller.rb   + request_human
app/views/support_desk/console/tickets/_draft.html.erb                          NEW (+ _composer, _message, _actions, _assignment, _context_card, _timeline, _ticket_row)
app/views/support_desk/tickets/_human_door.html.erb                             NEW (+ _ticket_row)
config/locales/{es,en}.yml · config/routes.rb
test/… (§12) · README.md · CHANGELOG.md · lib/support_desk/version.rb (0.3.0)
```
