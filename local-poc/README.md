# local-poc — El PoC completo corriendo en tu Mac

Mini-versión de la arquitectura de producción: **gateway con llaves y dashboards**
delante de un modelo servido localmente. Costo: $0.

```text
opencode / benchmark / curl
        │  (API key)
        ▼
LiteLLM  ──►  Ollama (nativo en tu Mac, usa la GPU)
   │
   ├── Postgres     (keys, presupuestos, registros de uso)
   ├── Prometheus   (métricas → :9090)
   └── Grafana      (dashboards → :3001)
```

Ollama NO va en Docker: en Mac corre nativo para poder usar la GPU
(Docker en Mac no accede a la GPU). Todo lo demás sí va en contenedores.

---

## Requisitos

- Docker Desktop instalado y corriendo
- Ollama instalado, con los modelos descargados (`ollama list` debe mostrar `qwen3-coder:30b`)

## Arranque (una sola vez)

```bash
cd local-poc

# 1. Crea tu .env con secretos propios (no uses los de ejemplo)
cp .env.example .env
# edita .env y CAMBIA las claves

# 2. Levanta todo
docker compose up -d

# 3. Verifica que los 4 contenedores estén healthy/up
docker compose ps
```

## Ollama accesible por red (para la otra laptop)

```bash
pkill ollama
OLLAMA_HOST=0.0.0.0 ollama serve &

# tu IP en la red:
ipconfig getifaddr en0        # ej: 192.168.31.66
```

LiteLLM (dentro de Docker) llega a Ollama vía `host.docker.internal:11434` —
ya está configurado así, no hay que tocar nada.

## Los 4 servicios

| Servicio | URL | Para qué |
|---|---|---|
| **LiteLLM UI** | http://localhost:4000/ui | Crear API keys, presupuestos, ver gasto por key (login con `UI_USERNAME`/`UI_PASSWORD` del .env) |
| **LiteLLM API** | http://localhost:4000/v1 | El endpoint que consumen opencode/benchmark — SIEMPRE con key |
| **Grafana** | http://localhost:3001 (admin / GRAFANA_PASSWORD) | Dashboards de métricas |
| **Prometheus** | http://localhost:9090 | Datos crudos de métricas |

## Flujo de uso

```bash
# 1. Entra a la UI (http://localhost:4000/ui) y crea una Virtual Key
#    (ej: "benchmark-key", presupuesto ilimitado o el que quieras)

# 2. Prueba el gateway con TU key:
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-TU-VIRTUAL-KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Hola"}]}'

# 3. Tu benchmark contra el GATEWAY (no contra Ollama directo):
python benchmark/benchmark_openai.py --base-url http://localhost:4000/v1 \
  --model qwen3-coder-30b --prompt "..." --out results_gateway.csv
# (pasa --api-key cuando el script lo soporte; por ahora exporta
#  OPENAI_API_KEY=sk-tu-key y ajusta el script en 1 línea si hace falta)

# 4. Desde la OTRA laptop (misma red): lo mismo, cambiando localhost por tu IP
#    → la repetición del experimento del WiFi, ahora CON llaves y control
```

## Detener / reiniciar

```bash
docker compose down      # detiene TODO (los datos persisten en volúmenes)
docker compose up -d     # vuelve a levantar
docker compose logs -f litellm   # si algo falla, aquí se ve
```

## Qué demostrar con esto

- **Seguridad**: sin key no hay acceso (prueba el curl SIN Authorization → 401)
- **Visibilidad**: cada request aparece en la UI con su usuario, tokens y costo
- **Portabilidad**: mañana LiteLLM apunta a vLLM en vez de Ollama y NADA más cambia
- **El producto**: "yo te doy keys, presupuestos y dashboards sobre tus modelos" —
  la capa que Anthropic no te da sobre tu propio consumo
