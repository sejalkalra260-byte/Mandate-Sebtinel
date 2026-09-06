# Phoenix — AI Revenue Recovery (formerly Mandate Sentinel)

**Two AI agents that decide whether a failed subscription payment deserves a message at all.**

In India, recurring payments run on UPI AutoPay and e-NACH mandates, and a large share of
scheduled debits fail on the first attempt. Merchants find out from a spreadsheet the next
morning; customers find out when the service cuts off.

Everyone builds the notification. This builds the **judgement** — which of forty failures
deserves a message, which deserves silence, and when.

```
                      ┌──────────────┐
   chaos simulator ──▶│  event bus   │──▶  MERCHANT OPS COPILOT ──┐
   scheduler       ──▶│  (SQLite)    │      cluster → hypothesise │ dispatch
                      └──────────────┘      → verify ↺ → decide   │ (and the brake)
                             │              → human approval      ▼
                             └───────────▶  CUSTOMER RETENTION AGENT
                                            classify → policy → decide
                                            → compose → review → send
                                                     │ outcomes
                                                     └──────────▶ back to the merchant agent
```

---

## Run it

```bash
git clone <your repo> && cd mandate-sentinel
./run.sh
```

Then open **http://localhost:8000**.

That's it. No API key required — the agents fall back to a deterministic rule engine that
returns the same typed objects the model would, so you can build and rehearse offline.
To run on real models:

```bash
cp .env.example .env      # add ANTHROPIC_API_KEY, check the model IDs
./run.sh
```

The header badge always tells you which engine is live, so you can never demo a mock by accident.

Manual setup, if you prefer:

```bash
pip install -r requirements.txt
python -m app.seed                 # 1,200 subscriptions, 12 months of history
uvicorn app.main:app --reload
```

---

## Why this is an agent and not a cron job

Say this out loud in the demo. It is what your evaluation turns on.

A cron job maps `event → template`. An agent holds a **bounded action space**, gathers
evidence with tools until it can choose from it, and its choice changes based on memory of
what happened last time.

| | Cron job | Mandate Sentinel |
|---|---|---|
| 40 failures on one bank | 40 emails | 1 merchant alert, **0 customer messages** |
| "Insufficient funds" | Retry in 48h | Retry on the 2nd, because that is when this customer's money arrives |
| "Mandate revoked" | Retry in 48h (guaranteed to fail) | Never retry; send a fresh mandate link |
| Customer replies | Ignored | Parsed, re-mandated, pending retries cancelled |

**The line to use on stage:** *"The interesting output of our system isn't the message it
sends. It's the thirty-seven it decided not to send."*

---

## The two agents

### Agent 1 — Merchant Ops Copilot  (`app/agents/merchant_agent.py`)

Looks at the whole book, not one customer.

```
gather → cluster → hypothesise → verify ──(disproved, <2 rounds)──▶ hypothesise
                                    │
                                    ▼
                                 decide → approval_gate → execute
```

Its distinguishing behaviour is that **it does not trust its own first explanation.** It
forms a hypothesis, runs tools to try to disprove it, and re-hypothesises if the evidence
disagrees. Two hypotheses tested and rejected is a real result, and it reports that honestly
rather than asserting a cause the data does not support.

Action space: `DIGEST · ALERT_OUTAGE · SUPPRESS_ALL · PROPOSE_CAMPAIGN · NO_ACTION`

It also answers questions in plain language over the same tools ("how much revenue is at
risk and what should I do first?").

### Agent 2 — Customer Retention Agent  (`app/agents/customer_agent.py`)

One run per at-risk subscription, running concurrently.

```
enrich → classify → policy_check → decide → compose → review → dispatch
                         │            │                  │
                      blocked      silent          blocked before sending
```

Action space: `WAIT · NUDGE · NUDGE_URGENT · SEND_REMANDATE · OFFER_PAUSE ·
OFFER_DOWNGRADE · ESCALATE · SUPPRESS`

Only `classify`, `decide`, `compose` and `review` touch a model. Everything else is ordinary
code — which is exactly how it should be.

It is also **two-way**: `handle_reply()` interprets an inbound message ("I closed that HDFC
account"), issues a new mandate link, cancels the now-pointless scheduled retries, and
writes what it learned to that customer's memory.

### How they talk

| Direction | What crosses |
|---|---|
| Merchant → Customer | "Stop, bank outage, message nobody" (the brake) · "Approved: run a win-back for these 12" |
| Customer → Merchant | "8 contacted, 5 recovered, ₹2,495 back" · "3 people said the same thing about pricing" |

---

## The failure taxonomy

`app/taxonomy.py` is the spine of the project. Everything interesting is a consequence of it.

| Cause | Retry? | Customer agent | Merchant agent |
|---|---|---|---|
| `INSUFFICIENT_FUNDS` | Timed to their payday | Soft nudge, retry scheduled to their money rhythm | Recoverable, no churn flag |
| `MANDATE_REVOKED` | **Never** | Re-mandate link + one question: why? | Churn signal, top of queue |
| `MANDATE_EXPIRING` | N/A | Proactive renewal at T-7 | Forecast of expiring revenue |
| `CARD_EXPIRED` | No | Card-update link | Cards dying in 30 days |
| `ISSUER_DOWN` | Fast, silent | **Stay silent** | Outage banner, suppress the cluster |
| `LIMIT_EXCEEDED` | After the cap is fixed | Explain the cap, offer a cheaper plan | "Your pricing trips UPI caps" |
| `RISK_DECLINE` | Once | Suggest another method | Route to human ops |

---

## Guardrails

Not a slide — code, in `app/policy.py`, running outside the model's reach.

- **Bounded action space** — the agent picks from an enum. It cannot move money, cancel a
  subscription, or issue a refund. Ever.
- **Human gate** — campaigns over ₹2,000 or 5 customers stop at the approval gate and wait
  for a click. LangGraph's own interrupt pattern.
- **Contact rate limit** — max 2 messages per customer per 7 days, hard-coded, not prompted.
- **Quiet hours** — a *deferral*, not a refusal: a 2am failure still deserves a message, it
  just deserves it at 9am.
- **Draft review** — a second model plus regex checks for invented amounts, links outside the
  allow-list, and pressure tactics. The regex always wins over the model's opinion.
- **Outage circuit breaker** — the merchant agent can suppress all customer contact globally.
- **Full audit trail** — `agent_runs` + `agent_steps` record every tool call, input, output
  and reason. Every message traces back to the decision that produced it.

---

## The chaos simulator

Your data source, your demo remote control, and your test rig — all seeded, so the demo
behaves identically every rehearsal. Buttons on the left of the dashboard:

| Button | What it proves |
|---|---|
| Fail 6 payments | Six identical-looking events, six different decisions |
| Fail 3 payday customers | The agent reads history and chooses `WAIT` |
| Revoke a high-value mandate | Single, personal, high-stakes handling |
| **Trigger HDFC outage — 40 failures** | The showpiece: 40 messages *not* sent |
| False alarm | The agent disproves its own hypothesis, live |
| Churn wave | Campaign proposal → approval gate → 7 agents dispatched |
| Advance clock 7 days | Releases scheduled messages, surfaces expiring mandates |
| Reply as the customer | The two-way loop |

---

## Eval harness

```bash
python -m evals.run_evals
python -m evals.run_evals --json     # for CI or a slide
```

25 labelled scenarios; it reuses the *same prompt builders the running agent uses*, so what
you measure is what actually ships. Current offline-engine numbers:

```
classification_accuracy    0.92
action_accuracy            1.00
end_to_end_accuracy        0.96
false_send_rate            0.00      <- zero messages during a suppressed incident
policy_violation_rate      0.00
median_latency_ms          1002
```

The harness prints the cases it gets **wrong** and why. Put those on a slide too — judges
trust a team that knows its own error modes far more than a team claiming 100%.

---

## Four-minute demo script

| Time | Beat |
|---|---|
| 0:00 | One sourced stat on first-attempt mandate failure. Who is left in the dark. |
| 0:25 | The healthy book: 1,200 subscriptions, ₹9.8L monthly. |
| 0:40 | **Fail 6 payments.** Open two traces side by side: one nudges, one chooses `WAIT` and schedules for the 2nd — and the panel says why. |
| 1:40 | Open the customer inbox. Real messages, real re-mandate links. |
| 2:05 | **Trigger HDFC outage.** Merchant agent clusters → hypothesises → verifies against 24h → opens the breaker. Watch four customer agents hit it and refuse to send. Say: *forty messages not sent.* |
| 2:45 | **Clear outage.** 40 payments recover silently. Nobody was ever contacted. |
| 3:00 | **Churn wave** → campaign proposal → click **Approve** → 7 agents launch. Human-in-the-loop, on screen. |
| 3:25 | Reply "I changed my bank" → re-mandate, retries cancelled, memory written. |
| 3:45 | Eval numbers. Close on what you'd ship next. |

Rehearse the exact button order three times against a stopwatch, and **record a screen
capture the night before** in case the venue wifi dies.

---

## Layout

```
app/
  config.py          all tunables in one place
  taxonomy.py        failure codes + retry policy + action spaces   ← the spine
  models.py          SQLModel schema
  db.py              engine, simulated clock, flag store
  bus.py             event bus + SSE trace stream
  llm.py             Anthropic structured output + offline rule engine
  policy.py          guardrails (deliberately not AI)
  schemas.py         every LLM output is one of these
  seed.py            1,200 subscriptions with behavioural patterns planted on purpose
  simulator.py       the chaos scenarios
  main.py            FastAPI routes + SSE
  agents/
    tools.py             what the agents can actually do
    customer_agent.py    AGENT 2
    merchant_agent.py    AGENT 1
  web/index.html     the console (single file, no build step)
evals/
  scenarios.json     25 labelled cases
  run_evals.py       the scorer
```

## Deliberately not built

Real money movement · auth and multi-tenancy · a trained churn model · a mobile app ·
a vector store (memory is structured JSON per customer). Say these out loud as scoped-out
decisions — it reads as judgement, not gaps.
