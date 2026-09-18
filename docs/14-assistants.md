# 14 — Assistants: design record

*2026-09-18; revised during adversarial review of d9ff5c5. The normative contract
is [15-assistants-prd.md](15-assistants-prd.md). The original design remains in
git history, not as a second set of conflicting algorithms. The review and
its required tests are [15-assistants-review.md](15-assistants-review.md).*

## 1. What exists and what does not

support_desk 0.2.0 has polymorphic agents, authorship, assignments, transactional
ticket transitions, a console and post-commit notifications. It has a
support_agent_kind flag, but no enforced AI policy, drafts, review, durable
work/claims or human-intervention lifecycle. The foundation is reusable; the
flag alone does not make autonomous operation reliable.

The old 04 Bot/Responder sketch is superseded. No responder class, model
provider, prompt, retrieval engine or workflow runtime belongs in this gem.
The host supplies those. SupportDesk supplies reliable support operations.

## 2. Preserved owner choices

[12](12-open-questions.md) #19–22 still apply:

1. Ship a SupportDesk::Assistant identity using the Desk pattern, without a
   responder_class. Allow a host AI identity to bind to the same contract;
   never treat a custom kind: :ai actor as a human by default.
2. A published approved draft is authored by the accountable human who sends
   it. Preserve original author, edits, approval and publishing separately.
3. Reopening an AI-closed ticket leaves it unassigned and capped at draft.
   Explicit authorized hand-back can lift that cap, not unrelated restrictions.
4. Disclosure has no default. The host explicitly chooses one of four modes;
   none is valid and silent. Presentation is independent from stored authorship.

CarHey has not chosen its actual disclosure mode in this document. An example
using signature_and_notice is not an owner decision or deployment approval.

## 3. The responsibility boundary

| Gem owns | Host owns |
|---|---|
| Agent identity and authorship | Persona/product choices, authenticated actor |
| Per-operation permission enforcement | Tenant, role and business policy |
| Draft revisions, reviews and publication | Generating content and supporting sources |
| Human requirements, pause, hand-back | Classification and specialist selection |
| Conditional writes, claims, receipts | Scheduling, provider calls, retries and tools |
| Structured authorized support context | Product fact selection, redaction, retrieval |
| Support evidence and queue surfaces | Model traces, costs, evaluations, notifications |

A review of a reply is not permission to execute a refund. An external action
may link its host review record to the case; its execution and validation stay
in that domain. The gem never executes arbitrary approved tool arguments.

## 4. Separate facts that a single AI mode cannot express

- Assignment: who is responsible for the case.
- Autonomy/permissions: what this actor can do right now.
- Draft review: whether a human approved this exact proposed content.
- Human requirement: what intervention is still outstanding.
- Work claim: which worker may commit this particular attempt.

A human-owned money case can still receive a private draft. A customer asking
for a person blocks autonomous publishing, while a separate policy can permit
private assistance. Resolving one human requirement does not clear a different
policy requirement. Pausing/restarting generation cannot lift a money cap.

## 5. Levels are presets, not the whole authorization model

| Level | Maximum output |
|---|---|
| off | No automated action |
| observe | Authorized context, internal notes, request intervention |
| draft | Propose replies for review |
| reply | Conditional autonomous replies |
| resolve | Conditional autonomous replies and closure |

Triage is a separate opt-in capability. The original observe level silently
allowed topic and subject changes, which could let an assistant move a money
case into a permissive category. Parent/leaf topic caps now combine by minimum;
pre-existing case restrictions survive automated reclassification. Host hard
rules derive from actual domain facts as well as category labels.

Permissions are checked inside model operations and supported Chats writes.
The console's actions_for remains an offer/refusal projection, composed with
host HTTP policy. Job calls also need host authorization; an offered button
list alone is not a universal authorization service.

## 6. Reliable work without owning the agent runtime

The original last_requester_message_id token missed takeover, pause/resume,
context edits and policy changes, and was optional. The revised token binds a
monotonic ticket revision, actor, activation and policy/context version.
Assistant mutations require it, a live work claim and an idempotency key.

Input creates durable work in the same transaction. The host receives a signal
or polls, claims work, reads a bounded snapshot, calls any provider outside
locks and conditionally commits a result. A failed enqueue cannot erase the
work. An expired/replaced worker cannot publish. Replaying a completed
operation returns its result rather than posting twice or replacing a draft.

This requires more than the original two Chats seams. A generic transactional
subject-write wrapper must serialize support-message creation/edits/deletion
with automated publication. The existing after-commit callback is too late to
establish that ordering. This dependency must be prototyped and race-tested
before advertising the guarantee. A plain application process with unrestricted
SQL is outside the library's security sandbox.

## 7. Review is a durable domain operation

Drafts have immutable revisions and attachment sets. Reviews name a revision
and the current context the human saw. Approve-and-send is atomic; separate
approval and publication are supported with rechecks. Later edits/input revoke
approval. Human-sent content remains authored by that human (#20).

There is no blanket even_if_stale switch. The reviewer explicitly reviews the
current context, and publication refuses if that context changes again. One
current proposal per case is the initial product limit; past proposals/reviews
stay as evidence. A failed new proposal cannot destroy the old one.

## 8. Human intervention is independent and durable

HumanRequirement carries requesting actor, reason, internal summary, permitted
assistance, resolution actor/reason and optional host reference. Multiple
requirements can coexist. Button, deterministic phrase rule, model escalation,
policy and timeout all land on this primitive.

The requester door remains available for historically assisted cases when the
assistant is paused, inactive or removed. Failure of a phrase classifier must
not permit autonomous continuation as if it returned false. Keep the message,
record failure and surface a human task. Acknowledgement copy does not pretend
a human is online or promise a response time that is not configured.

Pause, reopen cap and requirements are stored separately. A human explicitly
chooses what to resolve on hand-back. Validation runs against the proposed
resulting policy before committing any relaxation. AI cannot resolve its own
requirements or impersonate a human reviewer.

## 9. Identity and disclosure

Desk is the sender; agent is the author. Nameless replies suppress visible
personal signatures, not provenance. Each publication snapshots presentation
so removing/renaming an assistant does not change or break history. Notice
receipts are per identity/disclosure version, not a single lifetime boolean.

Modes: signature_and_notice, signature, notice, none. All requester surfaces
honor the choice, including rows and assignment announcements. Staff always
see real provenance. Approved drafts display the publishing human, with the
machine contribution retained internally. The gem documents behavior; host
legal conclusions and disclosure obligations are not asserted by this record.

## 10. Context and privacy

Use an authorized immutable context snapshot with stable IDs, structured
roles, bounded transcript/cursors, policy, restrictions and optional host
facts. Internal notes and past drafts are excluded by default and require an
explicit authorized opt-in. Human support_context is not automatically sent
to a provider. A host context callback deliberately chooses what to include.

System lifecycle messages are not provider system instructions. Input can
contain imperative text without becoming instructions. A grep for “You are”
is not a security test. Sources need safe URL/rendering rules; confidence is
model-reported metadata, not permission or accuracy evidence.

## 11. Liveness and honest evidence

Track work age before assignment, including draft-only mode. Lost enqueue,
crash, endless retries and stale leases cannot hide unassigned work. A sweep
rechecks the exact work/seat/deadline under locks; it never releases a human
who took over after the scan. Timeout imposes a requirement and fences the old
worker, rather than merely releasing a seat it can immediately retake.

External notification/audit callbacks remain post-commit, isolated and best
effort. Work receipts/events are durable; hosts needing guaranteed delivery
consume them with their own cursor/outbox contract. Acceptance rate is not
factual accuracy; an AI closure count is not containment without a cohort and
observation window. Human wait is measured separately from AI acknowledgements.

## 12. Rollout and delivery

Additive schema expansion is possible while disabled. Activation requires all
old web/job/cable/import writers drained, catch-up of stale non-null pointers,
verified schema and a shared persisted activation epoch. Automation active
alongside 0.2 writers is unsupported. Older code lacks identity/control
semantics; a bare pin back to 0.2 is not a safe rollback after AI activity.

Delivery: Chats transaction/presentation seam first; reliable kernel; review
and controls; surfaces/context/DX; complete integrated matrix and installed
package inspection; then host rollout. Version/PR numbers and estimates are
provisional. The PRD enumerates implementation gates; this design review does
not claim those runtime tests have already passed.

## 13. Changes from the original intuitions

The original intuitions about identity, a provider-neutral harness, draft
review, human escalation and model-level enforcement were right. The main
corrections are stronger operation semantics, not adding an AI engine:

- Turn => input/control revision plus fenced claim and replay receipt.
- One human flag => independent durable requirements and restrictions.
- Mutable proposal => immutable revisions and context-bound reviews.
- Post-commit signal => durable work plus optional signal/poller.
- Current author display => immutable publication presentation/provenance.
- Assistant-specific class test => AI-kind binding or explicit refusal.
- Same queries without AI => honest opt-in behavior contract.

Human-authored saved drafts, multiple autonomous responders per desk, streaming,
routing algorithms, CSAT and evaluations remain explicit deferrals. Attachments,
freshness, review, replay, reliable work and the customer exit are part of the
foundation, not optional later guardrails.
