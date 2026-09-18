# 14 — Assistants: AI agents as first-class citizens of the desk

*Design record, 2026-09-18. Implementation contract: [15-assistants-prd.md](15-assistants-prd.md). Follows 04 (agents), 09 (events), 10 (compliance),
12 Q10/Q17, 13 (writing first). Supersedes the "Bots (0.3)" sketch in 04.*

## 0. Where we actually are

**Is the gem ready for AI agents today? No.** `acts_as_support_agent kind: :ai`
exists and nothing reads it beyond `support_agent_kind`. There is no draft, no
autonomy policy, no hand-off verb (`escalate!` is a word in two constant lists),
no turn signal, no context bundle, and `config.routing` procs are accepted but
never invoked. A host that wired an LLM to `ticket.reply!(by: bot)` tomorrow
would ship a bot with the authority of a senior human and no way for a customer
to reach a person.

**Is the foundation right? Yes**, and that is why this is a layer, not a
rewrite:

| already true | why it matters for an assistant |
|---|---|
| D3: the **desk** sends, the agent **authors** (`author:` + `signed?`) | an AI persona is just another author; the requester keeps one counterpart |
| assignment is a **history** with reasons, `hand_off!`, `release!` | "the assistant holds the case" and "a human took over" are rows, not flags |
| `opened_by` / `closed_by` are polymorphic records | an assistant can open (outreach) and close (resolve) with full provenance |
| `actions_for(agent)` is the console's **authorization boundary** | bounded AI authority plugs into the one place that already decides "may this agent press this" |
| events after commit, isolated, `ticket_transitioned` umbrella | the harness subscribes; the audit log sees every AI action for free |
| `register!` owns `awaiting` and is idempotent | AI replies move the same clocks; a redelivered job double-counts nothing |
| notes are events (`note!`) | AI reasoning and hand-off summaries need no new table |
| the 0.2 `by:` seam + Q17 ("automation openers deferred") | a **persisted** assistant record is exactly what Q17 asked for instead of `:system` |

## 1. The one principle: the gem owns the guardrails, the host owns the brain

Everything an LLM does that can *hurt* — speak to a customer, close a case,
hold a case nobody else sees, keep going forever — is a deterministic rule that
belongs in the gem, enforced **on the model**, tested state by state, and
recorded as evidence. Everything an LLM does that is *clever* — read the case,
search the docs, decide what to say, decide it is unsure — belongs to the host,
with whatever provider and harness it likes.

So the gem ships **no LLM dependency, no prompt, no retrieval, no job loop**.
It ships five things a harness cannot build safely on its own:

1. **Identity** — who the assistant is and how it discloses itself.
2. **Permission** — what it may do on *this* case right now, and why.
3. **The turn** — when it should act, and a token that makes a late answer
   harmless.
4. **Review** — drafts a human approves, edits or rejects, with the outcome
   kept as a training signal.
5. **Context** — the case as facts a model can read, in one call.

Plus the two exits every customer must have: *the assistant hands off* and
*the customer asks for a person*.

## 2. The API we wish we had

```ruby
# config/initializers/support_desk.rb
SupportDesk.configure do |config|
  config.assistant :rose do |rose|
    rose.name            = "Rose"
    rose.avatar          = "rose.png"
    rose.autonomy        = :draft            # :off | :observe | :draft | :reply | :resolve  (default :draft)
    rose.disclosure      = :signature_and_notice  # REQUIRED, no default: :signature_and_notice | :signature | :notice | :none
    rose.max_turns       = 6                 # replies per case before Rose must hand off
    rose.responds_within = 3.minutes         # silence past this gives the case back to humans
    rose.hand_off_when { |ticket, message| message.body.match?(/\b(persona|humano|agente)\b/i) }
    rose.cap { |ticket| :draft if ticket.requester.try(:vip?) }   # a ceiling per case; nil = no opinion
  end

  config.topics do
    topic :ride,         about: Ride
    topic :payments,     about: Payouts::Withdrawal, assistant: :draft    # money: a human sends every word
    topic :verification,                             assistant: :observe  # identity: Rose only triages
    topic :app,                                      assistant: :resolve  # how-to: answer and close
    other
  end

  # The harness is yours. The gem tells you when it is Rose's turn.
  config.on(:assistant_turn) do |ticket, assistant, message, turn:|
    Support::AssistantTurnJob.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn)
  end
end
```

```ruby
# app/jobs/support/assistant_turn_job.rb — the host's harness, any provider
class Support::AssistantTurnJob < ApplicationJob
  def perform(ticket_id, assistant_key, turn)
    ticket = SupportDesk::Ticket.find(ticket_id)
    return unless ticket.assistant_turn == turn          # the requester wrote again; a newer job has it

    rose   = SupportDesk.assistant(assistant_key)
    answer = Support::Rose.answer(ticket.brief, ticket.transcript)   # your prompt, your tools, your model

    case answer.kind
    when :answer   then ticket.respond!(answer.text, by: rose, turn: turn,
                                        confidence: answer.confidence, sources: answer.sources)
    when :hand_off then ticket.escalate!(by: rose, reason: answer.reason, summary: answer.summary)
    end
  rescue SupportDesk::StaleTurn, SupportDesk::Locked
    # somebody spoke since, or there is nobody to write to any more — the newer turn (if any) answers
  end
end
```

```ruby
# what respond! does with the answer is the POLICY's decision, not the job's
outcome = ticket.respond!("Tu retirada está en revisión…", by: rose, turn: turn)
outcome.sent?      # Rose held the case (or took it), it was her turn, level ≥ :reply → a Chats::Message
outcome.drafted?   # level :draft, a human holds it, human required, or max_turns → a Draft for a person
outcome.withheld?  # level :off/:observe, or not her turn → nothing written, reason recorded

# the console, a human
draft = ticket.pending_draft
draft.send!(by: lucia)                                  # approve verbatim
draft.send!(by: lucia, body: "Hola Alice, …")           # edit and send
draft.reject!(by: lucia, reason: "wrong withdrawal")    # the outcome is kept: it is a training signal
ticket.pause_assistant!(by: lucia)  ticket.resume_assistant!(by: lucia)
ticket.hand_off!(to: rose, by: lucia)                   # give it back to Rose (only where policy lets her hold it)

# the requester
ticket.request_human!(by: alice)                        # the button; also what hand_off_when triggers

# reading
ticket.assistant_policy.level        # => :draft
ticket.assistant_policy.because      # => "topic payments caps rose at draft"
ticket.human_required?  ticket.held_by_assistant?  ticket.assistant_paused?
ticket.transcript.to_text  ticket.brief.to_h
```

Nothing in this file changes behaviour for a host that configures no
assistant. That is a hard requirement: 0.1/0.2 semantics byte for byte.

## 3. Identity: `SupportDesk::Assistant`

A persona is a **record** (polymorphic columns need an id) whose behaviour is
**configuration** — exactly the Desk pattern: `support_desk_assistants(key,
settings, active)`, lazily created, memoised as `SupportDesk.assistant(:rose)`,
config wins and `settings` is the runtime fallback.

```ruby
class SupportDesk::Assistant < ApplicationRecord
  acts_as_support_agent kind: :ai       # an agent like any other: assignable, an author, an opener, a closer
  def config          = SupportDesk.config.assistant(key)
  def name            = config.name
  def disclosed?      = config.disclosure != :none
  def disclosed_name  = disclosed? ? I18n.t("support_desk.assistant.disclosed_name", name: name) : name  # "Rose · asistente virtual"
  def display_name    = disclosed_name     # what chats prints under a signed bubble
  def to_s            = disclosed_name     # hosts whose display-name lambda falls back to to_s (CarHey does)
  def support_agent_name = disclosed_name  # "Rose · asistente virtual se ocupa de tu consulta"
  def on_duty?        = active?
end
```

Why `Assistant` and not the 04 sketch's `Bot`: "asistente virtual" is the
phrase the customer reads; `Bot` says scripted, and the 04 sketch also gave the
record a `responder_class`, which put the loop in the gem — the one thing §1
says the gem must not own.

**Disclosure lives in the identity**, not in the harness, and **the host
chooses it explicitly** (owner decision 22, 2026-09-18): declaring an assistant
without `disclosure=` is a boot-time `ConfigurationError` naming the four
modes; `:none` is a legitimate explicit choice and warns nowhere. A
human-sounding name ("Rose") is fine, pretending to be human is not.
Our reading of Regulation (EU) 2024/1689 art. 50(1) is that people interacting
with an AI system must be informed unless it is obvious, and that duty applies
since 2 August 2026 — confirm with counsel in the legal repo before launch;
legal facts are not invented in code repos. Modes:

| `disclosure` | the requester sees |
|---|---|
| `:signature_and_notice` | "— Rose · asistente virtual" under each of her bubbles **and** one system line before her first message in the case |
| `:signature` | the signature only |
| `:notice` | nameless replies (the desk's own name, no signature) and the notice |
| `:none` | nothing — an explicit choice, no warning |

The notice copy is a locale key with `%{name}`, `%{desk}` and, when the
customer can ask for a person, the way to do it. Nameless (`:notice`) is how a
desk gets "the desk answered" without a persona; it is still disclosed.

`Desk#agents` includes the desk's active assistant so the console's assign
picker offers Rose as a hand-back target; `Desk#humans` is the pool without
her, and `Ticket#agents_to_notify` uses humans only (an assistant is notified
by `:assistant_turn`, never by the host's bell).

## 4. Permission: the autonomy policy

Five ordered levels, named after the most an assistant may **produce** at each:

| level | may | never |
|---|---|---|
| `:off` | nothing | — |
| `:observe` | `note!`, `change_topic!`, `attach_subject!`, `escalate!` | write to the requester |
| `:draft` | + `draft!` — propose a reply a human sends | send |
| `:reply` | + `reply!` / take the case / speak on her turn | close |
| `:resolve` | + `close!` | — |

The **effective level** for a ticket is the minimum of every ceiling, then
clamped by floors:

```
ceilings:  assistant.autonomy  ∧  topic.assistant (inherited, like priority)  ∧  cap { |ticket| }  ∧  ticket override (pause = :off)
floors:    human_required?   → at most :observe      (the customer asked for a person)
           human holds it    → at most :draft        (humans outrank assistants: she may propose, not speak)
           closed?           → at most :observe      (a requester reply reopens first; she never speaks into a closed case)
```

`ticket.assistant_policy` returns a frozen `AssistantPolicy` (`level`,
`may?(:reply)`, `may_draft?`, `may_close?`, `because`, `to_h`). `because` names
the rule that decided ("topic payments caps rose at draft", "lucia holds the
case", "requester asked for a person") — it goes into the event payload, the
console badge and the brief, so nobody ever has to re-run the policy to learn
why the assistant did what it did (the forensics rule: persist the decision).

Enforcement is **in the transitions**, not in sugar: `reply!`, `close!`,
`assign!(to: assistant)`, `note!`, `change_topic!` consult the policy whenever
`by:` (or `to:`) is an assistant and raise `SupportDesk::AssistantNotAllowed <
NotAllowed` with `because` in the message. `actions_for(rose)` returns exactly
the verbs the level allows, so the boundary the console already trusts is the
same one the harness hits. `ensure_assignable!(rose)` refuses to seat her on a
case she may not answer (`< :reply`): holding a case means owing the next word.

Two policy rules are about *humans*, and they need no configuration:

- **Humans outrank assistants.** A human replying on a case an assistant holds
  takes it over (`drop_in_takeover`) under every `reply_policy`, `:assignee_only`
  included — that policy governs humans versus humans.
- **A human hands back explicitly.** `hand_off!(to: rose, by: lucia)` clears the
  pause and the human-required flag; nothing else does.

## 5. The turn

The assistant acts on **one signal**: `:assistant_turn` `(ticket, assistant,
message, turn:)`, emitted after commit when a requester message registers (or
the requester opened the case) **and** the effective level is at least
`:observe`. Every other filter — held by a human (drafts), paused, closed —
is already folded into the level, so the harness never re-implements policy
to decide whether to run. It fires per requester message; bursts are the
job's business (`set(wait:)` + the check below).

`ticket.assistant_turn` is a token: the id of the last registered requester
message (new column `last_requester_message_id`; the existing
`last_registered_message_id` is role-blind). The harness passes it back;
`respond!` / `reply!` / `draft!` with `turn:` raise `SupportDesk::StaleTurn <
InvalidTransition` when the requester has written since. A 40-second model
call that lands after the customer added "ah, y otra cosa" is a stale turn, not
a wrong answer sent — and the job for the newer turn is already queued.

Two more turn rules, deterministic and cheap:

- **She speaks only on the desk's turn.** A speaking verb by an assistant when
  `awaiting_requester?` is withheld (one reply per requester message, never an
  unsolicited follow-up). Outreach she opens is the one exception, and it is
  behind `may_open_conversations = false`.
- **A silent assistant never hides a case.** Cases she holds are excluded from
  humans' `mine` and `unassigned`, so `responds_within` (default 3 minutes)
  bounds that: `rake support_desk:release_silent_assistants` (the host schedules
  it) releases her seat with `release_reason: assistant_silent` and emits
  `:ticket_released`, `doctor` fails on any case past the bound, and
  `Queue#awaiting` shows them to humans regardless. Harness down is loud, not
  quiet.

## 6. Speaking: `respond!`, `draft!`, `reply!`

`ticket.respond!(body, by:, turn:, confidence: nil, sources: [], metadata: {})`
does *the most the policy allows* and returns an `Outcome` (`sent?`,
`drafted?`, `withheld?`, `message`, `draft`, `policy`). Under the row lock:

1. stale check → `StaleTurn`; `ensure_writable!` → `Locked` (closed account).
2. level `:off`/`:observe`, or not her turn → **withheld**; event
   `assistant_withheld` with `because`.
3. level `:draft`, or a human holds the case, or `human_required?`, or
   `assistant_turns_count >= max_turns` → **draft** (supersedes the pending
   one); at `max_turns` also `escalate!(reason: :max_turns)` so the draft
   arrives with a human already paged.
4. otherwise → **sent**: `reply_under_lock!` with `author: rose` (the existing
   reply policy seats her — `assign!(to: rose, by: rose)` — and
   `announce_assignments` says "Rose · asistente virtual se ocupa de tu
   consulta", which *is* the disclosure moment); the disclosure notice is
   posted first when the mode includes it and none has been posted on this
   case; `assistant_turns_count += 1`; `confidence`, `sources`, `turn` and
   the policy go into the message's `metadata` and the `agent_replied` payload.

`draft!` always drafts (level ≥ `:draft`); `reply!(by: rose)` sends or raises
`AssistantNotAllowed` — for harnesses that want the explicit shape. Both take
`turn:`.

**Authorship.** An autonomous reply is authored by the assistant (signed,
disclosed, exported as `from: "assistant"`). An **approved draft is authored by
the human who sent it** — they read it, they own it, the requester sees their
signature — with `metadata: { drafted_by: "rose", draft_id:, edited: true/false }`
on the message so the transcript, metrics and the brief still know. That is the
Intercom/Zendesk "suggested reply" model and the one counsel will like: a
human reviewed and sent it.

`SupportDesk::Assistant` never bypasses `reply!`: the same
`post_agent_message!` path, the same `register!`, the same events (Q17's whole
warning, honoured by making the actor a record).

## 7. Review: `SupportDesk::Draft`

```
support_desk_drafts
  ticket_id, author (polymorphic: an Assistant today, a human's saved draft tomorrow),
  in_reply_to_id (the requester message it answers — the turn token),
  body, confidence (decimal, nil ok), sources (json: [{title, url}]), metadata (json: provider/model/tokens/prompt version — opaque),
  status: pending | sent | rejected | superseded | expired,
  reviewed_by (polymorphic), reviewed_at, sent_message_id, sent_body (when edited), rejection_reason,
  timestamps
  partial unique index (ticket_id) WHERE status = 'pending'   ← at most ONE pending proposal per case
```

- `draft.stale?` — the requester wrote after `in_reply_to`. Sending a stale
  draft needs `send!(by:, even_if_stale: true)`; the console shows "El cliente
  ha escrito desde entonces" and asks twice.
- `draft.send!(by: human, body: nil)` → `ticket.reply!` as that human, marks
  `sent`, keeps `sent_body` when edited, event `draft_sent` `{edited:,
  assistant:}`. Because a human replied, the assistant's seat is released.
- `draft.reject!(by:, reason: nil)` → `rejected`, event `draft_rejected`.
- A new `draft!` supersedes the pending one; `close!` expires it; a pending
  draft on a closed case can never be sent (`InvalidTransition`).
- `ticket.pending_draft`, `ticket.drafts`, `Draft.pending/.sent/.verbatim/
  .edited/.rejected` — the acceptance rate of a persona is one query.

The draft's `sources` render in the console as the reviewer's evidence
("answered from FAQ › Retiradas"). Where they come from is the host's business.

## 8. The two exits

**The assistant hands off** — `ticket.escalate!(by: rose, reason:, summary:
nil)`. One transition, event `escalated` `{reason, summary, from}`: release her
seat (`release_reason: escalated`), stamp `human_required_at` /
`human_required_reason`, raise `priority` to at least `high`, keep any pending
draft (her best attempt is now the human's starting point), post the hand-off
line (`assistant.hand_off_line`, a String/Symbol/block like `opening_line`,
default "Te paso con una persona del equipo. Normalmente contestamos en menos
de %{reply_within}"), emit `:ticket_escalated (ticket, from:, reason:, by:)`.
Idempotent on a case already flagged. `summary` is the hand-off note humans
read first; it lives in the event payload, so the timeline shows it where it
happened.

**The customer asks for a person** — `ticket.request_human!(by: alice)`: the
same core with reason `:requester_request`, event `human_requested`, actor the
requester. The engine grows `POST /support/tickets/:id/request_human` and a
partial (`support_desk/tickets/_human_door`) the host renders in the thread
when `ticket.assistant_in_play?` and not yet `human_required?`. `hand_off_when`
runs inside `record_registration!` for requester messages (before any
`:assistant_turn` is emitted, so the model never runs) and calls the same verb
with reason `:phrase`; a block that raises counts as false and is reported
through `Rails.error`, like a subscriber.

While `human_required?`: the level floors at `:observe`, the case sits in a new
`needs_human` queue tab (and first in `next`, via the priority bump), the row
carries a badge. A human taking or replying does not clear the flag — history
— but makes it moot; `hand_off!(to: rose)` clears it.

**Reopen after an assistant closed it.** The requester writing into a case
Rose resolved is Rose having been wrong. Recommendation: the reopen leaves it
**unassigned and caps Rose at `:draft` for this case** (a ticket override), so
a person decides. The alternative — let her retake it, bounded by `max_turns`
(the counter survives reopen) — is a one-line change if the owner prefers it.

## 9. Pause and resume

`ticket.pause_assistant!(by: lucia, reason: nil)` writes the override
`assistant_autonomy = "off"`, event `assistant_paused`; `resume_assistant!`
clears it. `assistant_paused?` reads the column. Paused is total: no notes, no
drafts, no turn events — "off" means off.

## 10. Context: `transcript` and `brief`

Two read-only objects, provider-neutral, no instructions in them — facts only.
The host adds the prompt.

- `ticket.transcript` → Enumerable of `Turn(role:, name:, body:, at:,
  attachments:, message:)`, roles `:requester | :human | :assistant | :system`
  (a human-sent draft is `:human` with `assisted: true`). `to_a`, `to_h`,
  `to_text` ("[10:02] Alice: …"), `last(n)`, `since(message)`.
- `ticket.brief` → `Brief` with `to_h` / `to_text`: desk; assistant (name,
  disclosure, `policy.to_h` with the plain-words list of what she may and may
  not do on this case — tell the model, don't let it guess); reference, topic
  path + full label; subject label, status, `support_context` pairs; requester
  name, since, open cases, **`support_context`** pairs (new on the Requester
  concern, same name and meaning as the supportable's: what an agent sees about
  you — it feeds the console's context card too); state (status, awaiting,
  human required, turns used / max, reopened); internal notes and previous
  hand-off summaries; previous drafts with outcomes and rejection reasons (the
  feedback loop, in-context); the transcript.

Whatever a host puts in `support_context` is what it is sending to a model;
the README says so in bold.

## 11. Evidence, not verdicts

- New event kinds: `human_requested`, `assistant_paused`, `assistant_resumed`,
  `draft_sent`, `draft_rejected`, `assistant_withheld` (+ `escalated`, already
  in `KINDS`). Every assistant action carries `policy.to_h`, `turn`,
  `confidence` and the harness's opaque `metadata` in its payload.
- New events: `assistant_turn`, `draft_proposed`, `draft_sent`, `draft_rejected`,
  `ticket_escalated`, `human_requested`, `assistant_paused`, `assistant_resumed`,
  `assistant_withheld`. All through the same dispatcher; `ticket_transitioned`
  covers the audit mirror without the host adding a line.
- Scopes: `Ticket.held_by_assistants`, `.needs_human`, `.resolved_by_assistant`
  (closed by an Assistant and not reopened), `.assistant_paused`;
  `Draft.pending/.sent/.verbatim/.edited/.rejected`. Enough for a containment
  rate and an acceptance rate on day one; `Metrics` proper stays 0.4.
- `doctor`: an assistant is configured but nothing subscribes to
  `:assistant_turn` ("cases Rose holds will wait forever"); any case held by an assistant past `responds_within` (fail); pending drafts
  on closed cases; the display-name lambda returns blank for an Assistant.
- `Ticket#export` labels assistant-authored messages `from: "assistant"`.

## 12. Surfaces

**Console** (`actions_for` grows, `MEMBER_VERBS` grows, one table as today):
- humans: `:send_draft` / `:reject_draft` when `pending_draft`, `:pause_assistant`
  / `:resume_assistant` when the desk has an assistant and the case is open.
- assistants: exactly the level's verbs (`actions_for(rose)`), so a future
  "run Rose from the console" button and the harness share one boundary.
- `_draft` card above the composer: body, confidence pill, sources, stale
  warning; **Enviar** (verbatim), **Editar** (loads the composer with a hidden
  `draft_id`, so the ordinary reply form is the approval path), **Descartar**
  (optional reason). Assistant bubbles get a mark and the confidence on hover.
  Header: "Rose se ocupa · 2/6 turnos", **Pausar asistente**. Queue: the
  `needs_human` tab and a row badge.

**Requester engine**: the `request_human` route + door partial; the case row
says who is handling it ("Rose · asistente virtual"); the hand-off line and the
disclosure notice are ordinary system lines in the thread.

**Generator**: `rails g support_desk:assistant Rose` writes the initializer
stanza, `Support::AssistantTurnJob` and a `Support::Rose.answer(brief,
transcript)` stub returning `Answer(kind:, text:, confidence:, sources:,
reason:, summary:)` — provider-blank on purpose — plus locale entries and a
test built on the helpers below. `support_desk:upgrade` copies the additive
migration.

**TestHelpers**: `respond_as(rose, ticket, body, **)`, `assert_pending_draft
ticket, body: /…/`, `assert_needs_human ticket`, `refute_assistant_spoke ticket`,
`with_assistant_config(:rose, autonomy: :reply) { }`;
`capture_support_events(:assistant_turn)` already works.

## 13. Schema and rollout

Additive, one migration via `support_desk:upgrade`:

- `support_desk_assistants` (`key` unique, `settings` json, `active` bool).
- `support_desk_drafts` as in §7, with the one-pending partial unique index
  (MySQL: model + `doctor`, the 12 Q13 stance).
- `support_desk_tickets`: `assistant_autonomy` (string, nullable override),
  `human_required_at`, `human_required_reason`, `assistant_turns_count`
  (integer, default 0), `last_requester_message_id`.
- `Assignment::RELEASE_REASONS` += `assistant_silent`. No new assignment
  `reason` value, so — unlike 0.2 — this is **rolling-deploy safe**: old
  processes never save a row carrying a value they do not know.

Nothing fires until `config.assistant` is declared. `Desk#agents` gains the
assistant; a host that iterated `desk.agents` to page people should already be
on `agents_to_notify` (which excludes her).

Version: **support_desk 0.3.0**. Roadmap 11's "0.3.0 — agents at scale" keeps
the number; the duty table and routing strategies slide to 0.4 (routing is
still not invoked anywhere — the policy engine makes "AI first responder" work
without it: an unassigned case at `:reply` is taken by the assistant on her
turn).

## 14. What chats needs (little)

- `messager.message!(…, metadata: {})` — one kwarg, so `post_agent_message!`
  can stamp `drafted_by` / `confidence` through the single write path
  (chats 0.3.3). Fallback if we would rather not touch chats now:
  `conversation.messages.create!(sender: desk, author:, metadata:)` directly —
  support_desk already knows the models.
- Nothing else. The signature reads `display_name_for(author)`, which the
  Assistant answers with its disclosed name; `Message#metadata` exists;
  `signed?` is exactly the author-≠-seat rule we need.
- Optional later: a duck-typed `author.chat_signature` seam so a persona can
  sign differently from how it is named. Not needed for 0.3.0.

## 15. What is deliberately NOT in the gem

Model calls, prompts, retrieval / FAQ search / embeddings, language or
sentiment detection, an evaluation harness, a queue runner. The host owns all
of it; the gem gives each one a place to land: `sources` for retrieval,
`confidence` for the model's own doubt, `metadata` for provider bookkeeping,
`Draft` outcomes for evaluation, `:assistant_turn` for the runner. Saved
replies (roadmap 0.4) will be the natural bridge for "answer from the FAQ and
nothing else": `respond!(saved_reply: :withdrawal_delay, by: rose)` is safer
than free text and is one keyword away once macros exist.

## 16. Adversarial pass

| scenario | what happens |
|---|---|
| requester sends three messages in ten seconds | three turns, three tokens; jobs debounce; two are stale before they call a model (`ticket.assistant_turn == turn` first) |
| the model takes 40 s and the requester writes meanwhile | `respond!` → `StaleTurn`; nothing written; the newer turn's job answers |
| a human takes the case while Rose is generating | floor → `:draft`; her answer arrives as a draft for that human |
| a human pauses while Rose is generating | `withheld`, event with `because: "paused by lucia"` |
| the account closes mid-turn | `ensure_writable!` → `Locked`; the job rescues it |
| Rose resolves; the requester reopens | unassigned, Rose capped at `:draft` on this case (recommended, §8) |
| the harness is down | cases she holds are released after `responds_within`, `doctor` is red, `Queue#awaiting` showed them all along |
| a draft is approved after somebody closed the case | expired on close; `send!` raises |
| Rose escalates a case a human already holds | flag + summary + priority; no release (nobody's seat is taken) |
| the requester presses "hablar con una persona" twice | idempotent |
| the model says "close it" at `:reply` | `close!(by: rose)` → `AssistantNotAllowed`; the brief already told it it may not, and the harness should read `policy.may_close?` rather than try |
| `hand_off_when` raises | false, reported, the turn proceeds |
| Rose is deactivated (`active: false`) | `on_duty?` false → `actions_for` empty, no turns; her rows stay (never destroy an author) |
| a reporter flags a Rose message | chats' moderate contract sees an Assistant `author`; CarHey's Moderate flags require a `User` — verify the host mapping (Q17's second half) before launch |
| two requester-facing surfaces (web, native) | the door is an engine route; the thread partial is a slot; nothing native-specific |

## 17. Decisions

Taken by the owner on 2026-09-18 (recorded in 12 as 19–22):

1. **Name: `SupportDesk::Assistant`**, a gem-shipped record; 04's `Bot` and its `responder_class` are superseded.
3. **Approved drafts are authored by the sending human**, with `drafted_by` / `draft_id` / `edited` in the message metadata.
4. **Reopen after an assistant close** → unassigned, assistant capped at `:draft` on that case; `hand_off!(to: rose)` lifts it.
5. **Disclosure has NO default: the host must choose** one of the four modes or the assistant fails to boot; `:none` is explicit and silent.

Taken by default (the recommendation stands until the owner says otherwise):

2. **Default autonomy `:draft`** — every desk starts human-in-the-loop.
6. **`responds_within` default 3 minutes** and a scheduled release task (vs deriving "counts as unassigned" in the queue query).
7. **`may_open_conversations` default false** — proactive outreach by an assistant is a separate switch.
8. **Stale drafts need `even_if_stale: true`.**
9. **Level vocabulary** `off / observe / draft / reply / resolve`.
10. **`hand_off_when` lives in the gem** as a host block that runs before the model (recommended) vs host-only detection.

## 18. Delivery, in PR-sized units

A. **Kernel** — Assistant record + config DSL + topic option; `AssistantPolicy`;
`last_requester_message_id` + `assistant_turn` + `StaleTurn`; policy gates in
the transitions; `respond!` / `draft!`; `Draft` model; `escalate!` /
`request_human!` / `pause_assistant!` / `resume_assistant!`; humans-outrank and
hand-back rules; events + kinds; migration + upgrade generator; `doctor`
checks; the silent-release task; tests state by state (the
`console_offered_actions_test` template, extended to an assistant actor).
B. **Surfaces** — console verbs, draft card, badges, tab, pause button;
engine route + door partial; locales es/en.
C. **Context + DX** — `Transcript`, `Brief`, requester `support_context`,
generator, TestHelpers, README reference section, CHANGELOG, 0.3.0.
D. **CarHey** — Rose on the default desk at `:draft`; `payments` /
`verification` caps; `Support::AssistantTurnJob` on `Ai::Client` (Anthropic
SDK, already in the Gemfile) with a FAQ tool over `carhey-business` docs; madmin
draft card; the door in the ejected chats thread; Noticed on
`draft_proposed` / `ticket_escalated` / `human_requested`; a fortnight at
`:draft` measuring acceptance before any topic moves to `:reply`.
