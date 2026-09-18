# PRD — Assistants: AI agents as a first-class use case of `support_desk` (0.3.0)

*2026-09-18. Implements the design record in 14 with the owner decisions
recorded in 12 #19–22. This document is the implementation contract: an
engineer (or an agent) implements exactly this, and the review checks the
result against it line by line, the way 13 was used for writing-first.*

---

## Table of contents

0. Status, scope, decisions, non-goals
1. Problem and goals
2. Vocabulary
3. Architecture and invariants
4. Public API reference (complete)
5. Algorithms, in full
6. Data model and migration
7. Surfaces: console, requester engine, queue
8. Locales
9. The host harness contract and the generator
10. Compliance and safety
11. Observability: events, payloads, scopes, doctor
12. Test plan
13. Compatibility, upgrade, CHANGELOG
14. README additions
15. Delivery plan and acceptance gates
16. CarHey integration ("Rose")
17. Edge-case register
18. Deferred, explicitly
Appendix A — full configuration example
Appendix B — sequences
Appendix C — file map

---

## 0. Status, scope, decisions, non-goals

**Status.** Design approved (14), decisions taken (12 #19–22). Nothing in this
PRD is implemented. Target: `support_desk` **0.3.0**, plus `chats` **0.3.3**
for two one-line seams (§4.22).

**Scope.** Everything a host needs so that *any* LLM harness — any provider,
any prompt, any retrieval — can act as a support agent **safely**: identity,
permission, turn, review, context, the two exits, evidence, surfaces, tests,
docs. The gem ships **no model call, no prompt, no retrieval, no job loop**.

**Decisions already taken (do not reopen):**

| # | decision |
|---|---|
| 12 #19 | The persona is `SupportDesk::Assistant`, a gem-shipped record (Desk pattern). 04's `Bot` + `responder_class` are superseded. |
| 12 #20 | An approved draft is **authored by the human who sent it**; provenance lives in `metadata: { drafted_by, draft_id, edited }`. |
| 12 #21 | A case the assistant closed that the requester reopens comes back **unassigned with the assistant capped at `:draft`** on that case. |
| 12 #22 | **Disclosure has no default.** `disclosure=` is required on every assistant; omitting it fails boot; `:none` is explicit and silent. |

**Defaults taken by recommendation (14 §17):** default autonomy `:draft`;
`responds_within` 3 minutes with a scheduled release task; proactive outreach
off (`may_open_conversations = false`); stale drafts need `even_if_stale:
true`; levels `off / observe / draft / reply / resolve`; `hand_off_when` is a
gem-side host block evaluated before the model runs.

**Non-goals (0.3.0):** saved replies / macros (0.4), CSAT, duty tables and
routing strategies (0.4 — `config.routing` procs stay accepted and
un-invoked, as today), multiple assistants per desk, human-authored drafts
("save as draft"), attachments on drafts, an evaluation harness, streaming.

**Hard requirement:** a host that configures no assistant sees **zero**
behaviour change: same queries, same events, same messages, byte for byte.
§12.1 has the test that proves it.

---

## 1. Problem and goals

### 1.1 Problem

The gem models humans well and machines not at all. `acts_as_support_agent
kind: :ai` is a label nothing reads. A host wiring an LLM to `ticket.reply!(by:
bot)` today ships a bot with a senior human's authority (it can close any
case, hold any case invisibly, answer a money dispute) and gives the customer
no way to reach a person. Every host would rebuild the same guardrails, each
slightly differently, each untested against the transitions' real states.

### 1.2 Goals, as user stories

**Host developer** — "I want to write one job that calls my model and hands
the answer back, and have the gem decide what is allowed to happen with it,
so I never encode policy in a prompt."

**Human agent** — "I want the assistant's proposal waiting in the case with
one button to send, one to edit, one to discard; I want to see who wrote every
bubble; I want to pause it on a case that is getting delicate; I want cases
the customer escalated to jump to the top."

**Requester** — "I want to know when I am talking to an assistant, I want a
way to a person that always works, and I never want two answers to one
question."

**Owner / compliance** — "I want disclosure to be an explicit product
decision, the customer's transcript to say which words a machine wrote, every
machine action to be in the audit chain with the rule that allowed it, and
money topics to be human-sent by construction, not by prompt."

**Operations** — "If the harness dies, cases must surface to humans within
minutes and the health check must go red; a redelivered or late job must never
double-post."

### 1.3 Success criteria

- A harness of ≤ 30 lines (§9) is enough to run an assistant at every level.
- Every policy refusal is deterministic, named, and tested state by state.
- Zero double answers in the concurrency tests (§12.6).
- `SupportDesk.doctor` is red within `responds_within` of a dead harness.
- CarHey runs "Rose" at `:draft` for two weeks with an acceptance rate in the
  console, then moves two topics to `:reply` with no code change (§16).

---

## 2. Vocabulary

| term | meaning |
|---|---|
| **assistant** | a `SupportDesk::Assistant` record: an agent (`acts_as_support_agent kind: :ai`) with configured behaviour. One per desk in 0.3.0. |
| **level** | one of `:off :observe :draft :reply :resolve`, ordered. What the assistant may *produce* at most. |
| **ceiling** | a rule that lowers the level from the assistant's configured `autonomy`: a topic cap, the `cap` block, a per-ticket override. |
| **floor** | a rule that lowers the *effective* level because of case state: the case is closed, a person was requested, a human holds it, the assistant is inactive. |
| **effective level / policy** | `ticket.assistant_policy`: the result of ceilings then floors, with `because`. |
| **turn** | the moment after a requester message registers when the assistant should act; `ticket.assistant_turn` is its token (the last requester message id). |
| **stale** | a turn token that no longer matches: the requester wrote since. |
| **speak** | write a message the requester sees, as the desk, authored by the assistant. |
| **draft** | a proposed reply a human sends, edits or rejects. One pending per case. |
| **hand-off** | the assistant giving the case to humans (`escalate!`); the customer asking for a person (`request_human!`). |
| **human required** | the case state after either; floors the assistant at `:observe`. |
| **pause** | a per-case human override to `:off`. |
| **hold** | an open `Assignment` row: who owes the next word. The assistant holds a case only at `:reply`+. |
| **harness** | the host's job: builds the prompt from `brief` + `transcript`, calls a model, hands the answer to `respond!`/`escalate!`. |

---

## 3. Architecture and invariants

### 3.1 Layers

```
host harness (job, provider, tools, prompt)            ← host
────────────────────────────────────────────────────────
:assistant_turn  →  ticket.brief / ticket.transcript   ← gem: context
ticket.respond! / draft! / reply! / escalate!          ← gem: verbs, policy-gated in the model
SupportDesk::AssistantPolicy                           ← gem: ceilings + floors + because
SupportDesk::Draft  ·  console review verbs            ← gem: human in the loop
SupportDesk::Assistant  ·  config.assistant            ← gem: identity + disclosure
Ticket transitions · Assignment · Event · chats        ← existing kernel, unchanged semantics
```

### 3.2 Invariants (each has a test in §12)

1. **No assistant configured ⇒ nothing changes.** No new query, event,
   system line or column write on any existing path.
2. **Policy is enforced in the model.** Every assistant-actor transition
   (`reply!`, `close!`, `assign!`, `hand_off!`, `note!`, `change_topic!`,
   `attach_subject!`, `draft!`, `respond!`) consults `assistant_policy` under
   the row lock and raises `AssistantNotAllowed` naming `because`. Console
   sugar and harness sugar never decide.
3. **`actions_for(agent)` stays the single boundary.** For an assistant it
   returns exactly the policy's verbs adjusted for state; for a human it gains
   the review verbs. The console offers and accepts exactly that set.
4. **One reply per requester message.** An assistant speaks only when
   `awaiting_reply?`; a stale turn writes nothing; a redelivered job writes
   nothing.
5. **One pending draft per case**, enforced by a partial unique index where
   the adapter can and by the model + `doctor` where it cannot (12 #13).
6. **Humans outrank assistants.** A human reply on an assistant-held case
   takes it over under every `reply_policy`. A human hands back only
   explicitly (`hand_off!(to: assistant)` / `assign!(to: assistant)`).
7. **An assistant holds a case only where it may answer it** (`:reply`+),
   and never a human-required case.
8. **A silent assistant never hides a case.** `responds_within` bounds how
   long an assistant-held, awaiting case stays out of humans' `mine` /
   `unassigned`; `Queue#awaiting` shows it throughout; `doctor` fails past
   the bound.
9. **Authorship is accountability.** Autonomous ⇒ `author: assistant`.
   Approved draft ⇒ `author: the human`, provenance in `metadata`.
10. **Every machine decision is persisted where it was made** — message
    metadata, draft row, event payload — with the policy that allowed it.
    Forensics never re-run the policy.
11. **The gem never calls a model, never stores a prompt, never depends on a
    provider gem.**
12. **Disclosure is an explicit host choice**, validated at boot.

---

## 4. Public API reference (complete)

Everything below is public unless marked `:nodoc:`. Signatures are exact.

### 4.1 Configuration DSL

#### 4.1.1 `Configuration#assistant(key = nil, &block)`

```ruby
config.assistant :rose do |rose| … end   # declare or reconfigure :rose (block yields an AssistantConfiguration)
config.assistant(:rose)                  # read; raises ConfigurationError "no assistant :rose is configured" when unknown
config.assistant                         # the single configured assistant, or the default desk's; nil when none
config.assistants                        # Hash{Symbol => AssistantConfiguration}, insertion-ordered
config.assistant?(:rose)                 # true/false
```

Keys are Symbols; a String is `to_sym`'d. Declaring the same key twice
reconfigures the same object (idempotent across reloads).

#### 4.1.2 `Configuration::AssistantConfiguration`

```ruby
class SupportDesk::Configuration::AssistantConfiguration
  LEVELS           = SupportDesk::AssistantPolicy::LEVELS          # %i[off observe draft reply resolve]
  DISCLOSURE_MODES = %i[signature_and_notice signature notice none].freeze
  LINE_INTERPOLATIONS = { name: "…", desk: "…", reply_within: "…" }.freeze

  DEFAULTS = {
    name: nil,                        # nil → key.to_s.humanize
    avatar: nil,                      # String | callable(assistant) | nil
    autonomy: :draft,
    disclosure: nil,                  # REQUIRED — validate! raises when nil
    max_turns: 6,                     # positive Integer; nil = unlimited (doctor warns)
    responds_within: 3 * 60,          # seconds; nil disables the silent release
    may_open_conversations: false,
    hand_off_line: :"support_desk.system.handed_off_to_humans",
    human_requested_line: :"support_desk.system.human_requested",
    disclosure_line: :"support_desk.system.assistant_disclosure",
    hand_off_when: nil,               # ->(ticket, message) { bool } | nil
    cap: nil                          # ->(ticket) { level | nil } | nil
  }.freeze

  attr_reader :key

  def name / name=(String, non-blank, nil resets)
  def avatar / avatar=(String | callable | nil)
  def autonomy / autonomy=(one of LEVELS)
  def disclosure / disclosure=(one of DISCLOSURE_MODES)                # nil not accepted by the setter
  def max_turns / max_turns=(positive Integer | nil)
  def responds_within / responds_within=(Duration | Numeric | nil)     # reader returns ActiveSupport::Duration or nil
  def may_open_conversations / may_open_conversations=(true | false)
  def hand_off_line(&block) / hand_off_line=(String | Symbol | callable | nil)         # same contract as opening_line
  def human_requested_line(&block) / human_requested_line=(same)
  def disclosure_line(&block) / disclosure_line=(same)
  def hand_off_when(&block) / hand_off_when=(callable | nil)
  def cap(&block) / cap=(callable | nil)

  def signs?   = %i[signature_and_notice signature].include?(disclosure)
  def notice?  = %i[signature_and_notice notice].include?(disclosure)
  def disclosed? = disclosure != :none

  def line_for(setting, ticket)  # :nodoc: resolves String/Symbol/block with { name:, desk:, reply_within: }; nil/blank → nil
  def line_problems              # :nodoc: what doctor reports (String interpolation check, Symbol existence), like opening_line_problems
  def read(name) / own?(name) / reset_setting(name)   # :nodoc:, same as DeskConfiguration
end
```

Validation is **on assignment** (bad value ⇒ `ConfigurationError` with the fix
in the message), exactly like `DeskConfiguration`. `cap`'s and
`hand_off_when`'s return values are validated **when called** (§5.1, §5.7).

#### 4.1.3 `DeskConfiguration#assistant` / `#assistant=`

```ruby
config.desk(:billing) { |desk| desk.assistant = :rose }   # Symbol key, or nil to un-set
config.desk(:billing).assistant                            # Symbol | nil (falls back to the default desk's, like every desk setting)
config.desk(:billing).assistant_configuration              # AssistantConfiguration | nil
```

`DESK_SETTINGS` gains `assistant`, so `config.assistant = :rose` at the top
level is the default desk's. **Resolution when nothing is named:** if exactly
one assistant is configured, it is the default desk's implicitly. If two or
more are configured and the default desk names none, `validate!` raises
("two assistants (rose, max) and desk default names none — set
`config.assistant = :rose`").

#### 4.1.4 `Configuration#validate!` additions

Run at the end of `SupportDesk.configure`:

- every assistant has `disclosure` (else `ConfigurationError`: "assistant
  rose: disclosure is required — choose :signature_and_notice, :signature,
  :notice or :none (there is no default: this is your call)");
- every `desk.assistant` names a configured assistant;
- the implicit-default rule above;
- `max_turns` nil ⇒ a warning (surfaced by `doctor`), not an error.

#### 4.1.5 Topic option `assistant:`

```ruby
topic :payments, about: Payouts::Withdrawal, assistant: :draft
```

- `TopicTree::Builder::KNOWN_OPTIONS` += `:assistant`; validated ∈ `LEVELS`.
- `Topic::INHERITED_OPTIONS` += `:assistant` (a branch's cap applies to its
  subtree unless a child says otherwise).
- `Topic#assistant_cap` → Symbol | nil (`inherited_or_own(:assistant)`).
- `Topic::Unknown#assistant_cap` → `:observe` (an unknown topic is a case
  nobody can reason about; a person looks).

### 4.2 `SupportDesk` module functions

```ruby
SupportDesk.assistant(key = nil)        # the Assistant record for key (memoised, find_by || create_or_find_by!);
                                        # nil key → config.assistant&.key; returns nil when nothing is configured;
                                        # raises ConfigurationError for a key that isn't configured
SupportDesk.assistants                  # :nodoc: memo Hash
SupportDesk.reset_assistants!           # forget the memo (tests that truncate)
SupportDesk.reset!                      # also clears @assistants
SupportDesk.release_silent_assistants!  # → Integer released (see §5.11); what the rake task calls
SupportDesk.assistant_class?(klass)     # klass <= SupportDesk::Assistant (Class, instance or name)
```

### 4.3 `SupportDesk::Assistant`

```ruby
class SupportDesk::Assistant < SupportDesk::ApplicationRecord
  self.table_name = "support_desk_assistants"
  acts_as_support_agent kind: :ai

  attribute :settings, default: -> { {} }
  validates :key, presence: true

  scope :active,   -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  def self.for(key)                 # find_by(key:) || create_or_find_by!(key:); never INSERT-first

  def config                        # SupportDesk.config.assistant(key) — raises ConfigurationError when unconfigured
  def configured?                   # SupportDesk.config.assistant?(key)
  def name                          # config.name || settings["name"].presence || key.humanize
  def avatar                        # config.avatar (callable gets self) || settings["avatar"]
  def autonomy                      # config.autonomy
  def disclosure                    # config.disclosure
  def disclosed?  def signs?  def notice?
  def max_turns   def responds_within   def may_open_conversations?

  def disclosed_name                # disclosed? ? I18n.t("support_desk.assistant.disclosed_name", name:) : name
  def display_name = disclosed_name # what chats' default display-name lambda reads for a signature
  def to_s         = disclosed_name # hosts whose lambda falls back to to_s (CarHey)
  def support_agent_name   = disclosed_name
  def support_agent_avatar = avatar
  def chat_signature?      = signs?  # chats 0.3.3 duck seam: an author that declines to sign

  def on_duty?          = active?   # inactive ⇒ actions_for empty, no turns, seat released by the sweep
  def support_capacity  = nil
  def desks                         # Desk records whose config.assistant == key
  def held_tickets                  # Ticket.open.assigned_to(self)

  def inspect                       # "#<SupportDesk::Assistant rose \"Rose\" draft active>"
end
```

`acts_as_support_agent` registers the class in `agent_class_names` at load,
so GlobalID allow-lists and `SupportDesk.agent_class?` know it. The engine's
`to_prepare` references `SupportDesk::Assistant` next to `SupportDesk::Desk`
so lazy autoloading in development cannot leave the registry empty (the
grouped-inbox lesson from 13).

### 4.4 `SupportDesk::AssistantPolicy`

```ruby
class SupportDesk::AssistantPolicy
  LEVELS = %i[off observe draft reply resolve].freeze
  RANK   = LEVELS.each_with_index.to_h.freeze

  VERBS_BY_LEVEL = {
    off:     [].freeze,
    observe: %i[note change_topic attach_subject escalate release].freeze,
    draft:   %i[note change_topic attach_subject escalate release draft].freeze,
    reply:   %i[note change_topic attach_subject escalate release draft reply take hand_off].freeze,
    resolve: %i[note change_topic attach_subject escalate release draft reply take hand_off close].freeze
  }.freeze

  attr_reader :ticket, :assistant, :level, :because, :ceilings, :floors

  def self.for(ticket, assistant = nil, ignoring_holder: false)   # assistant defaults to ticket.desk.assistant; nil → Null
  def self.min(*levels)                                             # lowest by RANK, nils ignored

  def null?              # no assistant on this desk
  def at_least?(level)   def may?(verb)
  def may_observe? = at_least?(:observe)
  def may_draft?   = at_least?(:draft)
  def may_reply?   = at_least?(:reply)
  def may_hold?    = may_reply?
  def may_close?   = at_least?(:resolve)
  def allowed_verbs      # VERBS_BY_LEVEL[level]
  def forbidden_verbs    # VERBS_BY_LEVEL[:resolve] - allowed_verbs
  def to_h               # { assistant:, level:, because:, ceilings: { assistant:, topic:, cap:, ticket: }, floors: [ … ] }
  def to_s               # "draft (topic payments caps rose at draft)"
end
```

`Null` (returned when the desk has no assistant): `level :off`, `because "no
assistant on desk default"`, every predicate false, `null? true`.

### 4.5 `SupportDesk::Ticket` additions

#### 4.5.1 Columns (see §6)

`assistant_autonomy` (String, nullable: the per-case override, `"off"` or a
level), `human_required_at`, `human_required_reason`, `assistant_turns_count`
(Integer, default 0), `last_requester_message_id`.

#### 4.5.2 Associations

```ruby
has_many :drafts, class_name: "SupportDesk::Draft", inverse_of: :ticket, dependent: :destroy
has_one  :pending_draft, -> { pending }, class_name: "SupportDesk::Draft", inverse_of: :ticket
```

#### 4.5.3 Scopes

```ruby
scope :held_by_assistants,    -> { where(assignee_type: SupportDesk::Assistant.polymorphic_name) }
scope :held_by_humans,        -> { assigned.where.not(assignee_type: SupportDesk::Assistant.polymorphic_name) }
scope :needs_human,           -> { where.not(human_required_at: nil) }
scope :assistant_paused,      -> { where(assistant_autonomy: "off") }
scope :assistant_capped,      -> { where.not(assistant_autonomy: nil) }
scope :resolved_by_assistant, -> { closed.where(closed_by_type: SupportDesk::Assistant.polymorphic_name) }
scope :with_pending_draft,    -> { where(id: SupportDesk::Draft.pending.select(:ticket_id)) }
```

#### 4.5.4 Readers and predicates

```ruby
def assistant                 # desk.assistant (Assistant | nil)
def assistant_policy(assistant = self.assistant, ignoring_holder: false)   # AssistantPolicy (Null when none)
def assistant_in_play?        # assistant.present? && assistant_policy.may_draft?
def held_by_assistant?        # assignee.is_a?(SupportDesk::Assistant)   (assignee_type check, no load)
def human_required?           # human_required_at.present?
def assistant_paused?         # assistant_autonomy == "off"
def assistant_capped?         # assistant_autonomy.present?
def assistant_turn            # last_requester_message_id&.to_s   (nil until the requester has said something)
def assistant_turns_left      # max_turns ? [max_turns - assistant_turns_count, 0].max : nil
def transcript(limit: nil)    # SupportDesk::Transcript
def brief(**options)          # SupportDesk::Brief
```

#### 4.5.5 Verbs (new)

```ruby
def respond!(body = nil, by:, turn: nil, files: [], confidence: nil, sources: [], metadata: {}, request: nil)
  # → SupportDesk::Outcome. by: must be an Assistant (else NotAnAssistant). See §5.3.
def draft!(body, by:, turn: nil, confidence: nil, sources: [], metadata: {}, request: nil)
  # → SupportDesk::Draft. Always a draft; raises AssistantNotAllowed below :draft, StaleTurn, Locked. §5.4
def escalate!(by: nil, reason:, summary: nil, request: nil)
  # → self. Any agent or :system. Raises InvalidTransition on a closed case. Idempotent when already human_required. §5.6
def request_human!(by: nil, request: nil)
  # → self. by: must be THIS ticket's requester (NotAllowed otherwise). Reopens a reopen_on_reply case first. §5.6
def pause_assistant!(by: nil, reason: nil, request: nil)
  # → self. by: a human agent (NotAllowed for an Assistant). Idempotent. §5.9
def resume_assistant!(by: nil, request: nil)
  # → self. Clears any override (pause OR reopen cap). Idempotent. §5.9
```

#### 4.5.6 Verbs (changed behaviour when an assistant is involved)

```ruby
def reply!(body = nil, by: nil, files: [], request: nil, metadata: {})   # + metadata: (stamped on the chats message)
  # by: an Assistant → policy.may_reply? else AssistantNotAllowed; not awaiting_reply? → AssistantNotAllowed(:not_your_turn)
  # by: a human on an assistant-held case → takeover (§5.8)
def close!(by: nil, request: nil)
  # by: an Assistant → policy.may_close? else AssistantNotAllowed. Any close expires pending drafts (§5.10).
def assign!(to:, by: nil, reason: nil, note: nil, request: nil)
  # to: an Assistant → ensure_assignable! checks policy(ignoring_holder: true).may_hold? and !human_required-after-clear;
  #   assigning to an assistant CLEARS human_required_* and assistant_autonomy (an explicit hand-back, §5.8)
  # by: an Assistant → may only take (to == by) an unassigned case at :reply+
def hand_off!(to:, note: nil, by: nil, request: nil)          # same to:-rules as assign!
def release!(by: nil, reason: :released, request: nil)         # by: an Assistant → policy.may_observe?; reason may be :assistant_silent (sweep)
def note!(body, by: nil, request: nil)                          # by: an Assistant → policy.may_observe?
def change_topic!(to:, by: nil, request: nil)                   # by: an Assistant → policy.may_observe?
def attach_subject!(record, by: nil, request: nil)              # by: an Assistant → policy.may_observe?
def reopen!(by: nil, request: nil)                              # assistant was the last holder → §5.9 cap rule
def actions_for(agent)                                          # §4.5.7
def agents_to_notify                                            # humans only: assignee if human; else desk.humans.select(&:on_duty?)
def export                                                      # messages: from: "assistant" when author is an Assistant
```

#### 4.5.7 `actions_for(agent)` — the boundary, extended

```ruby
def actions_for(agent)
  return [] unless agent.respond_to?(:support_agent?) && agent.support_agent?
  return assistant_actions_for(agent) if agent.is_a?(SupportDesk::Assistant)
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
    if pending_draft && may_reply?(agent) && !requester_unavailable?
      actions << :send_draft << :reject_draft
    elsif pending_draft
      actions << :reject_draft
    end
    if assistant
      actions << (assistant_paused? ? :resume_assistant : :pause_assistant)
    end
  end
  actions
end

def assistant_actions_for(assistant)   # :nodoc:
  policy = assistant_policy(assistant)
  verbs = policy.allowed_verbs.dup
  verbs -= %i[escalate] if closed?                              # nothing to escalate
  verbs -= %i[reply draft take] if requester_unavailable?       # nobody to write to
  verbs -= %i[take] unless unassigned?
  verbs -= %i[hand_off release] unless assigned_to?(assistant)
  verbs
end
```

`may_reply?(agent)` for a human stays as today; `reply_policy :assignee_only`
with an **assistant** holder does not block a human (§5.8), so `may_reply?`
returns true when `held_by_assistant?`.

### 4.6 `SupportDesk::Draft`

```ruby
class SupportDesk::Draft < SupportDesk::ApplicationRecord
  self.table_name = "support_desk_drafts"
  STATUSES = %w[pending sent rejected superseded expired].freeze

  belongs_to :ticket,       class_name: "SupportDesk::Ticket", inverse_of: :drafts
  belongs_to :author,       polymorphic: true                           # an Assistant in 0.3.0
  belongs_to :reviewed_by,  polymorphic: true, optional: true
  belongs_to :in_reply_to,  class_name: "Chats::Message", optional: true
  belongs_to :sent_message, class_name: "Chats::Message", optional: true

  attribute :sources,  default: -> { [] }
  attribute :metadata, default: -> { {} }

  validates :status, inclusion: { in: STATUSES }
  validates :body, presence: true
  validates :confidence, numericality: { in: 0..1 }, allow_nil: true

  scope :pending,    -> { where(status: "pending") }
  scope :sent,       -> { where(status: "sent") }
  scope :rejected,   -> { where(status: "rejected") }
  scope :superseded, -> { where(status: "superseded") }
  scope :expired,    -> { where(status: "expired") }
  scope :reviewed,   -> { where(status: %w[sent rejected]) }
  scope :verbatim,   -> { sent.where(sent_body: nil) }
  scope :edited,     -> { sent.where.not(sent_body: nil) }
  scope :by,         ->(author) { where(author: author) }
  scope :chronological, -> { order(:created_at, :id) }
  scope :newest_first,  -> { order(created_at: :desc, id: :desc) }

  def pending? sent? rejected? superseded? expired?
  def stale?              # pending? && ticket.last_requester_message_id.to_s != in_reply_to_id.to_s  (nil == nil is not stale)
  def edited?             # sent? && sent_body.present?
  def final_body          # sent_body || body
  def confidence_percent  # (confidence * 100).round or nil
  def author_key          # SupportDesk.actor_key(author)
  def assistant           # author if author.is_a?(SupportDesk::Assistant)

  def send!(by:, body: nil, even_if_stale: false, request: nil)   # → Chats::Message. §5.5
  def reject!(by:, reason: nil, request: nil)                      # → self. §5.5
  def supersede!  # :nodoc:   pending → superseded
  def expire!     # :nodoc:   pending → expired

  def inspect     # "#<SupportDesk::Draft 12 ticket=T-AB12CD rose pending 0.82>"
end
```

### 4.7 `SupportDesk::Outcome`

```ruby
SupportDesk::Outcome = Struct.new(:action, :message, :draft, :policy, :reason, keyword_init: true) do
  def sent?     = action == :sent
  def drafted?  = action == :drafted
  def withheld? = action == :withheld
  def escalated? = !!reason&.to_s&.start_with?("max_turns")     # drafted AND escalated at the turn cap
  def to_h      # { action:, message_id:, draft_id:, reason:, policy: policy.to_h }
end
```

### 4.8 `SupportDesk::Transcript`

```ruby
class SupportDesk::Transcript
  include Enumerable
  Turn = Struct.new(:role, :name, :body, :at, :attachments, :assisted, :message, keyword_init: true) do
    def to_h   # everything but :message
    def to_s   # "[2026-09-18 10:02] Alice: …"  (UTC ISO minute; attachments as "[archivo.pdf]")
  end
  ROLES = %i[requester human assistant system].freeze

  def initialize(ticket, limit: nil)   # newest `limit` turns when given; default all
  def each(&)  def turns  def size  def empty?
  def last(n)  def since(message)      # turns after a Chats::Message
  def to_a  def to_h  def to_text      # to_text: one Turn#to_s per line, deterministic
end
```

Role resolution per message (`Ticket#role_of` extended): `system?` ⇒
`:system`; sender is the requester ⇒ `:requester`; sender is the desk and
`author.is_a?(Assistant)` ⇒ `:assistant`; sender is the desk otherwise ⇒
`:human`. `assisted` = `metadata["drafted_by"].present?`. `name`:
requester → `Chats.display_name_for`; assistant → `assistant.name` (bare, the
disclosure is the customer's concern, not the model's); human →
`author.try(:support_agent_name) || desk.name`; system → nil. Deleted
messages render their tombstone (`visible_body` nil ⇒ "[mensaje eliminado]").

### 4.9 `SupportDesk::Brief`

```ruby
class SupportDesk::Brief
  def initialize(ticket, assistant: ticket.assistant, transcript_limit: 50)
  def to_h
  def to_text          # sectioned plain text: "# Case", "# Desk", "# Assistant", "# Requester", "# Subject", "# Notes", "# Previous drafts", "# Transcript"
  def policy           # the AssistantPolicy it was built with
end
```

`to_h` shape (keys stable, documented in the README):

```ruby
{
  desk:      { key:, name:, reply_within: "1 día" },
  assistant: { key:, name:, disclosure:, level:, because:, may: [...], may_not: [...], turns: { used:, max: } },   # nil when no assistant
  case:      { reference:, status:, awaiting:, opened_at:, opened_via:, opened_by: "requester" | "support",
               reopened: Integer, human_required: { at:, reason: } | nil, assistant_paused: bool,
               topic: { path:, label: full_label }, subject: { type:, label:, status:, context: {…} } | nil },
  requester: { name:, since:, open_cases:, context: requester.try(:support_context) || {} },
  notes:     [ { at:, by:, body: } ],                        # internal notes + escalation summaries, chronological
  drafts:    [ { at:, status:, body:, confidence:, edited:, sent_body:, rejection_reason: } ],   # newest first, all statuses
  transcript: transcript.to_h
}
```

**Facts only, no instructions.** The README says in bold that whatever a host
puts in `support_context` is what it is sending to a model.

### 4.10 `SupportDesk::Requester#support_context`

New overridable reader on the requester concern, default `{}` — the same
name and meaning as `Supportable#support_context` ("what an agent sees about
you"). Read by `Brief` and by `ContextCard#requester_pairs`; the gem's
console context-card partial renders it under the requester block.

### 4.11 `SupportDesk::Desk` additions

```ruby
def assistant          # SupportDesk.assistant(config.assistant) or nil
def assistant?         # !assistant.nil?
def humans             # config.agent_pool.to_a — the pool as configured (never contains an Assistant)
def agents             # humans + [assistant].compact — what pickers and routing may choose
def on_duty_agents     # agents.select(&:on_duty?) (unchanged expression; now includes an active assistant)
```

`Ticket#agents_to_notify` switches to `desk.humans` (the assistant is
notified by `:assistant_turn`, never by a host bell). Hosts that iterate
`desk.agents` to page people are told in the CHANGELOG to use
`agents_to_notify` or `desk.humans`.

### 4.12 `SupportDesk::Assignment` / `SupportDesk::Event` constants

- `Assignment::RELEASE_REASONS` += `assistant_silent`. (No new `REASONS`
  value — rolling-deploy safe, §13.)
- `Event::KINDS` += `human_requested assistant_paused assistant_resumed
  draft_sent draft_rejected assistant_withheld` (`escalated` already exists).
- `Event.requester_visible` excludes `assistant_withheld draft_sent
  draft_rejected assistant_paused assistant_resumed` in addition to `note
  drop_in`. `escalated` and `human_requested` stay visible (the requester saw
  the line).
- `Event#summary` → `payload["summary"]` (for `escalated`).

### 4.13 Errors

```ruby
class NotAnAssistant       < NotAnAgent          # respond!/draft! by something that isn't a SupportDesk::Assistant
class AssistantNotAllowed  < NotAllowed          # carries `policy` (attr_reader) and `verb`; message: "rose may not reply on T-AB12CD: topic payments caps rose at draft"
class StaleTurn            < InvalidTransition   # the requester wrote since `turn`
```

Console error keys derive from the class names as today: `not_an_assistant`,
`assistant_not_allowed`, `stale_turn`.

### 4.14 Events catalogue additions (`SupportDesk::Events::CATALOGUE`)

| event | args | when |
|---|---|---|
| `assistant_turn` | `ticket, assistant, message, turn:` | a requester message registered (opening one included) on a desk with an assistant whose effective level ≥ `:observe`. After commit. |
| `draft_proposed` | `ticket, draft` | `draft!` / `respond!` produced a draft |
| `draft_sent` | `ticket, draft, message, by:` | a human sent it (verbatim or edited) |
| `draft_rejected` | `ticket, draft, by:, reason:` | |
| `assistant_withheld` | `ticket, assistant, reason:, policy:` | `respond!` wrote nothing; `reason` ∈ `:policy`, `:not_your_turn` |
| `ticket_escalated` | `ticket, from:, reason:, by:` | `escalate!` flagged the case (not on the idempotent repeat) |
| `human_requested` | `ticket, by:, reason:` | `request_human!` (`reason` ∈ `:requester_request`, `:phrase`) |
| `assistant_paused` | `ticket, by:` | |
| `assistant_resumed` | `ticket, by:` | |

Every one also reaches `ticket_transitioned` where an Event row is written
(`escalated`, `human_requested`, `assistant_paused`, `assistant_resumed`,
`draft_sent`, `draft_rejected`, `assistant_withheld`), and every one is
mirrored on `ActiveSupport::Notifications` as `"<event>.support_desk"`.

### 4.15 Console (`SupportDesk::Console`)

```ruby
MEMBER_VERBS = %i[reply take assign hand_off release close reopen note change_topic
                  send_draft reject_draft pause_assistant resume_assistant].freeze
OFFERED_AS   = OFFERED_AS.merge(send_draft: :send_draft, reject_draft: :reject_draft,
                                pause_assistant: :pause_assistant, resume_assistant: :resume_assistant).freeze
```

Actions (each through `attempt`, every refusal a flash):

```ruby
def send_draft        # params: draft_id (required), body (optional edit), even_if_stale ("1")
def reject_draft      # params: draft_id (required), reason (optional)
def pause_assistant   # params: reason (optional)
def resume_assistant
```

- `support_console_draft` (private): `@ticket.drafts.pending.find_by(id:
  params[:draft_id])`; nil ⇒ `refuse(:unknown_draft)`. A `draft_id` that is
  not a String ⇒ `InvalidInput :invalid_input`.
- `unavailable_reason` gains `"no_pending_draft"` for the two draft verbs.
- `RESCUED_ERRORS` needs no change (`StaleTurn < InvalidTransition`,
  `AssistantNotAllowed < NotAllowed`).
- **Agent picker values become actor keys.** `support_console_agent(id)`
  resolves `params[:agent_id]` by `SupportDesk.actor_key(agent) == id`, and,
  for one release, a bare numeric id **only when exactly one pool member has
  it** (an Assistant and a User can share an id). The `_assignment` partial
  emits `SupportDesk.actor_key(agent)` as option values.
- Helper methods added: `support_pending_draft` (memoised
  `@ticket.pending_draft`), `support_assistant` (`@ticket.assistant`).

### 4.16 Requester engine

```ruby
# config/routes.rb (engine)
resources :tickets, only: %i[create show] do
  post :request_human, on: :member
end
```

`SupportDesk::TicketsController#request_human`: `ticket =
current_requester.support_tickets.find(params[:id])` (404 for anybody
else's), `ticket.request_human!(by: current_requester, request: request)`,
redirect to `ticket_path(ticket)` (which already redirects into the chats
thread) with `notice: t("support_desk.thread.human_requested_notice")`;
`SupportDesk::Locked` / `InvalidTransition` ⇒ redirect with `alert`.

Partial `app/views/support_desk/tickets/_human_door.html.erb` (local:
`ticket`): renders `button_to t("support_desk.thread.human_door"),
support_desk.request_human_ticket_path(ticket)` **only when**
`ticket.assistant_in_play? && !ticket.human_required?`; renders nothing
otherwise. Hosts drop it into their thread (a chats slot, or their ejected
conversation view). `SupportDesk.native_path_rules` needs no change (a POST
that redirects).

### 4.17 Queue

```ruby
TABS = %i[awaiting needs_human mine unassigned open snoozed closed].freeze
def needs_human = scoped.open.needs_human.most_urgent_first
```

`counts` adds one grouping dimension, portable across adapters:
`Arel.sql("CASE WHEN #{table}.human_required_at IS NULL THEN 0 ELSE 1 END")`,
and sums `counts[:needs_human]` for open rows with `1`. `badge`, `next`,
`mine`, `unassigned` are unchanged (an assistant-held case is *assigned*, so it
is in none of a human's piles — invariant 8 bounds that).

### 4.18 Rake tasks

```
rake support_desk:release_silent_assistants   # SupportDesk.release_silent_assistants!; prints "released N case(s)"
rake support_desk:backfill_last_requester_message   # idempotent catch-up for rows the migration's UPDATE could not reach (none expected; kept for symmetry with 0.2)
```

### 4.19 Doctor checks (added)

| check | verdict |
|---|---|
| `assistants (config)` | every configured assistant resolves a desk, has a non-blank name; `max_turns nil` ⇒ warn |
| `assistant turn subscriber` | an assistant is configured and `SupportDesk.subscribers[:assistant_turn]` is empty ⇒ **warn** "cases rose holds will wait forever — subscribe to :assistant_turn" |
| `assistant authorship` | `Chats.display_name_for(assistant)` blank ⇒ **fail** (the host's display-name lambda does not duck-type; the signature would be "— ") |
| `assistant silence` | any `Ticket.open.held_by_assistants.awaiting_reply.waiting_over(responds_within)` ⇒ **fail**, naming the rake task |
| `assistant seats` | an assistant holds a `needs_human` case, or holds a case whose policy is below `:reply` ⇒ **fail** (invariant 7) |
| `drafts` | pending drafts on closed cases ⇒ warn; > 1 pending per case ⇒ **fail** (MySQL) |
| `ai agents without policy` | a registered agent class with `kind: :ai` that is not `SupportDesk::Assistant` ⇒ warn "no policy applies to X; it has a human's authority" |

### 4.20 Generators

- `support_desk:install` and `support_desk:upgrade` both copy
  `add_assistants_to_support_desk.rb` (§6) when its tables/columns are absent
  (the same idempotent copy the `opened_by` migration uses).
- **New** `rails g support_desk:assistant NAME [--desk KEY] [--autonomy LEVEL]`:
  - appends a `config.assistant :name do … end` stanza (with `disclosure`
    **left as a required blank the boot will name**, and a comment listing the
    four modes) plus the `config.on(:assistant_turn)` subscription to
    `config/initializers/support_desk.rb`, or prints both when the file is
    absent;
  - writes `app/jobs/support/assistant_turn_job.rb` (§9.2),
    `app/services/support/<name>.rb` (§9.3, provider-blank),
    `test/jobs/support/assistant_turn_job_test.rb` (§9.4);
  - appends the locale keys of §8 it does not find to `config/locales/es.yml`
    / `en.yml` (only the ones with `%{name}`).

### 4.21 `SupportDesk::TestHelpers` additions

```ruby
support_assistant(key = nil)                                # SupportDesk.assistant(key)
respond_as(assistant, ticket, body, turn: ticket.assistant_turn, **options)   # → Outcome
draft_as(assistant, ticket, body, **options)                # → Draft
assert_pending_draft(ticket, body: nil)                     # → the Draft; body may be a String or Regexp
refute_pending_draft(ticket)
assert_needs_human(ticket) / refute_needs_human(ticket)
assert_held_by_assistant(ticket, assistant = nil)
refute_assistant_spoke(ticket)                              # no visible message authored by an Assistant
assert_assistant_policy(ticket, level, because: nil)        # because: String or Regexp
with_assistant_config(key = nil, **overrides) { }           # like with_support_config, for an AssistantConfiguration
with_topic_assistant_cap(path, level) { }                   # rebuilds the default desk's tree with one node's cap changed, restores after
```

### 4.22 `chats` 0.3.3 — two seams

1. `Chats::Messager#message!(target, body = nil, about:, files:, reply_to:,
   author:, metadata: {})` — `metadata` merged onto the message (`{}` default,
   no behaviour change).
2. `Chats.message_signature_for(message)` returns `nil` when
   `message.author.respond_to?(:chat_signature?) && !message.author.chat_signature?`
   — an author that declines to sign. Documented in the chats README under
   "Signed messages" as the duck-typed veto; tests for both.

`support_desk.gemspec`: `spec.add_dependency "chats", "~> 0.3", ">= 0.3.3"`.

---

## 5. Algorithms, in full

All algorithms run **under the ticket's row lock** (`with_lock(requires_new:
true)` reloads the row, so every policy read is fresh) and write through the
existing transition plumbing (`write_transition!` / `record_transition!` /
`publish_transition`), so `ticket_transitioned`, the Turbo refresh and the
audit mirror come for free. Where a step says "event", it is one Event row
written inside the transaction; where it says "emit", it is
`SupportDesk.emit_after_commit`.

### 5.1 Effective policy — `AssistantPolicy.for(ticket, assistant, ignoring_holder: false)`

```ruby
def self.for(ticket, assistant = nil, ignoring_holder: false)
  assistant ||= ticket.assistant
  return Null.new(ticket) if assistant.nil?

  config   = assistant.config
  ceilings = {
    assistant: config.autonomy,
    topic:     ticket.topic&.assistant_cap,                     # Topic::Unknown → :observe
    cap:       evaluate_cap(config, ticket),                    # nil | level; anything else → ConfigurationError
    ticket:    ticket.assistant_autonomy&.to_sym                # nil | :off | a level
  }
  level, rule = ceilings.compact.min_by { |_, l| RANK.fetch(l) }   # ties → first in Hash order: assistant, topic, cap, ticket
  because = ceiling_sentence(rule, level, assistant, ticket)       # "topic payments caps rose at draft" · "rose is configured at draft" · "cap block caps rose at draft" · "paused on this case" / "capped at draft on this case (reopened after rose closed it)"

  floors = []
  unless assistant.active?
    level, because = :off, "#{assistant.key} is inactive"; floors << :inactive
  end
  if ticket.closed? && RANK[level] > RANK[:observe]
    level, because = :observe, "the case is closed"; floors << :closed
  end
  if ticket.human_required? && RANK[level] > RANK[:observe]
    level, because = :observe, "a person was requested (#{ticket.human_required_reason})"; floors << :human_required
  end
  if !ignoring_holder && ticket.assigned? && !ticket.assigned_to?(assistant) && RANK[level] > RANK[:draft]
    level, because = :draft, "#{ticket.send(:describe_actor, ticket.assignee)} holds the case"; floors << :held_by_human
  end
  new(ticket:, assistant:, level:, because:, ceilings:, floors:)
end
```

`evaluate_cap`: `config.cap` nil ⇒ nil; else `value = cap.call(ticket)`;
nil ⇒ nil; a Symbol/String in `LEVELS` ⇒ symbol; anything else ⇒
`ConfigurationError "assistant rose: cap must return one of …, got …"`. A cap
block that **raises** propagates (it is host code, and it is a bug), except
inside `emit_assistant_turn` (§5.2), which reports and skips the turn.

No database query is issued by `for`: `topic` is an in-memory tree lookup,
`assignee` is the loaded association (the console preloads it), everything
else is a column.

### 5.2 The turn token and its emission

`record_registration!` (existing) gains, in the `when :requester` branch:

```ruby
attributes[:last_requester_message_id] = message.id
```

and, after `save!` and before `announce_registration`:

```ruby
evaluate_hand_off_phrase!(message) if role == :requester      # §5.7
```

`announce_registration` gains, in the `when :requester` branch (opening
message **included**, unlike `requester_replied`):

```ruby
emit_assistant_turn(message)
```

```ruby
def emit_assistant_turn(message)   # :nodoc:
  assistant = self.assistant
  return if assistant.nil?
  policy = assistant_policy(assistant)
  return unless policy.may_observe?
  SupportDesk.emit_after_commit(:assistant_turn, self, assistant, message, turn: assistant_turn)
rescue StandardError => e
  SupportDesk.report_error(e, context: { hook: :assistant_turn, ticket: id })   # Rails.error when present, else logger — the dispatcher's own path, extracted
end
```

The token is `last_requester_message_id.to_s`. Properties:

- changes on every registered requester message, never on agent, assistant or
  system messages;
- `nil` until the requester has said something (a desk-opened case emits its
  first turn on the requester's first reply);
- survives reopen (the id is the id);
- is a String so it round-trips through job arguments unchanged.

`ensure_current_turn!(turn)`: `return if turn.nil?`; `raise StaleTurn,
"turn #{turn} is stale on #{reference}: the requester has written since
(current #{assistant_turn})" unless turn.to_s == assistant_turn`.

### 5.3 `respond!`

```ruby
def respond!(body = nil, by:, turn: nil, files: [], confidence: nil, sources: [], metadata: {}, request: nil)
  assistant = resolve_assistant!(by)                      # NotAnAssistant unless a persisted SupportDesk::Assistant; ensure_agent_record! (active + eligible)
  raise ArgumentError, "respond! needs something to say" if body.blank? && files.blank?

  with_lock(requires_new: true) do
    ensure_current_turn!(turn)
    ensure_writable!                                      # Locked: requester gone, or closed on a :locked desk
    policy = assistant_policy(assistant)

    return withhold!(assistant, policy, reason: :policy, request:)        unless policy.may_draft?
    return withhold!(assistant, policy, reason: :not_your_turn, request:) unless awaiting_reply?

    turns_left = assistant_turns_left                      # nil = unlimited
    if policy.may_reply? && (turns_left.nil? || turns_left.positive?)
      message = speak!(body, assistant, policy:, turn:, files:, confidence:, sources:, metadata:, request:)
      Outcome.new(action: :sent, message:, policy:)
    else
      draft = propose_draft!(body, assistant, policy:, confidence:, sources:, metadata:)
      reason = nil
      if policy.may_reply? && turns_left&.zero?
        escalate_within_lock!(by: assistant, reason: "max_turns", summary: metadata["summary"], request:)
        reason = "max_turns"
      end
      Outcome.new(action: :drafted, draft:, policy:, reason:)
    end
  end
end
```

`withhold!`: writes one Event `assistant_withheld` `{ "assistant" => key,
"reason" => reason, "policy" => policy.to_h }` through `write_transition!`
(so it is audited), emits `:assistant_withheld (self, assistant, reason:,
policy:)`, returns `Outcome.new(action: :withheld, reason:, policy:)`.

`speak!`:

```ruby
def speak!(body, assistant, policy:, turn:, files:, confidence:, sources:, metadata:, request:)
  post_disclosure_notice!(assistant) if assistant.notice? && !disclosure_posted?
  apply_reply_policy!(assistant, request:)               # unassigned → assign!(to: assistant, by: assistant) (reason :taken); announce_assignment! skips assistants (§5.12)
  stamped = metadata.merge(
    "assistant" => assistant.key, "turn" => turn&.to_s, "confidence" => confidence,
    "sources" => Array(sources), "policy" => policy.to_h
  ).compact
  posted = post_agent_message!(body, files:, by: assistant, metadata: stamped)
  record_registration!(posted)                            # clocks, first_agent_reply_at, :agent_replied
  update!(assistant_turns_count: assistant_turns_count + 1)
  posted
end
```

Ordering guarantee for the disclosure notice: posted inside the same
transaction *before* the message, and pinned one `ordering_tick` before it
with the same helper the opening line uses (`pin_before!(notice, posted)`), so
frozen clocks and UUID ids cannot sort it after the bubble it introduces.
`disclosure_posted?` = `metadata["assistant_disclosed_at"].present?`; the
notice stamps it (`update!(metadata: metadata.merge(…))`).

### 5.4 `draft!` and `propose_draft!`

```ruby
def draft!(body, by:, turn: nil, confidence: nil, sources: [], metadata: {}, request: nil)
  assistant = resolve_assistant!(by)
  raise ArgumentError, "a draft needs something to say" if body.blank?
  with_lock(requires_new: true) do
    ensure_current_turn!(turn)
    policy = assistant_policy(assistant)
    raise AssistantNotAllowed.new(policy, verb: :draft) unless policy.may_draft?
    propose_draft!(body, assistant, policy:, confidence:, sources:, metadata:)
  end
end

def propose_draft!(body, assistant, policy:, confidence:, sources:, metadata:)   # :nodoc:, caller holds the lock
  drafts.pending.each(&:supersede!)
  draft = drafts.create!(author: assistant, in_reply_to_id: last_requester_message_id, body: body.to_s,
                         confidence:, sources: Array(sources), status: "pending",
                         metadata: metadata.merge("policy" => policy.to_h).compact)
  broadcast_change
  SupportDesk.emit_after_commit(:draft_proposed, self, draft)
  draft
rescue ActiveRecord::RecordNotUnique
  # Two harness processes drafted the same case in the same millisecond. The
  # index kept one; ours is the loser, and the winner's draft is the one
  # humans see. Supersede-then-create under the row lock makes this
  # unreachable on PostgreSQL and SQLite; it is the MySQL belt.
  drafts.pending.first
end
```

Drafts never `ensure_writable!`: a draft is internal, and proposing one for a
customer who has since closed their account is harmless (the console will not
offer `send_draft`, because `actions_for` drops it when
`requester_unavailable?`).

### 5.5 `Draft#send!` and `Draft#reject!`

```ruby
def send!(by:, body: nil, even_if_stale: false, request: nil)
  human = ticket.send(:resolve_actor, by)
  raise NotAllowed, "an assistant can't approve a draft" if human.is_a?(SupportDesk::Assistant) || human.is_a?(Symbol)
  ticket.send(:ensure_agent!, human)

  message = nil
  ticket.with_lock(requires_new: true) do
    reload
    raise InvalidTransition, "draft #{id} is #{status}, not pending" unless pending?
    raise StaleTurn, "the requester has written since this draft — read it, then send with even_if_stale: true" if stale? && !even_if_stale

    final  = body.presence || self.body
    edited = final != self.body
    message = ticket.reply!(final, by: human, request:,
                            metadata: { "drafted_by" => author_key, "draft_id" => id, "edited" => edited })
    update!(status: "sent", reviewed_by: human, reviewed_at: Time.current,
            sent_message: message, sent_body: (final if edited))
    ticket.send(:write_transition!, :draft_sent, actor: human, request:) do
      { "draft" => id, "assistant" => author_key, "edited" => edited, "message" => message.id, "stale" => stale? }
    end
  end
  SupportDesk.emit_after_commit(:draft_sent, ticket, self, message, by: human)
  message
end

def reject!(by:, reason: nil, request: nil)
  human = ticket.send(:resolve_actor, by)
  raise NotAllowed, "an assistant can't reject a draft" if human.is_a?(SupportDesk::Assistant) || human.is_a?(Symbol)
  ticket.send(:ensure_agent!, human)
  ticket.with_lock(requires_new: true) do
    reload
    raise InvalidTransition, "draft #{id} is #{status}, not pending" unless pending?
    update!(status: "rejected", reviewed_by: human, reviewed_at: Time.current, rejection_reason: reason.presence)
    ticket.send(:write_transition!, :draft_rejected, actor: human, request:) do
      { "draft" => id, "assistant" => author_key, "reason" => reason.presence }
    end
  end
  SupportDesk.emit_after_commit(:draft_rejected, ticket, self, by: human, reason: reason.presence)
  self
end
```

`ticket.reply!(…, by: human)` inside `send!` runs the ordinary reply path:
`ensure_writable!`, then `apply_reply_policy!` — which, because the holder is
an assistant, **takes the case over for the human** (§5.8) — then
registration and `:agent_replied`. The message's `author` is the human
(decision 12 #20).

### 5.6 `escalate!` and `request_human!`

Both call one private core:

```ruby
def flag_human_required!(actor:, kind:, reason:, summary:, line:, request:)   # :nodoc:
  from = nil
  event = write_transition!(kind, actor: actor, request: request) do
    raise InvalidTransition, "can't #{kind} a closed case — reopen it first" if closed?
    next false if human_required?                                   # idempotent
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

  post_assistant_line!(line) unless requester_unavailable?          # the system line; nil line posts nothing
  event
end

def escalate!(by: nil, reason:, summary: nil, request: nil)
  actor = resolve_actor(by)
  ensure_agent!(actor)                                              # a Symbol (:system) passes, as everywhere
  raise ArgumentError, "escalate! needs a reason" if reason.blank?
  if actor.is_a?(SupportDesk::Assistant)
    policy = assistant_policy(actor)
    raise AssistantNotAllowed.new(policy, verb: :escalate) unless policy.may_observe?
  end
  event = flag_human_required!(actor:, kind: :escalated, reason:, summary:, line: :hand_off_line, request:)
  return self unless event
  SupportDesk.emit_after_commit(:ticket_escalated, self, from: event.payload["from"], reason: reason.to_s.to_sym, by: actor)
  self
end

def request_human!(by: nil, request: nil)
  actor = resolve_actor(by)
  unless self.class.same_actor?(actor, requester)
    raise NotAllowed, "only #{requester_type}##{requester_id} can ask for a person on #{reference}"
  end
  reopen!(by: actor, request:) if closed? && desk_config.closed_tickets == :reopen_on_reply   # a :locked desk raises Locked below
  ensure_writable!
  event = flag_human_required!(actor:, kind: :human_requested, reason: "requester_request", summary: nil,
                               line: :human_requested_line, request:)
  return self unless event
  SupportDesk.emit_after_commit(:human_requested, self, by: actor, reason: :requester_request)
  self
end
```

`escalate_within_lock!` (used by `respond!` at `max_turns`) is the same core
without the outer `resolve_actor`, since the caller already holds the lock
and the actor. `post_assistant_line!(setting)` resolves
`assistant.config.line_for(setting, self)` (`hand_off_line`,
`human_requested_line`, `disclosure_line`) and posts a chats system message;
when the desk has no assistant, `request_human!` posts nothing (there is no
line to resolve) but still flags — the flag is meaningful on a human-only desk
too (a badge, a priority bump).

### 5.7 `hand_off_when`

Inside `record_registration!`, for `role == :requester`, after `save!`:

```ruby
def evaluate_hand_off_phrase!(message)   # :nodoc:
  assistant = self.assistant
  return if assistant.nil? || human_required? || !assistant_in_play?
  block = assistant.config.hand_off_when
  return if block.nil?

  hit = begin
    !!block.call(self, message)
  rescue StandardError => e
    SupportDesk.report_error(e, context: { hook: :hand_off_when, ticket: id })
    false
  end
  return unless hit

  flag_human_required!(actor: requester, kind: :human_requested, reason: "phrase", summary: nil,
                       line: :human_requested_line, request: nil)
  SupportDesk.emit_after_commit(:human_requested, self, by: requester, reason: :phrase)
end
```

It runs **before** `emit_assistant_turn`, so the turn (if any) is emitted at
the already-floored level (`:observe`): the harness may still summarize for
the human, but it cannot draft or speak.

### 5.8 Humans outrank assistants; handing back

`apply_reply_policy!(actor, request:)` — the branch for a held case:

```ruby
elsif !assigned_to?(actor)
  if held_by_assistant? && !actor.is_a?(SupportDesk::Assistant)
    # A person answering a case the assistant holds takes it, whatever the
    # desk's policy says about people answering each other's cases.
    assign!(to: actor, by: actor, reason: :drop_in_takeover, request: request)
  elsif actor.is_a?(SupportDesk::Assistant)
    # Never reached at :reply (the policy floors a held case at :draft); belt.
    raise AssistantNotAllowed.new(assistant_policy(actor), verb: :reply)
  else
    case policy … (unchanged)
  end
end
```

`may_reply?(agent)` returns `true` for a human when `held_by_assistant?`
regardless of `reply_policy`, so `actions_for` offers `:reply` and the
console composer renders.

`ensure_assignable!(agent)` for an Assistant target:

```ruby
if agent.is_a?(SupportDesk::Assistant)
  policy = assistant_policy(agent, ignoring_holder: true)
  raise AssistantNotAllowed.new(policy, verb: :take) unless policy.may_hold?
end
```

`assign!` / `hand_off!`, inside their transition block, when `to` is an
Assistant: `update!(human_required_at: nil, human_required_reason: nil,
assistant_autonomy: nil)` and payload `"handed_back" => true`. This is the
**only** path that clears a human-required flag or a reopen cap
(`resume_assistant!` clears the override too, §5.9, but not the flag).

An assistant may `assign!` only itself, only onto an unassigned case, only at
`:reply`+ (`by: rose, to: rose`); `assign!(to: lucia, by: rose)` raises
`AssistantNotAllowed` (she hands off with `escalate!`, which pages humans
rather than picking one).

### 5.9 Pause, resume, and the reopen cap

```ruby
def pause_assistant!(by: nil, reason: nil, request: nil)
  actor = resolve_actor(by)
  ensure_agent!(actor)
  raise NotAllowed, "an assistant can't pause itself" if actor.is_a?(SupportDesk::Assistant)
  event = write_transition!(:assistant_paused, actor: actor, request: request) do
    raise InvalidTransition, "can't pause the assistant on a closed case" if closed?
    next false if assistant_paused?
    if held_by_assistant?
      assignments.open.each { |a| a.release!(reason: :released) }
      update!(assignee: nil)
    end
    drafts.pending.each(&:supersede!)               # a paused assistant's proposal is not offered
    update!(assistant_autonomy: "off")
    { "reason" => reason.presence, "assistant" => assistant&.key }.compact
  end
  return self unless event
  SupportDesk.emit_after_commit(:assistant_paused, self, by: actor)
  self
end

def resume_assistant!(by: nil, request: nil)
  actor = resolve_actor(by)
  ensure_agent!(actor)
  raise NotAllowed, "an assistant can't resume itself" if actor.is_a?(SupportDesk::Assistant)
  event = write_transition!(:assistant_resumed, actor: actor, request: request) do
    next false if assistant_autonomy.nil?
    update!(assistant_autonomy: nil)
    { "from" => assistant_autonomy_was, "assistant" => assistant&.key }.compact
  end
  return self unless event
  SupportDesk.emit_after_commit(:assistant_resumed, self, by: actor)
  self
end
```

`pause_assistant!` / `resume_assistant!` may be called on a desk with no
assistant (they write an override that nothing reads) — `actions_for` simply
never offers them there.

**Reopen cap** (decision 12 #21). `restore_assignment!(by:)` becomes:

```ruby
def restore_assignment!(by:)
  return if unassigned?
  if assignee.is_a?(SupportDesk::Assistant)
    # Rose closed it and the requester came back: she was wrong once. A
    # person decides; her next attempt is a draft for them.
    update!(assignee: nil, assistant_autonomy: (assistant_autonomy == "off" ? "off" : "draft"))
  elsif assignee.respond_to?(:support_agent?) && assignee.support_agent?
    Assignment.open!(ticket: self, agent: assignee, by: by, reason: :reopened)
  else
    update!(assignee: nil)
  end
end
```

Both reopen paths (`reopen!` and the requester-reply reopen inside
`record_registration!`) call it, so both apply the rule; the `reopened` event
payload gains `"assistant_capped" => true` when it fired. The cap is a ticket
override, so `AssistantPolicy#because` reads "capped at draft on this case
(reopened after rose closed it)" — the payload distinguishes it from a pause.

### 5.10 `close!` expires drafts

Inside `close!`'s transition block, after the status update:
`drafts.pending.each(&:expire!)`. The `closed` payload gains
`"expired_drafts" => n` when n > 0. `Draft#send!` on an expired draft raises
`InvalidTransition` (§5.5); the console never offers it (`actions_for` on a
closed case has no `:send_draft`).

### 5.11 Silent release — `SupportDesk.release_silent_assistants!`

```ruby
def release_silent_assistants!
  released = 0
  config.assistants.each_value do |cfg|
    bound = cfg.responds_within
    next if bound.nil?
    assistant = assistant(cfg.key)
    Ticket.open.assigned_to(assistant).awaiting_reply.where(waiting_since: ..bound.ago).find_each do |ticket|
      ticket.release!(by: :system, reason: :assistant_silent)
      released += 1
    rescue SupportDesk::Error => e
      logger&.warn("[support_desk] silent release of #{ticket.reference} refused: #{e.class}: #{e.message}")
    end
  end
  logger&.info("[support_desk] released #{released} silent assistant case(s)") if released.positive?
  released
end
```

`release!` re-checks under the lock that the case is still assigned, so a
reply that lands between the query and the lock loses nothing. The host
schedules the rake task every minute (solid_queue recurring, cron); the
README shows both. `:ticket_released (ticket, from: rose, reason:
:assistant_silent)` is what a host pages on.

### 5.12 Disclosure notice, and assignments announced

- `announce_assignment!(agent, first:)` returns early when `agent.is_a?
  (SupportDesk::Assistant)`. The disclosure line **is** the assistant's
  announcement; `announce_assignments` keeps governing humans.
- `post_disclosure_notice!(assistant)`: `line = assistant.config.line_for
  (:disclosure_line, self)`; posts it as a system message; stamps
  `metadata["assistant_disclosed_at"]`; pinned before the reply (§5.3).
  Posted once per case, and only when the mode includes a notice. A case the
  assistant only ever drafted on never gets one (a human sent every word).
- Signature: chats prints `display_name_for(author)` under a signed bubble;
  `Assistant#display_name` is the disclosed name, and `chat_signature?`
  (chats 0.3.3) is `false` for `:notice` / `:none`, so those modes print no
  signature at all.

### 5.13 `Ticket.open!` by an assistant (outreach)

`ensure_opener!(opener)`: when `opener.is_a?(SupportDesk::Assistant)`, raise
`AssistantNotAllowed` unless `opener.may_open_conversations? &&
RANK[opener.autonomy] >= RANK[:reply]`. Everything else is the 0.2 path: she
is seated with reason `opened`, the desk's `opening_line_from_support` posts,
her message is authored by her. The disclosure notice logic applies to her
first message here too (`speak!` is not involved — `post_opening!` calls
`post_disclosure_notice!` before `post_agent_message!` when the opener is an
assistant with a notice mode).

---

## 6. Data model and migration

### 6.1 Tables and columns

```
support_desk_assistants
  id, key (string, unique), active (bool, default true, not null), settings (json/jsonb), created_at, updated_at

support_desk_drafts
  id, ticket_id (fk → support_desk_tickets), author_type/author_id (polymorphic, not null),
  reviewed_by_type/reviewed_by_id (polymorphic, null), in_reply_to_id (message id, null),
  sent_message_id (message id, null), body (text, not null), sent_body (text, null),
  status (string, default "pending", not null), confidence (decimal 4,3, null),
  sources (json/jsonb), metadata (json/jsonb), rejection_reason (string, null),
  reviewed_at (datetime, null), created_at, updated_at
  indexes: (ticket_id, created_at) · (author_type, author_id, status) · UNIQUE (ticket_id) WHERE status = 'pending' [partial-index adapters]

support_desk_tickets  (+)
  assistant_autonomy (string, null), human_required_at (datetime, null), human_required_reason (string, null),
  assistant_turns_count (integer, default 0, not null), last_requester_message_id (fk type, null)
  index: (desk_id, human_required_at)
```

### 6.2 The migration template — `add_assistants_to_support_desk.rb.erb`

Same helpers and same idempotence style as `add_opened_by_to_support_desk_tickets`:

```ruby
class AddAssistantsToSupportDesk < ActiveRecord::Migration<%= migration_version %>
  def up
    primary_key_type, foreign_key_type = primary_and_foreign_key_types

    unless table_exists?(:support_desk_assistants)
      create_table :support_desk_assistants, id: primary_key_type do |t|
        t.string :key, null: false
        t.boolean :active, null: false, default: true
        t.send(json_column_type, :settings, default: json_column_default)
        t.timestamps
      end
      add_index :support_desk_assistants, :key, unique: true, name: "index_support_desk_assistants_on_key"
    end

    unless table_exists?(:support_desk_drafts)
      create_table :support_desk_drafts, id: primary_key_type do |t|
        t.references :ticket, null: false, type: foreign_key_type,
                              foreign_key: { to_table: :support_desk_tickets }, index: false
        t.references :author, polymorphic: true, null: false, type: foreign_key_type, index: false
        t.references :reviewed_by, polymorphic: true, null: true, type: foreign_key_type, index: false
        t.column :in_reply_to_id, foreign_key_type
        t.column :sent_message_id, foreign_key_type
        t.text :body, null: false
        t.text :sent_body
        t.string :status, null: false, default: "pending"
        t.decimal :confidence, precision: 4, scale: 3
        t.send(json_column_type, :sources, default: json_column_default)
        t.send(json_column_type, :metadata, default: json_column_default)
        t.string :rejection_reason
        t.datetime :reviewed_at
        t.timestamps
      end
      add_index :support_desk_drafts, [ :ticket_id, :created_at ], name: "index_support_desk_drafts_on_ticket"
      add_index :support_desk_drafts, [ :author_type, :author_id, :status ], name: "index_support_desk_drafts_on_author"
      if partial_indexes?
        # ONE pending proposal per case. Model + doctor everywhere else (docs 12 #13).
        add_index :support_desk_drafts, :ticket_id, unique: true, where: "status = 'pending'",
                  name: "index_support_desk_drafts_on_pending_ticket"
      end
    end

    add_column :support_desk_tickets, :assistant_autonomy, :string unless column_exists?(:support_desk_tickets, :assistant_autonomy)
    add_column :support_desk_tickets, :human_required_at, :datetime unless column_exists?(:support_desk_tickets, :human_required_at)
    add_column :support_desk_tickets, :human_required_reason, :string unless column_exists?(:support_desk_tickets, :human_required_reason)
    unless column_exists?(:support_desk_tickets, :assistant_turns_count)
      add_column :support_desk_tickets, :assistant_turns_count, :integer, null: false, default: 0
    end
    add_column :support_desk_tickets, :last_requester_message_id, foreign_key_type unless column_exists?(:support_desk_tickets, :last_requester_message_id)
    unless index_exists?(:support_desk_tickets, [ :desk_id, :human_required_at ], name: "index_support_desk_tickets_on_human_required")
      add_index :support_desk_tickets, [ :desk_id, :human_required_at ], name: "index_support_desk_tickets_on_human_required"
    end

    # The turn token for cases that already exist: the newest requester
    # message in each case's conversation. ORDER BY rather than MAX(id) so it
    # works where ids are UUIDs (PostgreSQL has no max(uuid)).
    execute <<~SQL
      UPDATE support_desk_tickets
         SET last_requester_message_id = (
           SELECT m.id FROM chats_messages m
            WHERE m.conversation_id = support_desk_tickets.conversation_id
              AND m.sender_type = support_desk_tickets.requester_type
              AND m.sender_id   = support_desk_tickets.requester_id
              AND m.kind = 'text'
            ORDER BY m.created_at DESC, m.id DESC
            LIMIT 1)
       WHERE last_requester_message_id IS NULL
         AND conversation_id IS NOT NULL
    SQL
  end

  def down
    remove_index  :support_desk_tickets, name: "index_support_desk_tickets_on_human_required"
    remove_column :support_desk_tickets, :last_requester_message_id
    remove_column :support_desk_tickets, :assistant_turns_count
    remove_column :support_desk_tickets, :human_required_reason
    remove_column :support_desk_tickets, :human_required_at
    remove_column :support_desk_tickets, :assistant_autonomy
    drop_table :support_desk_drafts
    drop_table :support_desk_assistants
  end

  private
  # primary_and_foreign_key_types / partial_indexes? / json_column_type / json_column_default — copied verbatim from create_support_desk_tables
end
```

The migration lives in the three places 12 #15 names: the generator template,
the dummy app's copy (`test/dummy/db/migrate/20260101000006_add_assistants_to_support_desk.rb`),
and the source-text assertions in `test/generators/install_generator_test.rb`
and `upgrade_generator_test.rb`.

### 6.3 Rolling-deploy analysis

| change | old process (0.2) behaviour while 0.3 is rolling out |
|---|---|
| new tables | never touched |
| new nullable columns / defaulted integer | ignored by inserts, read as nil/0 by nothing |
| `last_requester_message_id` | not written by old registrations; the migration's UPDATE covers existing rows; a message registered by an old process leaves the token one behind until the next requester message — an assistant is not yet configured, so no turn is emitted anyway |
| `RELEASE_REASONS` += `assistant_silent` | only new code writes it; old code never re-saves a released row (`release!` returns early) |
| `Event::KINDS` additions | only new code writes them; Event rows are readonly once written |
| `Desk#agents` includes the assistant | only when an assistant is configured, i.e. only in new code |

**Rolling deploy is safe.** Configure the assistant **after** every process is
on 0.3.0 (the CHANGELOG says so), since an old process that saw
`config.assistant` would raise `NoMethodError` at boot.

---

## 7. Surfaces

### 7.1 Console — the case page

Partial contracts (all under `app/views/support_desk/console/tickets/`, all
rendering **only** what `actions` contains):

| partial | locals | renders |
|---|---|---|
| `_draft.html.erb` (new) | `ticket, draft, actions` | when `draft` (pending): the author's disclosed name + "Propuesta", the body (pre-wrap), `confidence_percent` pill when present, `sources` list (title → url, `rel="noopener"`), `stale?` warning block; buttons: **Enviar** (`send_draft` with `draft_id`; when stale, the form carries `even_if_stale=1` and the button reads "Enviar de todos modos"), **Editar** (link to `?compose=reply&draft=ID`), **Descartar** (`reject_draft` with an optional `reason` text input). Buttons appear only if `:send_draft` / `:reject_draft` are in `actions`. |
| `_composer.html.erb` | + `draft` (optional) | when `params[:draft]` names the pending draft and `:send_draft` is offered: textarea prefilled with `draft.body`, hidden `draft_id`, form URL `send_draft`, submit reads "Enviar propuesta editada"; a small line "Editando la propuesta de Rose · cancelar" (link back to `?compose=reply`). Otherwise unchanged. |
| `_message.html.erb` | | when `message.author.is_a?(SupportDesk::Assistant)`: a small robot mark before the signature and `title=` with `metadata["confidence"]` when present; when `message.metadata["drafted_by"]`: a "propuesta de %{name}" mark after the human signature. |
| `_actions.html.erb` | | + **Pausar asistente** / **Reanudar asistente** (`pause_assistant` / `resume_assistant`) when offered. |
| `_assignment.html.erb` | | picker option values are `SupportDesk.actor_key(agent)`; the assistant appears with her disclosed name; header line "Rose se ocupa · %{used}/%{max} turnos" when `held_by_assistant?`. |
| `_context_card.html.erb` | | + requester `support_context` pairs; + an "Asistente" row: level and `because` (`ticket.assistant_policy.to_s`) when the desk has one. |
| `_timeline.html.erb` | | renders `Timeline::Entry#draft?` entries (superseded/rejected/expired/sent drafts, greyed, with status and reviewer) and the new event kinds with their payload (`escalated` shows `summary` as a callout). |
| `_ticket_row.html.erb` / index | | badge "Necesita persona" when `human_required?`; "Propuesta lista" when `pending_draft` (preloaded via `includes(:pending_draft)`); assignee column shows the disclosed name. |
| `_tabs.html.erb` | | the `needs_human` tab from `queue.tabs` (no change needed: tabs are data-driven). |

`SupportDesk::Console::Index#support_queue_tickets` adds `:pending_draft` to
its `includes`.

### 7.2 Requester engine

- `_human_door.html.erb` (§4.16) — the button.
- `_ticket_row.html.erb`: "Atendida por %{name}" line when `held_by_assistant?`
  (disclosed name), "Una persona del equipo seguirá con tu consulta" when
  `human_required?`.
- `show` (redirect into chats) unchanged.

### 7.3 Queue

§4.17. `Queue#tabs` labels come from `support_desk.queue.tabs.needs_human`.

---

## 8. Locales

Added to `config/locales/es.yml` and `en.yml` (Spanish shown; English
mirrors). Hosts override any key in their own locale files.

```yaml
es:
  support_desk:
    assistant:
      disclosed_name: "%{name} · asistente virtual"
    system:
      assistant_disclosure: "%{name} es el asistente virtual de %{desk}. Si prefieres hablar con una persona, pídelo aquí mismo y te pasamos con el equipo."
      handed_off_to_humans: "Te paso con una persona del equipo. Normalmente contestamos en menos de %{reply_within}."
      human_requested: "Una persona del equipo seguirá con tu consulta. Normalmente contestamos en menos de %{reply_within}."
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
        confidence: "confianza %{percent} %"
        sources: "Fuentes"
        stale: "El cliente ha escrito desde esta propuesta. Léelo antes de enviar."
        editing: "Editando la propuesta de %{name}"
        cancel_edit: "cancelar"
        reason_placeholder: "¿Por qué la descartas? (opcional, ayuda a mejorar)"
      actions:
        send_draft: "Enviar"
        send_draft_anyway: "Enviar de todos modos"
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
        draft_sent: "%{actor} envió la propuesta de %{assistant}%{edited}"
        draft_sent_edited: " (editada)"
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
        unknown_draft: "Esa propuesta ya no existe o ya se resolvió."
        no_pending_draft: "No hay ninguna propuesta pendiente en este caso."
        stale_turn: "El cliente ha escrito desde entonces. Léelo y vuelve a enviar."
        assistant_not_allowed: "El asistente no puede hacer eso en este caso: %{detail}"
        not_an_assistant: "Esa acción es solo para el asistente."
    notifications:
      draft_proposed: "%{name} propone una respuesta en %{reference}"
      escalated: "%{reference} necesita una persona: %{reason}"
```

`errors.assistant_not_allowed` interpolates `detail` with the error's
`because` — the one English-in-a-Spanish-flash exception we accept, since
`because` names a configuration rule and the reader is staff.

---

## 9. The host harness contract, and what the generator writes

### 9.1 The contract

A harness is any code that:

1. subscribes to `:assistant_turn` and, at some later moment, holds a
   `ticket`, an `assistant` and the `turn` token it was given;
2. **checks `ticket.assistant_turn == turn` before spending money** on a model
   call (the cheap early exit for bursts);
3. reads `ticket.brief` and/or `ticket.transcript` (never the chats models
   directly — the brief already applies the roles, the policy and the
   redaction of internal notes the gem decided on);
4. hands its answer to **exactly one** of `ticket.respond!` (let the policy
   decide), `ticket.draft!` (force a draft), `ticket.reply!` (force a send or
   raise), `ticket.escalate!` (hand off), `ticket.note!` (say something to
   humans only), `ticket.change_topic!` / `attach_subject!` (triage) — all
   with `by: assistant` and, for the speaking verbs, `turn: turn`;
5. rescues `SupportDesk::StaleTurn` and `SupportDesk::Locked` as normal
   outcomes, and lets `AssistantNotAllowed` surface as a bug (it means the
   harness ignored `policy.may_*` the brief told it about).

Everything else — debounce, retries, provider, model, tools, prompt, cost
caps, language, evaluation — is the host's. The gem never imports the
harness, never knows the provider, never sees the prompt.

### 9.2 `app/jobs/support/assistant_turn_job.rb` (generated)

```ruby
# frozen_string_literal: true

module Support
  # Runs one turn of the assistant on one case. Enqueued from
  # `config.on(:assistant_turn)` in config/initializers/support_desk.rb with a
  # short delay so a burst of messages becomes one answer.
  class AssistantTurnJob < ApplicationJob
    queue_as :support

    # A job that raises is retried by your queue; a job whose turn went stale
    # is simply finished — the newer turn's job answers.
    discard_on SupportDesk::StaleTurn, SupportDesk::Locked

    def perform(ticket_id, assistant_key, turn)
      ticket = SupportDesk::Ticket.find(ticket_id)
      return unless ticket.assistant_turn == turn        # the requester wrote again while we waited

      assistant = SupportDesk.assistant(assistant_key)
      policy    = ticket.assistant_policy(assistant)
      return unless policy.may_observe?                  # paused, closed, or a person took over meanwhile

      answer = Support::<%= class_name %>.answer(ticket.brief(assistant: assistant), ticket.transcript)

      case answer.kind
      when :answer
        ticket.respond!(answer.text, by: assistant, turn: turn,
                        confidence: answer.confidence, sources: answer.sources,
                        metadata: answer.metadata.merge("summary" => answer.summary))
      when :hand_off
        ticket.escalate!(by: assistant, reason: answer.reason, summary: answer.summary)
      when :note
        ticket.note!(answer.text, by: assistant)
      when :nothing
        nil
      end
    end
  end
end
```

### 9.3 `app/services/support/<name>.rb` (generated, provider-blank)

```ruby
# frozen_string_literal: true

module Support
  # Your assistant's brain. The gem hands you the case as facts
  # (`brief.to_text`, `transcript.to_text`) and takes back an Answer; which
  # model, which tools and which words are yours.
  module <%= class_name %>
    Answer = Struct.new(:kind, :text, :confidence, :sources, :reason, :summary, :metadata, keyword_init: true) do
      def initialize(kind:, text: nil, confidence: nil, sources: [], reason: nil, summary: nil, metadata: {})
        super
      end
    end

    # brief.to_h[:assistant][:may] tells you what this turn may end in. Do not
    # ask for more: `respond!` will turn a send into a draft on its own, and
    # `close!` below :resolve raises.
    def self.answer(brief, transcript)
      raise NotImplementedError, "wire your model here — see the README, 'Assistants'"
    end
  end
end
```

### 9.4 `test/jobs/support/assistant_turn_job_test.rb` (generated)

Stubs `Support::<Name>.answer` to return `Answer.new(kind: :answer, text:
"…", confidence: 0.9)`, opens a case with `open_support_ticket`, performs the
job with `ticket.assistant_turn`, and asserts `assert_pending_draft` under the
default `:draft` autonomy and `assert_awaiting_requester` under
`with_assistant_config(autonomy: :reply)`. Also asserts a stale turn performs
nothing (`refute_assistant_spoke`).

### 9.5 The initializer stanza (generated)

```ruby
  config.assistant :<%= key %> do |<%= key %>|
    <%= key %>.name       = "<%= human_name %>"
    <%= key %>.autonomy   = :draft
    # REQUIRED — there is no default. One of:
    #   :signature_and_notice  "— <%= human_name %> · asistente virtual" under each reply, and one notice before the first
    #   :signature             the signature only
    #   :notice                nameless replies (as the desk) and the notice
    #   :none                  nothing — your explicit call
    <%= key %>.disclosure = <%= disclosure || "nil # ← choose" %>
    <%= key %>.max_turns  = 6
    <%= key %>.responds_within = 3.minutes
    # <%= key %>.hand_off_when { |ticket, message| message.body.match?(/\b(persona|humano|agente)\b/i) }
    # <%= key %>.cap { |ticket| :draft if ticket.requester.try(:vip?) }
  end

  config.on(:assistant_turn) do |ticket, assistant, message, turn:|
    Support::AssistantTurnJob.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn)
  end
```

---

## 10. Compliance and safety

### 10.1 Disclosure

- **Required configuration**, four modes, validated at boot (12 #22). The
  gem carries the AI Act art. 50(1) reading from 14 §3 in the README as
  guidance ("people interacting with an AI system must be informed unless it
  is obvious; applies since 2 August 2026"), with the standing caveat that
  counsel confirms in the host's legal repo. The gem does not decide for the
  host; it makes the host decide.
- Every autonomous assistant message is `author: assistant` in the database
  regardless of mode — disclosure is about what the customer *sees*; the
  record is always honest. `Ticket#export` labels those messages `from:
  "assistant"` in every mode, so a GDPR export tells the truth even where the
  thread was nameless.
- Human-sent drafts are the human's words to the customer and `from:
  "support"` in the export; provenance stays in message metadata.

### 10.2 Bounded authority (invariants 2, 6, 7)

The assistant can never: speak below `:reply`; close below `:resolve`; hold a
case she may not answer; hold a human-required case; take a case a human
holds; assign a case to a human; speak twice to one requester message; speak
into a closed case; speak after `max_turns`; act while paused or inactive.
Each is a model rule with a test.

### 10.3 Money and identity

Topic caps are the mechanism: `topic :payments, assistant: :draft` means no
autonomous word about money by construction, whatever the prompt says. The
README's CarHey-shaped example shows `payments :draft`, `verification
:observe`.

### 10.4 What the model sees

`Brief` includes `subject.support_context` and `requester.support_context` —
host-authored maps. The README states in bold that these are sent to a
third-party model, and recommends keeping identity documents, full card
numbers and bank details out of them (show a masked IBAN, a KYC *status*, not
a number).

### 10.5 Moderation and audit (host integration points)

- A reported assistant message reaches chats' moderate contract with an
  `Assistant` author. Hosts whose moderation flags require a `User` (CarHey)
  must map the owner (desk owner / nil) before launch — flagged in §16 and in
  the README's "Before you launch" list.
- The audit umbrella `ticket_transitioned` fires for every new Event kind
  with the assistant as `by:`; `SupportDesk.actor_key(assistant)` is
  `"gid://app/SupportDesk::Assistant/1"`-derived and stable.

### 10.6 Abuse

The requester-facing `request_human!` is idempotent and scoped to the
requester's own case; it cannot be used to spam a queue (one flag per case,
priority bumps once). `respond!` is server-side only; there is no
requester-reachable path that makes the assistant speak.

---

## 11. Observability

### 11.1 What carries the decision

| where | what |
|---|---|
| `chats_messages.metadata` on an autonomous reply | `assistant`, `turn`, `confidence`, `sources`, `policy` (+ whatever the harness passed) |
| `chats_messages.metadata` on a human-sent draft | `drafted_by`, `draft_id`, `edited` |
| `support_desk_drafts` row | body, confidence, sources, `metadata.policy`, status, reviewer, `sent_body`, `rejection_reason` |
| Event `assistant_withheld` | `assistant`, `reason`, `policy` |
| Event `escalated` / `human_requested` | `reason`, `summary`, `from` |
| Event `assistant_paused` / `assistant_resumed` | `reason` / `from` |
| Event `draft_sent` / `draft_rejected` | `draft`, `assistant`, `edited`, `stale`, `message` / `reason` |
| Event `reopened` | `assistant_capped: true` when the cap applied |
| Event `closed` | `expired_drafts: n` |

### 11.2 Scopes for the two numbers that matter

```ruby
# containment: cases the assistant resolved that stayed resolved
SupportDesk::Ticket.resolved_by_assistant.where(reopen_count: 0).closed_between(range).count
# acceptance: of the drafts humans reviewed, how many went out as written
drafts = SupportDesk::Draft.by(rose).reviewed.where(reviewed_at: range)
drafts.verbatim.count / drafts.count.to_f
SupportDesk::Draft.by(rose).edited.count · .rejected.count
# escalations by reason
SupportDesk::Event.of_kind(:escalated).where(created_at: range).group("payload->>'reason'")  # PG; the README shows the portable Ruby group_by
```

`Metrics` proper stays 0.4; these scopes are documented as the day-one
dashboard.

### 11.3 Instrumentation

Every new event is on `ActiveSupport::Notifications` as
`"<event>.support_desk"` with `args:`, exactly like the existing catalogue.

---

## 12. Test plan

The suite today is 804 tests across SQLite and PostgreSQL × Rails 7.2 / 8.0 /
8.1 (Appraisals). Everything below is added to it; nothing existing changes
its expectation except where this PRD changes behaviour (each such change is
listed in §13 and has its old assertion updated *deliberately*).

### 12.1 Invariant 1 — nothing changes without an assistant

`test/assistants/no_assistant_test.rb`: with no `config.assistant`, run the
full requester → agent → close → reopen story and assert: no
`support_desk_assistants` or `support_desk_drafts` rows; no Event of a new
kind; no `assistant_turn` / `draft_*` / `assistant_*` dispatcher event
(`capture_support_events(*ALL_NEW)` empty); no system message beyond 0.2's;
`desk.agents == desk.humans`; `actions_for(lucia)` equals the 0.2 set;
`Queue#counts[:needs_human] == 0` and the tab is present but empty.

### 12.2 Configuration

`test/configuration/assistant_configuration_test.rb`: every setter's
validation (good, bad, nil); `disclosure` missing ⇒ `ConfigurationError` at
`configure`, message names the four modes; two assistants + unnamed default
desk ⇒ error; `desk.assistant = :nope` ⇒ error; implicit single assistant;
line settings (String interpolation checked on assignment, Symbol existence in
`line_problems`, block returns String/nil); topic `assistant:` option
validation and inheritance (branch cap applies to leaf, leaf overrides);
`Topic::Unknown#assistant_cap == :observe`.

### 12.3 Policy — the table test

`test/assistants/assistant_policy_test.rb`, parametrised: autonomy ∈ 5 ×
topic cap ∈ {nil, 4 levels} × `cap` block ∈ {nil, :draft} × override ∈ {nil,
"off", "draft"} ⇒ expected level = min, `because` names the deciding rule
(ties: assistant first). Then floors, each alone and stacked: inactive ⇒ off;
closed ⇒ ≤ observe; human_required ⇒ ≤ observe; human holds ⇒ ≤ draft;
`ignoring_holder: true` lifts only the last; Null policy on a desk with no
assistant. `to_h` shape snapshot.

### 12.4 Verb matrix for an assistant actor

`test/assistants/assistant_verbs_test.rb`: for each level × each verb in
`VERBS_BY_LEVEL[:resolve]`, on an open unassigned awaiting case: allowed verbs
succeed, the rest raise `AssistantNotAllowed` whose message contains
`because`. Extra rows: `assign!(to: lucia, by: rose)` raises at every level;
`assign!(to: rose, by: rose)` on a human-held case raises; `close!` at
`:reply` raises; `reply!` when `awaiting_requester?` raises
(`:not_your_turn`); `hand_off!(to: lucia, by: rose)` works when she holds.
`actions_for(rose)` equals `allowed_verbs` adjusted for state, checked in
`test/console/console_offered_actions_test.rb` (extended, see 12.10).

### 12.5 `respond!` outcome matrix

`test/assistants/respond_test.rb`: level ∈ {observe, draft, reply, resolve} ×
holder ∈ {none, rose, lucia} × awaiting ∈ {agent, requester} × turns_left ∈
{some, zero, unlimited} ⇒ `sent` / `drafted` / `withheld(:policy |
:not_your_turn)`, plus: at zero turns and `:reply`, `drafted` **and**
`escalated` (human_required, seat released, priority high, hand-off line
posted once, `reason "max_turns"`); `sent` increments
`assistant_turns_count`, stamps metadata (assistant, turn, confidence,
sources, policy), seats her (`taken`), posts **no** assignment announcement,
posts the disclosure notice once and pinned before the bubble (frozen-time
test), sets `first_agent_reply_at`, emits `:agent_replied`; `drafted`
supersedes a previous pending draft and emits `:draft_proposed`;
`withheld` writes the Event and emits; `by:` a User ⇒ `NotAnAssistant`;
blank body ⇒ `ArgumentError`; closed account ⇒ `Locked`.

### 12.6 Turn and concurrency

`test/assistants/turn_test.rb`: token nil before any requester message; set
by the opening message; unchanged by agent/assistant/system messages; changes
per requester message; survives reopen; `respond!(turn: old)` ⇒ `StaleTurn`
and writes nothing; `turn: nil` bypasses; `:assistant_turn` emitted for the
opening message and every later requester message, **not** for a desk-opened
case until the requester replies, **not** at `:off`, **not** when paused,
**still** at `:observe` (human_required); `hand_off_when` true ⇒
`human_requested` event + floored turn; `hand_off_when` raising ⇒ reported,
turn proceeds; `cap` raising inside emission ⇒ reported, no turn.
`test/assistants/concurrency_test.rb` (PostgreSQL only, threads): two
`respond!` on the same turn ⇒ exactly one message; a `respond!` racing a
requester message ⇒ either the message posts first and the response is a
reply to it, or `StaleTurn` — never two assistant messages; two `draft!` ⇒
one pending.

### 12.7 Drafts

`test/models/draft_test.rb`: statuses and scopes; `stale?` (nil/nil not
stale); `send!` verbatim ⇒ author human, `metadata` `{drafted_by, draft_id,
edited: false}`, `sent_body` nil, event + dispatcher event, `:agent_replied`,
takeover of the assistant's seat; `send!(body:)` edited ⇒ `sent_body`,
`edited: true`; `send!` stale ⇒ `StaleTurn` unless `even_if_stale`; `send!`
by an Assistant / `:system` ⇒ `NotAllowed`; `send!` on non-pending ⇒
`InvalidTransition`; `reject!` with/without reason; `close!` expires pending
(`closed` payload), `send!` afterwards raises; pause supersedes pending;
`pending_draft` association preloads; `Timeline` includes non-pending drafts
as entries.

### 12.8 Hand-offs

`test/assistants/hand_off_test.rb`: `escalate!` by rose (releases seat with
`escalated`, flags, priority high, keeps pending draft, posts hand-off line,
`escalated` event with summary, `:ticket_escalated`); idempotent repeat writes
nothing; on a human-held case flags without releasing; on closed ⇒
`InvalidTransition`; by a human agent ⇒ allowed; by `:system` ⇒ allowed;
`request_human!` by the requester (flag, `human_requested` event, line,
dispatcher event); by another user ⇒ `NotAllowed`; on a closed
`reopen_on_reply` case ⇒ reopens then flags; on a `:locked` desk ⇒ `Locked`;
when the requester is unavailable ⇒ `Locked`; on a desk with no assistant ⇒
flags, no line. Humans outrank: `reply!(by: lucia)` on rose-held under
`:assignee_only` ⇒ `drop_in_takeover`, rose released `handed_off`;
`may_reply?(lucia)` true. Hand back: `hand_off!(to: rose, by: lucia)` clears
flag + override, payload `handed_back`; refused when topic caps at `:draft`
(`AssistantNotAllowed`, because names the topic); `assign!(to: rose, by:
admin)` same.

### 12.9 Pause, resume, reopen cap, silent release, outreach

`test/assistants/pause_resume_test.rb`: pause releases her seat, supersedes
drafts, floors policy to off, blocks turns; by rose ⇒ `NotAllowed`; resume
clears; both idempotent; on closed ⇒ pause raises.
`test/assistants/reopen_cap_test.rb`: rose closes at `:resolve`, requester
writes ⇒ reopened, unassigned, `assistant_autonomy == "draft"`, payload
`assistant_capped`, her next `respond!` drafts; the same via `reopen!(by:
lucia)`; a **human**-closed case still restores the human's seat (regression);
a paused case stays `"off"` through the cap.
`test/assistants/silent_release_test.rb`: `release_silent_assistants!`
releases only awaiting cases past `responds_within`, writes
`release_reason: assistant_silent`, emits `:ticket_released`, returns the
count, ignores `responds_within: nil`, skips cases where she is not the
holder; the rake task calls it.
`test/assistants/outreach_test.rb`: `Ticket.open!(by: rose)` ⇒
`AssistantNotAllowed` unless `may_open_conversations` and autonomy ≥ `:reply`;
when allowed, she is seated `opened`, the notice posts before her message in a
notice mode, no turn is emitted until the requester replies.

### 12.10 Console and engine

`test/console/console_offered_actions_test.rb` — the state-by-state table
gains columns for `send_draft`, `reject_draft`, `pause_assistant`,
`resume_assistant` for a human agent (with/without pending draft, paused or
not, closed, requester unavailable, `:assignee_only` with an assistant
holder), and a second table for `actions_for(rose)` per level and state. Both
still checked twice: against the method and against what the console accepts
over HTTP (the new verbs are POSTs the routing concern draws —
`test/console/console_routes_test.rb` asserts the four new routes).
`test/console/console_drafts_test.rb`: send verbatim, send edited (composer
with `draft_id`), send stale ⇒ flash `stale_turn`, send with
`even_if_stale=1`, unknown draft ⇒ flash, reject with reason, non-String
`draft_id` ⇒ 422 invalid input; pause/resume flows and flashes; agent picker
accepts actor keys, resolves a bare id only when unambiguous (a User and an
Assistant sharing id 1 ⇒ bare "1" refused, keys accepted).
`test/system/console_draft_review_test.rb` (browser): a pending draft renders
with confidence and sources; Enviar posts and the bubble appears with the
human's signature and the "propuesta de Rose" mark; Editar prefills the
composer; Descartar with a reason; stale warning appears after `ask_again`.
`test/engine/request_human_test.rb`: own ticket ⇒ flag + redirect + notice;
somebody else's ⇒ 404; door partial renders only when `assistant_in_play? &&
!human_required?`.

### 12.11 Context

`test/assistants/transcript_test.rb`: roles for requester / human /
assistant / system / human-sent draft (`assisted: true`); names; tombstones;
attachments; `last`, `since`, `to_text` deterministic (frozen time snapshot).
`test/assistants/brief_test.rb`: `to_h` shape and keys; `may` / `may_not`
match the policy; notes include escalation summaries; drafts include
outcomes and rejection reasons; requester and subject `support_context`
present; `to_text` contains no imperative sentences from the gem (grep for
"You are" / "Debes" — a guard against instructions leaking into facts).
`test/models/ticket_export_test.rb`: `from: "assistant"` for autonomous
messages, `"support"` for human-sent drafts.

### 12.12 Doctor, generators, docs, rake

`test/doctor_test.rb`: each new check red and green.
`test/generators/install_generator_test.rb` / `upgrade_generator_test.rb`:
the new migration is copied once, idempotent, source-text assertions on the
partial index and the UPDATE; `assistant_generator_test.rb`: the four files
and the initializer stanza (disclosure left as the required blank when not
passed), locale keys appended once.
`test/docs_test.rb`: the README's assistant snippets (config stanza, harness
job, `respond!` outcome, `Draft#send!`) compile and behave.
`test/tasks/support_desk_rake_test.rb`: both tasks.

### 12.13 Matrix and gates

Every PR in §15 passes `bundle exec rake test` on SQLite **and** the
PostgreSQL leg, the three Appraisals, and rubocop, with the dummy schema dump
removed between legs as today. Coverage must not drop below the current line
(97.5 %).

---

## 13. Compatibility, upgrade, CHANGELOG

### 13.1 Behaviour changes for hosts **with** an assistant configured (none otherwise)

- `Desk#agents` includes the assistant (use `desk.humans` / `agents_to_notify` to page people).
- `announce_assignments` never announces an assistant; the disclosure line does.
- A human reply on an assistant-held case takes it over under every `reply_policy`.
- A reopen after an assistant close leaves the case unassigned and caps the assistant at `:draft`.
- `close!` expires pending drafts.
- `Ticket#reply!` and `Ticket#post_agent_message!` accept `metadata:`.
- `Queue::TABS` gains `:needs_human` (a host that switch-cases on tabs adds one branch; `Queue#scope` already routes it).
- Console agent picker values are actor keys (bare ids still accepted when unambiguous, for one release).

### 13.2 Upgrade steps (README + CHANGELOG)

1. `bundle update support_desk chats` (0.3.0 / 0.3.3).
2. `rails generate support_desk:upgrade` → `rails db:migrate` (additive; rolling-safe; backfills the turn token).
3. Deploy **everything** to 0.3.0 **before** adding `config.assistant` (an old process would not know the method).
4. Add the assistant (`rails g support_desk:assistant Rose`), choose `disclosure`, wire the job, schedule `rake support_desk:release_silent_assistants` every minute, subscribe your notifiers to `draft_proposed` / `ticket_escalated` / `human_requested`.
5. Render `support_desk/tickets/_human_door` in your thread.
6. Run `SupportDesk.doctor` — every new check green.
7. Start at `:draft`. Move topics up one level at a time, from the acceptance rate.

### 13.3 CHANGELOG entry (draft)

```
## [0.3.0] - TBD

**Assistants.** AI agents are first-class: a persona the gem ships, a policy
the model enforces, drafts a human reviews, a turn token that makes a late
answer harmless, and two exits every customer has. No LLM in the gem: you
bring the model, the gem brings the guardrails.

### Added
- `SupportDesk::Assistant` and `config.assistant :key do … end` (name, avatar, autonomy, disclosure — required, no default —, max_turns, responds_within, may_open_conversations, hand_off_line, human_requested_line, disclosure_line, hand_off_when, cap); `desk.assistant = :key`; topic option `assistant:`.
- `SupportDesk::AssistantPolicy` and `ticket.assistant_policy` — five levels, ceilings, floors, `because`.
- `ticket.respond!` / `draft!` / `escalate!` / `request_human!` / `pause_assistant!` / `resume_assistant!`; `ticket.assistant_turn`; `SupportDesk::Outcome`.
- `SupportDesk::Draft` with `send!` / `reject!`, one pending per case.
- `ticket.transcript`, `ticket.brief`, `Requester#support_context`.
- Events: `assistant_turn`, `draft_proposed`, `draft_sent`, `draft_rejected`, `assistant_withheld`, `ticket_escalated`, `human_requested`, `assistant_paused`, `assistant_resumed`.
- Console verbs `send_draft`, `reject_draft`, `pause_assistant`, `resume_assistant`; the draft card; the `needs_human` queue tab; engine route `request_human` and the `_human_door` partial.
- `rake support_desk:release_silent_assistants`; doctor checks; `support_desk:assistant` generator; TestHelpers.
- Errors `NotAnAssistant`, `AssistantNotAllowed`, `StaleTurn`.

### Changed (only when an assistant is configured — see 13.1)

### Upgrading (see 13.2)
```

---

## 14. README additions

A new top-level section **"🤖 Assistants"** between "Writing first" and the
console, written in the README's narrative voice, containing: the two-minute
story (config stanza → job → what the human sees); the five levels table;
ceilings and floors in one diagram; `respond!` outcomes; drafts in the
console with a screenshot-free description; the two exits; disclosure — the
four modes and the *required* choice, with the art. 50 paragraph and the
counsel caveat; the silent-release task and why; "What the model sees" with
the PII warning in bold; "Before you launch" checklist (doctor, moderation
mapping, notifiers, the door); and the reference tables (configuration,
`Ticket` verbs and readers, `Draft`, `Outcome`, `Transcript`, `Brief`,
events, errors, console verbs, TestHelpers). The "Upgrading" section gains
13.2. `test/docs_test.rb` pins the snippets.

---

## 15. Delivery plan and acceptance gates

Four PRs on `rameerez/support_desk`, one on `rameerez/chats`, one on
`carheyapp/carhey`. Each gem PR: `bundle exec rake test` (SQLite), the PG leg,
three Appraisals, rubocop, `docs_test`; reviewed line by line against this
document before merge.

| PR | contents | gate |
|---|---|---|
| chats **#7** — 0.3.3 | `message!(metadata:)`, `chat_signature?` veto, README + CHANGELOG, release | tests for both seams; support_desk's suite green against the branch (path Gemfile) |
| support_desk **A — kernel** | §4.1–4.14 except surfaces: configuration, `Assistant`, `AssistantPolicy`, `Draft`, `Outcome`, ticket columns + verbs + gates, events, migration + generators (upgrade/install), doctor, rake, TestHelpers; tests §12.1–12.9, 12.12 | invariant-1 test green; policy table + verb matrix + outcome matrix complete; concurrency test green on PG |
| support_desk **B — surfaces** | §4.15–4.17, §7, §8: console verbs + views, engine route + door, queue tab, locales, timeline entries; tests §12.10 | offered-actions table green both ways; browser test green on the 16-leg CI matrix |
| support_desk **C — context + DX** | §4.8–4.10, §4.20 assistant generator, §9 templates, §14 README, CHANGELOG, VERSION 0.3.0; tests §12.11–12.12 | docs_test green; README covers every public name introduced (grep audit as in #5) |
| support_desk **release** | tag `v0.3.0`, GitHub release, gem push (owner MFA) | rubygems SHA matches the built gem |
| carhey **D** | §16 | `bin/ci` green in an isolated-DB worktree; doctor green in prod after deploy |

---

## 16. CarHey integration — "Rose"

### 16.1 Configuration (`config/initializers/support_desk.rb`)

```ruby
config.assistant :rose do |rose|
  rose.name            = "Rose"
  rose.avatar          = "rose-avatar.png"                # brand-styled, not a photo of a person
  rose.autonomy        = :draft                            # fortnight one: every word human-sent
  rose.disclosure      = :signature_and_notice             # CarHey's explicit choice (owner to confirm; recommended)
  rose.max_turns       = 6
  rose.responds_within = 3.minutes
  rose.hand_off_when { |_ticket, message| message.body.to_s.match?(/\b(persona|humano|agente|alguien de verdad)\b/i) }
  rose.cap { |ticket| :observe if ticket.requester.banned? || ticket.requester.shadowbanned? }
end

config.topics do
  topic :ride,         about: Ride,                icon: "map",                assistant: :draft
  topic :payments,     about: Payouts::Withdrawal, icon: "banknotes",          assistant: :draft     # money: never autonomous
  topic :verification,                             icon: "identification",     assistant: :observe   # identity: triage only
  topic :account,                                  icon: "user-circle",        assistant: :draft
  topic :app,                                      icon: "device-phone-mobile", assistant: :draft    # → :reply after the soak
  other                                            icon: "lifebuoy",           assistant: :draft
end

config.on(:assistant_turn) do |ticket, assistant, _message, turn:|
  Support::AssistantTurnJob.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn)
end
config.on(:draft_proposed)   { |ticket, draft| Support::DraftProposedNotifier.with(ticket:, record: draft).deliver(ticket.agents_to_notify) }
config.on(:ticket_escalated) { |ticket, from:, reason:, by:| Support::NeedsHumanNotifier.with(ticket:, record: ticket, reason:).deliver(ticket.agents_to_notify); Operations::SupportTicketAlertJob.perform_later(ticket.id, escalated: reason) }
config.on(:human_requested)  { |ticket, by:, reason:| Support::NeedsHumanNotifier.with(ticket:, record: ticket, reason:).deliver(ticket.agents_to_notify) }
config.on(:ticket_released)  { |ticket, from:, reason:| Support::NeedsHumanNotifier.with(ticket:, record: ticket, reason:).deliver(ticket.agents_to_notify) if reason == :assistant_silent }
```

`User#support_context` (new): `{ "Cuenta" => created_at.to_fs(:short),
"KYC" => kyc_status_label, "Saldo" => wallet.balance.format, "Viajes
completados" => rides_completed_count, "Retiradas" => withdrawals.count }` —
statuses and counts, **no** DNI, IBAN or document images.

### 16.2 The harness

`Support::AssistantTurnJob` as generated (§9.2), `queue_as :support` on
solid_queue. `Support::Rose.answer(brief, transcript)`:

- `Ai::Client.anthropic` (the one client CarHey constructs), model chosen by
  the host (`claude-sonnet-5` as the default; Fable/Opus for harder desks if
  cost allows), Spanish, structured output matching `Answer`.
- System prompt (host-owned, in `app/prompts/support/rose.md.erb`): the
  desk's voice, what Rose may and may not do **read from
  `brief.to_h[:assistant][:may]`**, the disclosure posture, the rule "answer
  only from the sources you were given; when you cannot, hand off", the
  reply-within promise from the brief.
- Tools (read-only, scoped to the requester): `search_help`(query) over the
  FAQ/guide markdown in `carhey-business` mirrored into `app/content/help/`
  (simple BM25 in Ruby to start; embeddings later); `lookup_ride(id)`,
  `lookup_withdrawal(id)` returning the same `support_context` maps the
  console shows; nothing that writes.
- `confidence` from the model's self-report **and** a floor: no source cited
  ⇒ `min(confidence, 0.5)`. Below 0.6 ⇒ `kind: :hand_off, reason:
  "low_confidence"` with a one-paragraph `summary` for the human.
- Cost cap: one model call per turn; transcript limited to the last 40 turns
  by `brief(transcript_limit: 40)`; a job that exceeds 60 s aborts (`StaleTurn`
  will likely follow anyway).

### 16.3 madmin

- `app/views/madmin/support_tickets/_draft.html.erb` (ejected from the gem's
  partial, restyled): the card above the composer.
- `_message.html.erb` (ejected chats view): call `chats_message_signature`
  (already) — the `chat_signature?` veto and the disclosed name flow through;
  add the robot mark for `author.is_a?(SupportDesk::Assistant)` and the
  "propuesta de Rose" mark for `metadata["drafted_by"]`.
- `_actions`: Pausar/Reanudar; `_ticket_row`: the two badges; the queue tabs
  already render from `queue.tabs`.
- Agent picker: actor-key values (the gem's partial change; CarHey's ejected
  `_assignment` mirrors it).

### 16.4 Requester side

- The door: render `support_desk/tickets/_human_door` in the ejected
  `chats/conversations/show.html.erb` when `@conversation.subject.is_a?
  (SupportDesk::Ticket)` (below the header, above the transcript).
- Native: nothing — the POST redirects back into the thread; the existing
  chats rule covers it.
- Copy: CarHey's locale overrides for the three lines, in CarHey's voice
  ("Te paso con una persona del equipo…" is already the register the desk
  uses).

### 16.5 Compliance items before flipping on

- Moderate: map a reported assistant message's owner (`reported_owner`) to
  nil / the desk's owner so the flag path does not require a `User`. Verify
  with a reported Rose message in staging.
- AuditLog: `ticket_transitioned` handler already handles a non-User `by:`
  (`actor_key` in data); confirm the new kinds appear in the chain.
- Legal repo: record the disclosure choice and the art. 50 reading
  (`carhey-business/legal/…`), per the ecosystem rule.
- Privacy: `User#support_context` reviewed for PII; the prompt file reviewed
  for anything that instructs the model to reveal internal notes (the brief
  includes notes — the prompt must say they are internal).

### 16.6 Rollout and metrics

1. Deploy 0.3.0 with **no** assistant (rolling). Run `doctor`.
2. Add Rose at `:draft` everywhere. Two weeks. Watch in madmin:
   acceptance (`Draft.by(rose).verbatim / reviewed`), edit rate, rejection
   reasons, `assistant_withheld` count, time-to-first-reply on drafted cases.
3. If verbatim acceptance on `app` and `account` ≥ 80 % and no
   rejection reason cites a wrong fact: move those two topics to `:reply`.
   Two weeks. Watch containment (`resolved_by_assistant` — still zero at
   `:reply`, since she can't close), escalations by reason, `needs_human`
   volume, silent releases (must be zero).
4. `:resolve` only for `app`, only after the second soak, only with
   `max_turns 4`.
5. `payments` and `verification` never move (owner decision if ever).

---

## 17. Edge-case register

Each row is a test in §12 (name in the last column).

| # | scenario | expected | test |
|---|---|---|---|
| 1 | requester sends 3 messages in 10 s | 3 turns, 3 tokens; harness debounces; 2 jobs exit on the cheap token check | turn_test / job test |
| 2 | model answers after the requester wrote more | `respond!` ⇒ `StaleTurn`, nothing written; the newer job answers | turn_test, concurrency_test |
| 3 | human takes the case mid-generation | policy floor `:draft` ⇒ the answer becomes a draft for that human | respond_test |
| 4 | human pauses mid-generation | `withheld(:policy)`, Event with `because` "paused on this case" | respond_test |
| 5 | account closes mid-turn | `Locked` from `ensure_writable!`; job discards | respond_test |
| 6 | Rose resolves; requester writes "no funcionó" | reopened, unassigned, capped `:draft`, payload `assistant_capped` | reopen_cap_test |
| 7 | harness dead | `Queue#awaiting` shows the case; after `responds_within` the sweep releases (`assistant_silent`), `:ticket_released` pages; doctor red meanwhile | silent_release_test, doctor_test |
| 8 | draft approved after the case was closed by someone else | expired on close; `send!` ⇒ `InvalidTransition`; console never offered it | draft_test, offered_actions |
| 9 | Rose escalates a case Lucía already holds | flag + summary + priority; Lucía keeps the seat | hand_off_test |
| 10 | customer presses the door twice | second call writes nothing | hand_off_test |
| 11 | model says "close it" at `:reply` | `close!` ⇒ `AssistantNotAllowed`; brief already said `may_not: [close]` | verbs_test |
| 12 | `hand_off_when` raises | false, `Rails.error`, turn proceeds | turn_test |
| 13 | `cap` returns garbage | `ConfigurationError` in `respond!`; reported + no turn in emission | policy_test, turn_test |
| 14 | Rose deactivated | `on_duty?` false ⇒ empty `actions_for`, no turns, sweep releases her seats; rows stay | verbs_test, silent_release_test |
| 15 | reported Rose message | reaches moderate with an Assistant author; host maps owner (CarHey §16.5) | host test |
| 16 | User#1 and Assistant#1 both in the pool | picker uses actor keys; bare "1" refused as ambiguous | console_drafts_test |
| 17 | human replies while a draft is pending | ordinary reply; the draft stays pending (and turns stale on the next requester message); console keeps offering it | draft_test |
| 18 | requester asks for a person while Rose is generating | flag lands first ⇒ `respond!` sees `:observe` ⇒ withheld; or `respond!` lands first ⇒ one reply, then the flag; never a reply after the flag | concurrency_test |
| 19 | topic changed by a human from `app` to `payments` mid-case | policy recomputed per call ⇒ Rose drops to `:draft`; if she held it, `change_topic!` releases her seat with reason `released` and payload `assistant_released: true` (invariant 7) | verbs_test |
| 20 | assistant on desk A, ticket on desk B | `ticket.assistant` is B's (nil) ⇒ Null policy; `respond!(by: rose_a)` ⇒ `AssistantNotAllowed` "rose is not this desk's assistant" | policy_test |
| 21 | requester-opened case with **no** message | no token, no turn; `respond!(turn: nil)` allowed by turn rule but nothing to answer — harness never runs | turn_test |
| 22 | desk-opened (outreach) case, Rose the opener | seated `opened`, notice before her message; first turn on the requester's reply | outreach_test |
| 23 | frozen clock / UUID ids | disclosure notice pinned one tick before the bubble | respond_test |
| 24 | MySQL host | no partial index ⇒ model supersede-then-create + `RecordNotUnique` belt + doctor `drafts` check | draft_test (adapter-skipped), doctor_test |
| 25 | host without `Rails.error` | `SupportDesk.report_error` falls back to the logger | events_test |

Row 19 adds one rule not stated elsewhere: **any transition that lowers an
assistant holder's effective level below `:reply` releases her seat** inside
the same transaction (`change_topic!`, `attach_subject!` onto a capped topic,
`pause_assistant!`, `request_human!`, `escalate!`). One private helper,
`release_assistant_if_unfit!`, called at the end of each of those blocks.

---

## 18. Deferred, explicitly

- Human-authored drafts ("save as draft") — the `author` column is ready.
- Attachments on drafts.
- Saved replies as `respond!(saved_reply:)` — 0.4 with macros.
- Several assistants per desk / assistant per topic.
- Streaming or partial replies.
- A gem-side evaluation harness; `Metrics` proper.
- `by: :system` as an opener (Q17) — still deferred; assistants are the
  answer for automation that speaks.
- Requester-visible "was this helpful?" on assistant replies (CSAT, 0.4).

---

## Appendix A — full configuration example

```ruby
SupportDesk.configure do |config|
  config.requester_class = "User"
  config.agents { User.admin }
  config.name = "Soporte CarHey"

  config.assistant :rose do |rose|
    rose.name            = "Rose"
    rose.avatar          = "rose-avatar.png"
    rose.autonomy        = :draft
    rose.disclosure      = :signature_and_notice
    rose.max_turns       = 6
    rose.responds_within = 3.minutes
    rose.may_open_conversations = false
    rose.hand_off_line        = "Te paso con una persona del equipo. Normalmente contestamos en menos de %{reply_within}."
    rose.human_requested_line = :"support_desk.system.human_requested"
    rose.disclosure_line { |ticket| "#{ticket.assistant.name} es el asistente virtual de #{ticket.desk.name}. Pide una persona cuando quieras." }
    rose.hand_off_when { |_ticket, message| message.body.to_s.match?(/\b(persona|humano|agente)\b/i) }
    rose.cap { |ticket| :observe if ticket.requester.try(:banned?) }
  end
  config.assistant = :rose                       # the default desk's (implicit when it is the only one)

  config.desk :billing do |desk|
    desk.name = "Facturación"
    desk.assistant = :rose                       # the same persona may serve several desks
  end

  config.topics do
    topic :ride,     about: Ride,                assistant: :draft
    topic :payments, about: Payouts::Withdrawal, assistant: :draft
    topic :verification,                         assistant: :observe
    topic :app,                                  assistant: :reply
    other
  end

  config.on(:assistant_turn)   { |ticket, assistant, _m, turn:| Support::AssistantTurnJob.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn) }
  config.on(:draft_proposed)   { |ticket, draft| … }
  config.on(:ticket_escalated) { |ticket, from:, reason:, by:| … }
  config.on(:human_requested)  { |ticket, by:, reason:| … }
end
```

## Appendix B — sequences

```
B1  requester message → autonomous reply (:reply, unassigned, first turn)
  requester ─message!─▶ chats ─:message_created─▶ Ticket#register! (lock)
     record_registration!: last_requester_message_id=m1, awaiting=agent, hand_off_when? no
     announce_registration: emit :requester_replied, emit :assistant_turn(turn "m1")   [after commit]
  host job (wait 20 s): assistant_turn == "m1"? yes → model → Answer(:answer, 0.9)
  ticket.respond!(text, by: rose, turn: "m1") (lock)
     ensure_current_turn! ✓ · ensure_writable! ✓ · policy :reply ("rose is configured at reply") · awaiting_reply? ✓ · turns_left 6
     speak!: disclosure notice (pinned) → apply_reply_policy!: assign!(to: rose) [taken, no announcement]
             → post_agent_message!(author: rose, metadata{assistant,turn,confidence,policy}) → record_registration! (awaiting=requester, first_agent_reply_at) → turns=1
  after commit: :ticket_assigned, :agent_replied ; Turbo refresh ; requester sees "— Rose · asistente virtual"

B2  :draft — proposal → human sends edited
  … :assistant_turn → respond! → policy :draft ("topic payments caps rose at draft") → propose_draft! → :draft_proposed → bell to humans
  Lucía opens the case: _draft card; Editar → composer(draft_id) → POST send_draft(body)
  Draft#send!(by: lucia, body:) (lock): pending ✓ · stale? no · ticket.reply!(final, by: lucia, metadata{drafted_by,draft_id,edited:true})
     apply_reply_policy!: case unassigned → assign!(to: lucia) [taken, announced "Lucía G. se ocupa…" first_only]
     draft → sent(sent_body) · Event draft_sent · :draft_sent
  requester sees "— Lucía G."; the transcript marks the turn assisted

B3  hand-off from the assistant
  respond!… model returns Answer(:hand_off, reason "low_confidence", summary "…")
  ticket.escalate!(by: rose, reason:, summary:) → flag_human_required! (lock): release rose (escalated), human_required_at, priority high, Event escalated{summary}
     → hand-off line posted → :ticket_escalated → host pages humans; queue: needs_human tab, first in next

B4  the customer asks for a person
  POST /support/tickets/:id/request_human → request_human!(by: alice) → same core, Event human_requested, line, :human_requested
  next requester message → :assistant_turn at :observe (harness may note/summarize, cannot draft)

B5  silent assistant
  rose holds T-1 awaiting since 10:00; harness down. 10:03 cron → release_silent_assistants! → release!(by: :system, reason: :assistant_silent) → :ticket_released → humans paged; unassigned pile; doctor was red from 10:03 until then
```

## Appendix C — file map

```
lib/support_desk.rb                                  + assistant/assistants/reset_assistants!/release_silent_assistants!/assistant_class?/report_error
lib/support_desk/configuration.rb                    + AssistantConfiguration, Configuration#assistant(s), DeskConfiguration#assistant, validate! rules
lib/support_desk/topic.rb · topic_tree.rb            + assistant: option, Topic#assistant_cap, Unknown → :observe
lib/support_desk/assistant_policy.rb                 NEW
lib/support_desk/outcome.rb                          NEW
lib/support_desk/transcript.rb                       NEW
lib/support_desk/brief.rb                            NEW
lib/support_desk/models/assistant.rb                 NEW
lib/support_desk/models/draft.rb                     NEW
lib/support_desk/models/ticket.rb                    + columns, scopes, readers, verbs, gates (consider extracting SupportDesk::Ticket::Assistance concern)
lib/support_desk/models/desk.rb                      + assistant/humans/agents
lib/support_desk/models/assignment.rb · event.rb     + constants, Event#summary, requester_visible
lib/support_desk/models/concerns/requester.rb        + support_context
lib/support_desk/events.rb                           + catalogue
lib/support_desk/errors.rb                           + NotAnAssistant, AssistantNotAllowed, StaleTurn
lib/support_desk/console.rb · console_routes.rb      + verbs, actions, picker resolution
lib/support_desk/queue.rb                            + needs_human
lib/support_desk/timeline.rb                         + Draft entries
lib/support_desk/context_card.rb                     + requester_pairs, assistant_label
lib/support_desk/summary.rb                          + needs_human state
lib/support_desk/doctor.rb                           + checks
lib/support_desk/test_helpers.rb                     + helpers
lib/support_desk/engine.rb                           + to_prepare reference to Assistant; route
lib/tasks/support_desk.rake                          + two tasks
lib/generators/support_desk/templates/add_assistants_to_support_desk.rb.erb   NEW
lib/generators/support_desk/{install,upgrade}_generator.rb                     + copy it
lib/generators/support_desk/assistant_generator.rb + templates/assistant/*     NEW
app/controllers/support_desk/tickets_controller.rb   + request_human
app/views/support_desk/console/tickets/_draft.html.erb                          NEW  (+ edits to _composer, _message, _actions, _assignment, _context_card, _timeline, _ticket_row)
app/views/support_desk/tickets/_human_door.html.erb                             NEW  (+ _ticket_row)
config/locales/{es,en}.yml                           + §8
config/routes.rb                                     + request_human
test/…                                               §12
README.md · CHANGELOG.md · lib/support_desk/version.rb (0.3.0) · support_desk.gemspec (chats >= 0.3.3)
```
