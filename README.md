# AI Inference PoC — servir un modelo propio en GPU alquilada

**English TL;DR:** A measured PoC to evaluate self-hosting an open model for a team instead of paying per seat. Stack: `opencode → LiteLLM (gateway) → vLLM` serving **Qwen3-Coder-30B-A3B-Instruct-FP8** (MoE, ~3B active) on **1× NVIDIA L40S (48 GB)** rented at **$1.09/h**. Total cost of the test: **<$15**. Headline findings: the bottleneck was **network, not the GPU**; **prefix caching made it 3.1× faster**; **48 KB/token** of KV cache explains why one GPU can't hold 30 sessions of 16K. All numbers below come from the CSVs in `benchmark/resultados/`.

> PoC técnico para decidir si conviene servir un modelo open-source en infraestructura alquilada en vez de pagar por asiento — **con datos medidos, no opiniones**. Dos ingenieros lo usaron para trabajo real. **Sanitizado**: sin claves, sin hostnames ni IDs de pod reales.

---

## 1. Setup

| Pieza | Detalle |
|---|---|
| Modelo | `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` — MoE **30B totales, ~3B activos**, FP8, ~31 GB de pesos, Apache-2.0 |
| Hardware | **1× NVIDIA L40S (48 GB)**, RunPod, **$1.09/h** |
| Servidor | **vLLM**, nativo (`uv pip install vllm`), sin Docker |
| Gateway | **LiteLLM** con Postgres (keys virtuales, UI, logs) + Prometheus/Grafana |
| Cliente | **opencode** con `limit.context = 65536`, `limit.output = 8192` |
| Observabilidad | Prometheus + Grafana (dashboard vLLM ID 23991) |

Flags de arranque de vLLM:

```bash
vllm serve ./models/qwen3-coder-30b \
  --served-model-name qwen3-coder-30b \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.92 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --host 0.0.0.0 --port 8000
```

## 2. Resultados (L40S, a través del gateway)

| Escenario | Éxitos | Pared | TTFT p50 | TTFT p90 | tok/s p50 | Agregado |
|---|---:|---:|---:|---:|---:|---:|
| 1 usuario, 16K | 1/1 | 3,3 s | 2.541 ms | 2.541 ms | 120,3 | 120 tok/s |
| 5 usuarios, 16K | 5/5 | 9,1 s | 5.435 ms | 7.541 ms | 27,3 | 166 tok/s |
| 10 usuarios, 16K (**sesiones distintas**) | 10/10 | 16,1 s | 9.652 ms | 14.206 ms | **15,9** | 199 tok/s |
| 5 usuarios, 32K | 5/5 | 18,7 s | 10.541 ms | 16.609 ms | 13,7 | 110 tok/s |
| 10 usuarios, 32K | 10/10 | 36,3 s | 20.861 ms | 34.434 ms | 7,6 | 147 tok/s |
| **10 usuarios, 16K (prefijo compartido)** | 10/10 | **5,2 s** | **3.773 ms** | 3.783 ms | **73,6** | **740 tok/s** |

Detalle por petición en `benchmark/resultados/l40s-gateway-20260925-1351/`.

**Local (MacBook M4 Max, Ollama), para contraste:**

| Modelo | TTFT | tok/s (decode) | prefill tok/s |
|---|---:|---:|---:|
| `qwen3-coder:30b` | 4.007 ms (frío) / 34,9 ms (caliente) | 91–93 | — |
| `qwen2.5:7b` | ~2.745–3.184 ms | 72–79 | 861–929 |
| `qwen2.5:0.5b` | ~1.006–1.171 ms | 308–326 | 5.655–11.766 |

## 3. Hallazgos principales

1. **El cuello de botella no fue la GPU: fue la red del proxy.** Con 1 usuario, el TTFT fue **2.541 ms** — absurdo para una L40S. El proxy HTTP de RunPod buffereaba SSE. El informe desglosa: **~1.000 ms de red pública**, 56 ms de modelo, 15 ms de gateway → **~94% de la espera era internet**. Los TTFT de la tabla **no** son comparables con un SLO de latencia; hay que medirlos por túnel SSH.
2. **Prefix caching es el argumento económico central**: mismo escenario de 10 usuarios, **16,1 s → 5,2 s** y **9.652 ms → 3.773 ms** de TTFT (throughput 199 → 740 tok/s) cuando el prefijo ya está en caché. En un workload agéntico que reenvía el contexto en cada turno, esto domina.
3. **El hardware se dimensiona por memoria, no por cómputo.** KV cache en FP8 = 2×48 capas×4 heads×128 dim×1 byte = **48 KB/token**. 1×L40S ≈ 8 GB de KV ≈ **~175K tokens**; 30 sesiones×16K = **480K** → no cabe.
4. **Bug metodológico del propio benchmark**: `load_test.py` mandaba el mismo prompt a todos, así que con prefix caching los 30 compartían KV y medía la memoria de **uno**. Se corrigió con marcador único por sesión (`--session-mode unique`) — y ese es el escenario "sesiones distintas" de la tabla.
5. **Tool calling necesita flags explícitos**: sin `--enable-auto-tool-choice --tool-call-parser qwen3_coder`, el modelo devuelve la llamada como texto y el agente no funciona.

## 4. Costos

| Concepto | Valor |
|---|---|
| GPU L40S alquilada | **$1.09/h** (2× ≈ $1.7/h) |
| Costo total de la prueba | **<$15** |
| Siempre encendida (1 GPU) | ~**$796/mes** + almacenamiento del volumen |
| Alternativa por asiento (suscripción a precio de lista) | ~$200/asiento → 30 ingenieros ≈ **$6.000/mes** |

Proyección para un equipo (estimación del informe, **no medida**):

| Ingenieros | Propio (reservado) | Ahorro vs suscripciones | Costo por ingeniero |
|---:|---:|---:|---:|
| 10 | $1.650–2.050 | 0–17% | — |
| 30 | $3.800–4.600 | **24–37%** | ~$155–185 |
| 60 | $5.600–7.000 | 42–53% | — |
| 100 | $7.700–10.000 | **50–62%** | ~$96–119 |

Cálculo: el cronómetro corre mientras el pod está encendido; el self-hosted **solo gana con uso sostenido** (la GPU ociosa se paga igual).

## 5. Troubleshooting: 7 bugs del entorno alquilado

| Síntoma | Causa | Fix |
|---|---|---|
| `Operation not permitted` al instalar/chmod | El volumen de red no soporta chmod | Binarios y venv en el disco del contenedor, nunca en el volumen |
| `config.json is not a valid JSON` / pesos en 0 bytes | El volumen no conserva symlinks de la caché de Hugging Face | Descargar con `--local-dir` (carpeta plana) |
| vLLM muere al arrancar sin motivo | `VLLM::EngineCore` huérfano retiene la VRAM | `pkill -9 -f VLLM::EngineCore` y confirmar 0 MiB antes de relanzar |
| `address already in use` | Jupyter o un LiteLLM viejo en el puerto | Matar el proceso del puerto |
| `/key/generate` → `Not Found` | LiteLLM sin capa de base de datos | `litellm[proxy,extra_proxy]` + `prisma generate` con el venv en el PATH |
| `prisma-client-py: not found` | Prisma generado con ruta absoluta | `export PATH=<venv>/bin:$PATH` |
| UI morada vacía / redirect a IP interna | Placeholder de assets y proxy sin confianza | Ajustar `/litellm-asset-prefix` y `FORWARDED_ALLOW_IPS='*'` |

`vllm --version` y la versión de CUDA quedaron en la lista de "pendientes de anotar" (ver §6).

## 6. Lo que NO está medido (honestidad metodológica)

- **Versión exacta de vLLM y de CUDA** (no se anotaron).
- **Tamaño real del KV cache** (la línea `GPU KV cache size` del arranque no está en un log).
- **VRAM pico** durante carga y bajo concurrencia.
- **20 y 30 usuarios concurrentes**: solo se probaron 1/5/10.
- **Calidad del modelo**: el dataset (`datasets/evaluation.jsonl`) tiene 5 tareas y **no hay resultados**.
- Los percentiles se calculan con índice discreto (`int(n·p/100)`): con 5–10 muestras son orden de magnitud, no percentiles formales.
- Las cifras de negocio del informe (**87% de relectura de contexto**, **157 tokens leídos por cada uno escrito**, **~220K tokens** de memoria) provienen de logs del gateway/sesiones **no versionados**: se presentan como observación del PoC, no como benchmark reproducible.

## 7. Estructura y reproducción

```
benchmark/   benchmark.py (Ollama), benchmark_openai.py (API OpenAI-compatible),
             load_test.py (concurrencia), resultados/ (CSV del barrido real)
datasets/    evaluation.jsonl (dataset de evaluación, pendiente de correr)
notes/       apuntes: fundamentos, optimización, cadena completa, dataset
reports/     plan, runbook de tiers, informe de resultados, troubleshooting
runpod/      start-poc.sh / stop-poc.sh (arranque y parada del pod)
local-poc/   docker-compose (LiteLLM+Postgres+Prometheus+Grafana) para probar en local
```

```bash
# Benchmark contra cualquier API OpenAI-compatible (vLLM, LiteLLM, Ollama)
python benchmark/benchmark_openai.py --base-url https://<POD_ID>-8888.proxy.runpod.net/v1 \
  --model qwen3-coder-30b --prompt-file benchmark/prompt_largo.txt --out results.csv

# Concurrencia (sesiones distintas para que el prefix caching no falsee la medición)
python benchmark/load_test.py --base-url $URL/v1 --model qwen3-coder-30b \
  --concurrency 10 --context 16k --session-mode unique
```

---

**Licencia**: usa el contenido y los scripts libremente; el modelo es Apache-2.0.
