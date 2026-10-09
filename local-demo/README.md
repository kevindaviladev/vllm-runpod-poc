# Qwen + Ollama + LiteLLM in Docker (local demo)

A minimal, self-contained stack to **show how an LLM gateway works**: a local model
(Qwen) served by **Ollama**, behind **LiteLLM** (API keys, limits, spend, logs, UI) —
all in a single `docker compose`.

🌐 **English** · [Español](README.es.md)

> ⚠️ **vLLM does not run on macOS** (it needs CUDA). Locally we use **Ollama**. Docker
> on macOS can't access the GPU (Metal), so by default Ollama runs **on CPU** inside
> Docker (fine for a 3B model). For speed, see **Fast mode**.

---

## Architecture

```text
                        ┌──────────── containers ──────────────┐
  curl / opencode       │                                       │
  benchmark             │   Ollama  :11434   (Qwen2.5:3b)        │
      │                 │      ▲                                │
      │ direct API ─────┼──────┘                                │
      │ (no key)        │                                       │
      │                 │   LiteLLM :4000  ──► Ollama           │
      │ gateway API ────┼──────┘   │                            │
      ▼ (with virtual   │           └──► Postgres (keys/spend)  │
        key)            └───────────────────────────────────────┘
```

- **:11434** → direct API to Ollama/Qwen (no auth) — the "before".
- **:4000** → LiteLLM (auth via virtual key) — the "after".
- **:4000/ui** → LiteLLM dashboard (keys, spend, logs).

---

## Quick start (all-in-Docker)

```bash
cp .env.example .env        # review/change the secrets
docker compose up -d
docker compose ps           # 3 containers: ollama, postgres, litellm

./scripts/01-pull-model.sh  # downloads qwen2.5:3b (~2 GB)
./scripts/02-create-key.sh  # creates your demo virtual key
./scripts/03-demo.sh        # the 3 curl calls
```

### The 3 steps you record

1. **Direct to Ollama** (`:11434`, no key) → the model answers… but with no control.
2. **LiteLLM without key** (`:4000`) → `401`. This is the gateway argument.
3. **LiteLLM with your virtual key** → it answers + `usage` (tokens).

---

## The secrets (what you show on video)

Everything comes from **`.env`** and enters compose via `${VARIABLES}`:

| Variable | What it is | Demo value |
|---|---|---|
| `POSTGRES_PASSWORD` | Password for LiteLLM's DB | `litellm-demo-pg` |
| `LITELLM_MASTER_KEY` | **Master key**: manages all the others | `sk-master-demo-0001` |
| `UI_USERNAME` / `UI_PASSWORD` | UI login (`:4000/ui`) | `admin` / `admin-demo-0001` |
| `DEMO_KEY` | **Virtual key** used by curl/opencode | `sk-demo-local-0001` |
| `OLLAMA_BASE_URL` | Where the gateway points | `http://ollama:11434` |
| `OLLAMA_MODEL` | Demo model | `qwen2.5:3b` |

> `.env` is git-ignored. Do not commit it.

---

## Test the API by hand

```bash
# 1) Direct to Ollama
curl -s http://localhost:11434/api/chat \
  -d '{"model":"qwen2.5:3b","messages":[{"role":"user","content":"hi"}],"stream":false}'

# 2) LiteLLM (OpenAI-compatible) with your virtual key
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-demo-local-0001" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"hi"}]}'
```

Open the **UI**: http://localhost:4000/ui → you'll see the key, the spend and every request.

---

## Use it as a local provider in opencode

Copy `opencode.json.example` to `~/.config/opencode/opencode.json` (it points to
LiteLLM, so usage is keyed and traceable):

```bash
cp opencode.json.example ~/.config/opencode/opencode.json
```

`baseURL` is `http://localhost:4000/v1` with `apiKey: sk-demo-local-0001`, model
`local/qwen-local`.


---

## Fast mode (native Ollama on macOS, uses the GPU)

1. **Comment out (or remove) the `ollama` service** in `docker-compose.yml` (so it
   doesn't clash on port 11434 with native Ollama).
2. In `.env`, change:
   ```
   OLLAMA_BASE_URL=http://host.docker.internal:11434
   ```
3. Start native Ollama and pull the model:
   ```bash
   ollama serve &
   ollama pull qwen2.5:7b        # or any model (bigger = better quality)
   ```
   In `litellm/config.yaml`, if you want the 7B, switch `ollama/qwen2.5:3b` to
   `ollama/qwen2.5:7b` (or use the `qwen-local-7b` alias).
4. `docker compose up -d --scale ollama=0` (or just bring up postgres + litellm).

> **Note:** don't run native Ollama and the Docker one listening on `11434` at the same time.

---

## Stop / clean

```bash
docker compose down            # stop (data persists in volumes)
docker compose down -v         # also wipes the DB and downloaded models
```

---

## Video notes

- Show the **`.env`**: that's the secret hierarchy (master key → virtual keys).
- The key moment is the **2 vs 3 contrast** (401 without key → 200 with key).
- In the **UI**, show: the created key, tokens per request and spend.
- Closing line: "tomorrow I swap Ollama for vLLM in `config.yaml` and **nothing on the client changes**".

---

_Author: Kevin Dávila Benavides_
