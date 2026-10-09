# Qwen + Ollama + LiteLLM en Docker (demo local)

Stack mínimo y autocontenido para **mostrar cómo funciona un gateway de LLMs**: un
modelo local (Qwen) servido por **Ollama**, detrás de **LiteLLM** (API keys, límites,
gasto, logs, UI) — todo en un solo `docker compose`.

🌐 [English](README.md) · **Español**

> ⚠️ **vLLM no corre en Mac** (necesita CUDA). En local usamos **Ollama**. Docker en
> Mac no accede a la GPU (Metal), así que por defecto Ollama corre **en CPU** dentro de
> Docker (bien para un 3B). Para velocidad, ver **Modo rápido**.

---

## Arquitectura

```text
                        ┌──────────── contenedores ────────────┐
  curl / opencode       │                                       │
  benchmark             │   Ollama  :11434   (Qwen2.5:3b)        │
      │                 │      ▲                                │
      │ API directa ────┼──────┘                                │
      │ (sin key)       │                                       │
      │                 │   LiteLLM :4000  ──► Ollama           │
      │ API gateway ────┼──────┘   │                            │
      ▼ (con virtual    │           └──► Postgres (keys/gasto)  │
        key)            └───────────────────────────────────────┘
```

- **:11434** → API directa a Ollama/Qwen (sin auth) — el "antes".
- **:4000** → LiteLLM (con auth por virtual key) — el "después".
- **:4000/ui** → dashboard de LiteLLM (keys, gasto, logs).

---

## Arranque (modo todo-en-Docker)

```bash
cp .env.example .env        # revisa/cambia los secretos
docker compose up -d
docker compose ps           # 3 contenedores: ollama, postgres, litellm

./scripts/01-pull-model.sh  # descarga qwen2.5:3b (~2 GB)
./scripts/02-create-key.sh  # crea tu virtual key de demo
./scripts/03-demo.sh        # los 3 curls
```

### Los 3 pasos que grabas

1. **Directo a Ollama** (`:11434`, sin key) → el modelo responde… pero sin control.
2. **LiteLLM sin key** (`:4000`) → `401`. Aquí está el argumento del gateway.
3. **LiteLLM con tu virtual key** → responde + `usage` (tokens).

---

## Los secretos (lo que muestras en video)

Todo sale de **`.env`** y entra al compose vía `${VARIABLES}`:

| Variable | Qué es | Valor demo |
|---|---|---|
| `POSTGRES_PASSWORD` | Password de la DB de LiteLLM | `litellm-demo-pg` |
| `LITELLM_MASTER_KEY` | **Llave maestra**: administra todas las demás | `sk-master-demo-0001` |
| `UI_USERNAME` / `UI_PASSWORD` | Login de la UI (`:4000/ui`) | `admin` / `admin-demo-0001` |
| `DEMO_KEY` | **Virtual key** que usas en curl/opencode | `sk-demo-local-0001` |
| `OLLAMA_BASE_URL` | A dónde apunta el gateway | `http://ollama:11434` |
| `OLLAMA_MODEL` | Modelo del demo | `qwen2.5:3b` |

> `.env` está en `.gitignore`. No lo subas a git.

---

## Probar la API a mano

```bash
# 1) Directo a Ollama
curl -s http://localhost:11434/api/chat \
  -d '{"model":"qwen2.5:3b","messages":[{"role":"user","content":"hola"}],"stream":false}'

# 2) LiteLLM (OpenAI-compatible) con tu virtual key
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-demo-local-0001" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"hola"}]}'
```

Abre la **UI**: http://localhost:4000/ui → verás la key, el gasto y cada request.

---

## Usarlo como proveedor "local" en opencode

Copia `opencode.json.example` a `~/.config/opencode/opencode.json` (apunta a LiteLLM,
así el uso queda con key y trazable):

```bash
cp opencode.json.example ~/.config/opencode/opencode.json
```

El `baseURL` es `http://localhost:4000/v1` con `apiKey: sk-demo-local-0001`, modelo
`local/qwen-local`.

---

## Modo rápido (Ollama NATIVO en el Mac, usa la GPU)

1. **Comenta (o borra) el servicio `ollama`** en `docker-compose.yml` (para no chocar
   en el puerto 11434 con el Ollama nativo).
2. En `.env`, cambia:
   ```
   OLLAMA_BASE_URL=http://host.docker.internal:11434
   ```
3. Arranca Ollama nativo y baja el modelo:
   ```bash
   ollama serve &
   ollama pull qwen2.5:7b        # o el que quieras (más grande = mejor calidad)
   ```
   En `litellm/config.yaml`, si quieres el 7B, cambia `ollama/qwen2.5:3b` por
   `ollama/qwen2.5:7b` (o usa el alias `qwen-local-7b`).
4. `docker compose up -d --scale ollama=0` (o levanta solo postgres + litellm).

> **Ojo:** no tengas Ollama nativo y el de Docker escuchando a la vez en `11434`.

---

## Detener / limpiar

```bash
docker compose down            # detiene (los datos persisten en volúmenes)
docker compose down -v         # además borra la DB y los modelos descargados
```

---

## Notas para el video

- Muestra el **`.env`**: ahí está la jerarquía de secretos (master key → virtual keys).
- El momento clave es el **contraste 2 vs 3** (401 sin key → 200 con key).
- En la **UI** enseña: la key creada, los tokens de cada request y el gasto.
- Cierre: "mañana cambio Ollama por vLLM en el `config.yaml` y **nada del cliente cambia**".

---

_Autor: Kevin Dávila Benavides_
