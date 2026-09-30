# Self-Hosted AI Models for Engineering — Test Results

**To:** engineering stakeholders
**From:** Kevin Dávila
**Date:** September 26, 2026
**Status:** technical test complete, quality not yet measured

---

## One-page summary

Over two days we ran an open-source coding model on a rented GPU. In front of it we
put a gateway that gives each person their own access key and logs all usage. Two
engineers used it with opencode, on Mac and Windows, for real work.

**What worked:**

- One GPU at **$796/month** serves about **10 people working at the same time**,
  with smooth responses and zero errors across every test.
- **87% of real traffic was context re-reads.** That is exactly what Anthropic
  bills for over and over; on our own GPU it costs nothing. The core idea behind
  this project holds up with our own data.
- The gateway gives us something we don't have with Claude today: **visibility into
  who uses what, how much, and with what result**, plus the ability to grant or
  revoke access in seconds.

**What we don't know yet:** whether the model's quality is good enough for daily
work. It's the most important question, and this test doesn't answer it.

**What it would cost:** for our 30 engineers the savings would be modest, between
**8% and 37%** depending on how we contract the GPUs. Savings grow with the team:
at 100 engineers they reach **41–62%**.

**Recommendation:** don't decide on a migration yet. Approve a **two-week pilot with
5 to 8 volunteer engineers (~$1,000)** to measure quality on real work, with success
criteria agreed before we start.

---

## 1. What we built

Three pieces, all open source:

```text
   Engineers (opencode on Mac, Windows, Linux)
                    │
                    │  each with a personal key
                    ▼
   ┌─────────────────────────────────────┐
   │  GATEWAY (LiteLLM)                  │  ← controls access, logs everything,
   │  keys · limits · usage logs         │    and can route tasks to Claude
   └─────────────────┬───────────────────┘
                     ▼
   ┌─────────────────────────────────────┐
   │  MODEL (vLLM + Qwen3-Coder 30B)     │  ← runs on a GPU we rent
   │  1× NVIDIA L40S, 48 GB              │
   └─────────────────────────────────────┘
```

- **The model:** Qwen3-Coder 30B, from Alibaba. It's trained for coding and for
  using tools (reading files, editing, running commands), which is what an agent
  like opencode does. Apache 2.0 license: free commercial use, no royalties.
- **The server (vLLM):** the industry standard for serving open models. It handles
  many people at once and reuses context it has already processed.
- **The gateway (LiteLLM):** the front door. Engineers never talk to the GPU
  directly.
- **Where:** a GPU rented by the hour on RunPod. Nothing purchased.

**Total cost of the test: under $15 in GPU time.**

---

## 2. What we measured

Every number here comes from real tests, not estimates.

### Capacity and speed

| What | Result | What it means in practice |
|---|---|---|
| Speed with 1 person | **135 tokens/s** | Faster than anyone can read |
| Speed with 10 people at once (**shared prefix**) | **58–73 tokens/s each** | Only when they share context; distinct sessions drop to ~16 tok/s (see results) |
| Working memory | **220,000 tokens** | About 9 real sessions open at once |
| Errors | **0** across all tests | Even when asked for more memory than exists, it doesn't fail — it queues |
| Tool use | **Works** | opencode reads, edits and runs commands without issues |

### The key finding: reusing context multiplies capacity

We sent the same load twice: 10 people at once. First with different contexts,
then with shared context.

| | Total time | Time to first word |
|---|---:|---:|
| New context every time | 16.1 s | 9.7 s |
| Context already processed | **5.2 s** | **3.8 s** |

**3× faster** just by reusing what was already in memory. In a normal work session
each turn resends almost everything before it, so this is where the system spends
most of its time.

### How a real engineer works

We measured 14 turns of a teammate working with opencode:

- **Every session starts at 12,000 tokens** before doing anything (the tool's
  internal instructions).
- **It grows about 2,400 tokens per turn.** In 14 turns it reached 43,500.
- **For every token the model writes, it reads 157.** This workload is about reading
  context, not generating text.
- **87% of what was sent had already been sent before.** Anthropic charges for that
  every time. On our GPU it's memory being reused.

### Latency: almost all of it is the network

| Segment | Time |
|---|---:|
| The model responds | 56 ms |
| The gateway adds | 15 ms |
| The public internet path to the rented GPU | ~1,000 ms |

**94% of the wait is the internet path**, not the system. In production the GPU
would sit on a private network or in our own cloud, and that second would drop to a
few tens of milliseconds. The gateway, with everything it provides, costs 15 ms.

---

## 3. What the gateway gives us

This is the part worth having even if the savings were zero.

**One key per person.** Created or revoked in seconds from a web panel. If someone
leaves the team, access is cut with one click.

**Per-person limits.** Tokens per minute, requests per minute, which models they can
use, until what date. They protect the whole team from a runaway session.

**Full visibility.** Every request is logged: who, when, which model, how many
tokens, how long it took. In this test we already had 76 requests logged, each with
its owner. Today we have nothing like this for how we use Claude.

**One address for everything.** Any tool compatible with the OpenAI API connects the
same way: opencode, scripts, IDE extensions.

**No lock-in.** Switching models or GPU providers is a one-line change in the
gateway config. Engineers don't notice.

**Our model and Claude in one place.** The gateway can send routine work to our
model and hard work to Claude, and fail over to Claude automatically if our server
goes down. It's available but **we haven't tested it yet**.

**Privacy, with an important caveat.** With our own model, no AI vendor sees our
code or uses it for training. But in this test the GPU was on RunPod, a third party.
To say "our code never leaves the house," the GPU has to live on infrastructure we
control: our own cloud account or our own hardware.

---

## 4. What it would cost

### Assumptions

- **GPU:** $1.09/hour per L40S, the price we paid in the test ($796/month if always
  on). With a reserved contract, roughly 30% less.
- **People working at the same time at peak:** 30% to 40% of the team (assumption,
  not measured). A session spends much of its time waiting on the human.
- **Operations:** a quarter of one engineer's time, ~$800–1,000/month. Mostly fixed;
  it doesn't grow much with the team.
- **Claude for hard tasks:** 10% to 20% of work would still go to Claude.
- **Redundancy:** from 30 engineers up, always one spare server, so a failure never
  leaves anyone without service.

### By team size (monthly cost)

| Engineers | Today (Claude, $200/seat) | Self-hosted, hourly | Savings | Self-hosted, reserved | Savings |
|---:|---:|---:|---:|---:|---:|
| 10 | $2,000 | $1,900 – 2,300 | none | $1,650 – 2,050 | 0 – 17% |
| **30** | **$6,000** | **$4,700 – 5,500** | **8 – 21%** | **$3,800 – 4,600** | **24 – 37%** |
| 60 | $12,000 | $7,000 – 8,400 | 30 – 41% | $5,600 – 7,000 | 42 – 53% |
| 100 | $20,000 | $9,600 – 11,900 | 41 – 52% | $7,700 – 10,000 | 50 – 62% |

### Breakdown for our 30 engineers

| Item | Hourly | Reserved |
|---|---:|---:|
| 4 GPUs (2 servers of 2 GPUs, one as backup) | $3,184 | ~$2,230 |
| Gateway, monitoring and storage | $150 | $150 |
| Operations | $800 – 1,000 | $800 – 1,000 |
| Claude for hard tasks | $600 – 1,200 | $600 – 1,200 |
| **Total** | **$4,700 – 5,500** | **$3,800 – 4,600** |

### What matters in this table

**Cost stops being per person and becomes per capacity.** Today every new engineer
adds $200 a month, forever. With this we pay per server, and one server serves many
people: the cost per engineer **goes down** every time the team grows.

- At 30 engineers: ~$155–185 per person.
- At 100 engineers: ~$96–119 per person.

**At 30 engineers the financial case is modest.** We shouldn't promise big savings at
this size. What is already clear is section 3: control, visibility, and not depending
on a single vendor.

---

## 5. What we still don't know

This section matters as much as the ones before it.

**Quality.** We didn't measure it. This model doesn't match Anthropic's best on the
hardest tasks, and the design already assumes that (which is why Claude stays for
hard work). What we don't know is **what share of daily work** it handles well.
Almost the entire business case depends on that.

> Feedback from the teammate who tried it: _[PENDING — 1–5 rating and whether they
> would have preferred Claude]_

**Long sessions.** We tested minutes and hours, not multi-day sessions. When a
session fills its memory, the tool summarizes it and the context-reuse advantage is
lost. That will happen several times a day per engineer, and we haven't measured it
yet.

**30 people at once.** We tested 10 on one GPU. The numbers for 30 are calculated
with a formula we validated in this test (it predicted 78 tokens/s, we measured 73),
but we didn't test them on a 2-GPU server.

**How many work at the same time.** The 30–40% peak assumption changes the GPU count
significantly. The pilot will measure it.

**Running it isn't free.** Setting it up took two work sessions, and we hit seven
problems specific to the rented environment (disks, ports, processes that stayed
alive). All of them are fixed and automated in a startup script, but they confirm
the "operations" line in the costs is real.

---

## 6. What we propose

**A two-week pilot**, before any migration decision.

| | |
|---|---|
| **Who** | 5 to 8 volunteer engineers |
| **With what** | 1 server with 2 GPUs, the same gateway, opencode |
| **Cost** | ~$1,000 (hourly GPU + Claude for hard tasks) |
| **What we measure** | quality per task, satisfaction, how many work at once, long sessions |

**Success criteria, agreed before we start:**

- At least **75% of tasks** solved without the engineer missing Claude.
- Speed of **40 tokens/s or more** per person at peak.
- Time to first word **under 1.5 s** for 9 out of 10 requests, measured from a
  private network.
- **No unexplained outages.**

**If it passes**, we propose a rollout for all 30 engineers on a reserved contract.
**If it doesn't**, the result is still valuable: we avoid spending ~$50,000 a year on
something worse, and we keep the gateway, which is just as useful for organizing and
measuring our Claude usage.

**What we need to start:**

1. Approval of the pilot budget (~$1,000).
2. 5 to 8 volunteers willing to rate their tasks for two weeks.
3. A decision on where this would live in production (our cloud, or a provider with
   private networking).

---

## Minimal glossary

| Term | What it is |
|---|---|
| **Token** | A piece of a word, about 3–4 characters. The unit AI is measured and billed in. |
| **Context** | Everything the model "has in view" in a conversation: instructions, files it read, history. |
| **Tokens/s** | How fast the model writes. A person reads about 5–10 per second. |
| **GPU** | The processor the model runs on. Rented by the hour. |
| **Gateway** | The single front door: controls who gets in, logs usage, and routes the work. |
| **Context re-read** | When each turn of a conversation resends everything before it. Anthropic charges every time; on our own GPU it's reused for free. |

---

_Technical detail, scripts and raw data: `inference-poc/` (technical plan in
`reports/plan-self-hosted-30-ingenieros.md`, measurements in `benchmark/resultados/`,
startup scripts in `runpod/`)._
