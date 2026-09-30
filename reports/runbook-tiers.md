# Runbook de ejecución — De tu Mac al PoC (Tiers 1 → 2 → 3)

> El plan de acción concreto: dónde entrar, qué alquilar, qué comandos correr,
> qué validar y cuánto cuesta. Si un checklist no pasa, NO se paga el siguiente tier.

---

## TIER 1 — La tarde de validación ($5-15)

### Qué necesitas

- Una cuenta en un proveedor de GPU en la nube:
  - **RunPod** (https://runpod.io) — recomendado primero: interfaz simple, pricing claro
  - Alternativas: **Vast.ai** (más barato, más ruidoso), **Lambda** (https://lambda.ai)
- ~$20 de crédito inicial
- Tu `benchmark_openai.py` y `load_test.py` (ya están en `benchmark/`)

### Paso a paso

```text
1. Crear cuenta en runpod.io → Billing → agregar $20 (tarjeta)
2. Pods → Deploy:
   - GPU: 1× L40S (48 GB)          [~$0.70-0.90/h en Secure Cloud; Community más barato]
   - Container disk: 20 GB
   - Volume: 60 GB (persistente — aquí viven los pesos, se reusan entre sesiones)
   - Template: PyTorch 2.x / CUDA 12.x (el que ofrezca por defecto)
3. Conectar al pod: botón "Connect" → Web Terminal o SSH
```

### Dentro del pod (terminal)

```bash
# 1. Herramientas base (2 min)
pip install vllm requests

# 2. Descargar el modelo al volumen persistente (una sola vez, ~10-15 min)
export HF_HOME=/workspace/hf
huggingface-cli download Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8

# 3. Levantar vLLM (el servidor EXACTO del plan)
vllm serve Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.92 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --port 8000
# Espera 3-5 min a que cargue. Verás "Uvicorn running on http://0.0.0.0:8000"
```

### Probar desde tu Mac

RunPod expone el puerto con "Connect → HTTP Service [8000]" — te da una URL pública.
Guárdala como $URL.

```bash
# Humo (debe responder un JSON):
curl $URL/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8","messages":[{"role":"user","content":"Hola"}]}'

# Tu benchmark (el MISMO de la Mac, cambió solo el destino):
cd ~/Documents/ai/inference-poc/benchmark && source .venv/bin/activate
python benchmark_openai.py --base-url $URL/v1 --model Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --prompt "$(cat prompt_largo.txt)" --out results_tier1.csv
# corre 2 veces: la 2ª es la válida (prefix cache)

# EL TEST QUE VALIDA EL PLAN (30 concurrentes):
python load_test.py --base-url $URL/v1 --model Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --concurrency 30 --context-tokens 16000 --out loadtest_30.csv
```

### Checklist de compuerta (TODO debe pasar para pasar al Tier 2)

```text
[ ] TTFT 2ª corrida (cache hit) < 500 ms
[ ] load_test con 30 concurrentes: TTFT p90 < 1500 ms
[ ] tok/s por usuario >= 40 (mirar el "min" del resultado)
[ ] 0 fallos en 30 concurrentes
[ ] Contexto 32K sin OOM:  load_test.py --context-tokens 32000
[ ] /metrics responde:     curl $URL/metrics | head -20
```

Si algo falla → anota QUÉ falló y vuelve al plan (sección de riesgos). NO pases al Tier 2.

### Al terminar

```text
Pods → Stop (no Destroy: el volumen con los pesos se reusa la próxima vez)
Costo esperado: $3-6 de GPU + $0.5/mes del volumen
```

---

## TIER 2 — Piloto con ingenieros reales (1 semana, $250-400)

### Qué alquilar

```text
1 Pod: 2× L40S (tensor parallel 2)     → el nodo de serving     [~$1.50/h → ~$250/semana]
1 Pod chico CPU (2 GB RAM)             → LiteLLM (gateway)      [~$0.05/h → ~$10/semana]
Opcional: 1 Pod chico CPU              → Prometheus + Grafana   [~$10/semana]
```

### Paso a paso

```text
1. Nodo de serving: igual que Tier 1 pero con 2× L40S y:
   vllm serve Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
     --tensor-parallel-size 2 \
     --max-model-len 65536 --gpu-memory-utilization 0.92 \
     --kv-cache-dtype fp8 --enable-prefix-caching

2. Gateway (en el pod chico):
   pip install litellm[proxy]
   # config.yaml: define el modelo apuntando al nodo + una key por piloto
   litellm --config config.yaml --port 4000
   # features a activar: virtual keys, max_budget por key, drop_params

3. Cada piloto: opencode configurado con
   baseURL = URL-del-gateway/v1  ·  apiKey = su key personal

4. Diariamente: cada piloto reporta por tarea: rating 1-5 + "hubiera preferido Claude: sí/no"
```

### Checklist de compuerta

```text
[ ] ≥ 3 pilotos lo usaron ≥ 3 días reales
[ ] Rating promedio >= 4/5 en tareas de su día a día
[ ] Cero quejas bloqueantes de latencia (TTFT percibido OK)
[ ] El gateway registró uso por persona (costo visible)
[ ] 0 caídas no explicadas del nodo
```

---

## TIER 3 — PoC con los 30 (2 semanas, $1,100-1,700)

```text
2 Pods de 2× L40S (idénticos)  → capacidad para 30 concurrentes con N+1
LiteLLM con los 30 keys        → load balancing entre los 2 nodos + fallback a Claude
Prometheus + Grafana           → dashboard: TTFT p50/p90, tok/s, cola, VRAM, KV en uso
Los criterios de éxito del plan (sección 11) definidos ANTES de arrancar
```

Al terminar: apagar TODO, consolidar números reales vs estimados, y escribir el
informe para el equipo con la tabla de costos.

---

## Reglas de dinero (aplicar SIEMPRE)

```text
1. Sube → prueba → BAJA. Nunca dejes pods corriendo sin testear.
2. Volumen persistente para los pesos (~$0.10/GB/mes): descargas el modelo UNA vez.
3. Interruptible/Community solo en Tier 1. Tier 2-3: pricing firme (que no te bote).
4. Versiones fijadas: vllm==X.Y.Z exacta en todos los nodos del mismo tier.
5. Cada tier se paga solo si el anterior pasó su checklist.
6. Presupuesto total de aprendizaje hasta el informe: ~$2,000. Escalona las decisiones.
```
