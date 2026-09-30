# Tier 1 — Instrucciones de ejecución en RunPod

> Versión corregida y ejecutable del Tier 1 del `runbook-tiers.md`.
> Objetivo: convertir en mediciones las estimaciones de las secciones 5.1–5.3 del plan.
> Tiempo: una tarde (3–4 h). Costo: **~$6–8**.

---

## 0. Dos correcciones al runbook original (léelas antes de gastar)

### Corrección 1 — 1× L40S NO puede correr el test de 30 concurrentes

El runbook decía "Tier 1 = 1× L40S". La matemática del propio plan lo desmiente:

```text
KV cache por token (FP8): 2 (K y V) × 48 capas × 4 KV heads × 128 dim × 1 byte = 48 KB
  ← confirmado contra el config real del modelo en Hugging Face

1× L40S (48 GB × 0.92 = 44 GB):
  pesos FP8 ~32 GB + activaciones ~4 GB  →  KV disponible ~8 GB  →  ~175K tokens
  30 sesiones × 16K = 480K tokens        →  NO CABE (2.7× por encima)

2× L40S, TP=2 (96 GB × 0.92 = 88 GB):
  pesos ~32 GB (16+16) + overhead ~8 GB  →  KV disponible ~48 GB  →  ~1.0M tokens
  30 sesiones × 16K = 480K tokens        →  CABE con 2× de margen  ✓
  30 sesiones × 32K = 960K tokens        →  CABE justo             ✓
```

Con 1 GPU el test no fallaría por OOM (vLLM encola y hace preemption), fallaría por
TTFT p90 — y no sabrías si es culpa del plan o de haber alquilado media máquina.

**Decisión: Tier 1 se corre en 2× L40S**, que es exactamente el "nodo" de la sección 6.2
del plan. Diferencia de costo: ~$3 más por la tarde. Es el gasto más barato del proyecto.

### Corrección 2 — tu `load_test.py` medía el caso imposible

Mandaba **el mismo prompt** en las N peticiones concurrentes. Con `--enable-prefix-caching`
las 30 comparten los mismos bloques de KV: 30 usuarios consumían la memoria de **uno**.
El test habría dado números excelentes y habría validado nada.

Ya lo arreglé: `--session-mode unique` (nuevo default) mete un marcador único al inicio
de cada prompt, así los prefijos divergen desde el token 0 y cada petición ocupa su
propio KV — 30 ingenieros de verdad. `--session-mode shared` conserva el comportamiento
viejo, que sigue siendo útil: mide el **mejor caso** de prefix caching.

Los dos números importan, y su diferencia ES el argumento económico del plan.

Otros arreglos incluidos: un fallo ya no tumba el test (se cuenta, que es lo que pide el
checklist), y ambos scripts aceptan `--api-key` (lo necesitarás con LiteLLM en Tier 2).

---

## 1. Antes de entrar a RunPod

```bash
# Genera una llave SSH si no tienes (la vas a cargar en RunPod → Settings → SSH Keys)
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "runpod"
```

Crea cuenta en runpod.io → Billing → **$20**. Settings → SSH Public Keys → pega tu `.pub`.

---

## 2. Desplegar el pod

```text
Pods → Deploy → GPU:      L40S  ·  cantidad: 2
Template:                 RunPod PyTorch 2.x (CUDA 12.x)
Container Disk:           30 GB
Volume Disk:              80 GB   → montado en /workspace  (aquí viven los pesos)
Expose HTTP Ports:        8000
Expose TCP Ports:         22
Cloud:                    Community (más barato; en Tier 1 un reinicio no duele)
```

Precio esperado: ~$0.80–0.90/h por GPU → **~$1.7/h el pod**.

Cuando arranque: botón **Connect** → copia el comando `ssh root@… -p …`.

---

## 3. Instalar vLLM (una vez; queda en el volumen)

```bash
# desde tu Mac
ssh root@<IP> -p <PUERTO> -i ~/.ssh/id_ed25519

# --- ya dentro del pod ---
export HF_HOME=/workspace/hf                 # los pesos al volumen persistente
echo 'export HF_HOME=/workspace/hf' >> ~/.bashrc

pip install -q uv
uv venv /workspace/venv --python 3.12        # el venv también al volumen
source /workspace/venv/bin/activate
echo 'source /workspace/venv/bin/activate' >> ~/.bashrc
uv pip install vllm hf_transfer

vllm --version    # ← ANOTA ESTA VERSIÓN. Regla 4 del runbook: se fija en todos los tiers.
nvidia-smi        # ← confirma que ves 2× L40S
```

Descarga de los pesos (~31 GB, 5–12 min). Hacerlo aparte evita confundir "descarga lenta"
con "servidor roto":

```bash
export HF_HUB_ENABLE_HF_TRANSFER=1
hf download Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8
du -sh /workspace/hf     # debe dar ~31 GB
```

---

## 4. Levantar el servidor

```bash
mkdir -p /workspace/bench && cd /workspace/bench

nohup vllm serve Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --served-model-name qwen3-coder-30b \
  --tensor-parallel-size 2 \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.92 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --host 0.0.0.0 --port 8000 > /workspace/vllm.log 2>&1 &

tail -f /workspace/vllm.log    # Ctrl-C cuando veas "Uvicorn running on http://0.0.0.0:8000"
```

### El número más importante de todo el Tier 1

En el log, antes de "Uvicorn running", vLLM imprime algo como:

```text
GPU KV cache size: 1,047,552 tokens
```

**Anótalo.** Es la medición directa de la sección 5.1 del plan (que estimó 1.15M).

```bash
grep -i "kv cache size" /workspace/vllm.log
```

| Lo que veas | Qué significa |
|---|---|
| ≥ 900K tokens | El plan es correcto. 30 × 32K entra. Sigue. |
| 400–900K | Entra 30 × 16K, no 32K. Ajusta la política de contexto (5.4) a 16K. |
| < 400K | Algo está mal (¿KV en fp16?). Revisa troubleshooting antes de medir. |

Humo:

```bash
curl -s localhost:8000/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Hola"}]}' | head -c 300
```

---

## 5. Copiar los scripts y medir

**Mide desde dentro del pod.** El proxy HTTP de RunPod bufferea SSE y te inflaría el TTFT:
estarías midiendo la red de RunPod, no tu servidor.

```bash
# desde tu Mac, en otra terminal
cd ~/Documents/ai/inference-poc/benchmark
scp -P <PUERTO> -i ~/.ssh/id_ed25519 \
  benchmark_openai.py load_test.py tier1_sweep.sh prompt_largo.txt \
  root@<IP>:/workspace/bench/
```

```bash
# en el pod
cd /workspace/bench && chmod +x tier1_sweep.sh
uv pip install requests
./tier1_sweep.sh http://localhost:8000/v1 qwen3-coder-30b
```

El barrido corre, en orden: prefix caching (2 corridas) → concurrencia 1/5/10/20/30 a 16K
con sesiones únicas → 30 a 32K → 30 con prefijo compartido → métricas. Tarda ~20 min.

Al terminar, tráete los CSVs:

```bash
# desde tu Mac
scp -P <PUERTO> -i ~/.ssh/id_ed25519 'root@<IP>:/workspace/bench/results_tier1_*.csv' \
  ~/Documents/ai/inference-poc/benchmark/
```

### Una medición extra desde la Mac (el camino real del ingeniero)

```bash
ssh -N -L 8000:localhost:8000 root@<IP> -p <PUERTO> -i ~/.ssh/id_ed25519 &
cd ~/Documents/ai/inference-poc/benchmark && source .venv/bin/activate
python benchmark_openai.py --base-url http://localhost:8000/v1 --model qwen3-coder-30b \
  --prompt "$(cat prompt_largo.txt)" --out results_tier1_desde_mac.csv
```

La diferencia contra el mismo test corrido en el pod = **la latencia de red**. Anótala:
es un dato que el VP va a preguntar ("¿y desde la oficina?").

---

## 6. Checklist de compuerta

```text
[ ] KV cache reportado por vLLM        ≥ 900K tokens
[ ] Prefix caching: TTFT 2ª corrida    < 500 ms   (la 1ª será de segundos: es correcto)
[ ] c=30, 16K, sesiones únicas:  TTFT p90 < 1500 ms
[ ] c=30, 16K, sesiones únicas:  tok/s min ≥ 40
[ ] c=30, 16K, sesiones únicas:  0 fallos
[ ] c=30, 32K, sesiones únicas:  0 fallos y sin OOM en el log
[ ] La curva 1→5→10→20→30 es suave, no un acantilado
[ ] curl localhost:8000/metrics responde
```

El punto de la curva: si TTFT se dispara entre 20 y 30, encontraste el techo real del
nodo — y eso decide si el Tier 3 necesita 2 nodos o 3. Es el dato más caro de este día.

**Si algo falla, anota QUÉ falló y no pases al Tier 2.** Un "no" con número es el
resultado valioso (sección 8 del plan, regla 23 del roadmap).

---

## 7. La prueba que el runbook no tenía: tool calling

Riesgo #6 del plan ("vLLM/modelo tiene bug con tool calling del harness", detectarlo
"antes del piloto"). Te cuesta 15 min y cero dólares extra. **Hazlo.**

Relanza el servidor agregando:

```bash
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
```

Con el túnel SSH abierto, apunta opencode a `http://localhost:8000/v1` y dale una tarea
real de tu día (leer un archivo, editarlo, correr un comando). Lo que validas:

- ¿emite tool calls bien formadas?
- ¿encadena varios pasos sin perderse?
- ¿el harness compacta cuando el contexto crece? (sección 5.4)

Si el tool calling falla, **el Tier 2 no tiene sentido** por bueno que sea el TTFT:
los ingenieros no usan un modelo que no sabe usar herramientas.

---

## 8. Apagar (regla 1: sube → prueba → BAJA)

```text
Pods → Stop     (el volumen con los pesos sobrevive: la próxima sesión arranca en 3 min)
Costo del volumen parado: ~$8-16/mes por 80 GB.
Si no vuelves en esta semana → Destroy. Re-descargar son 10 minutos.
```

---

## 9. Troubleshooting

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| Error al arrancar mencionando `fp8` / kv cache dtype | Ada (sm89) con backend de atención que no acepta KV fp8 en esa versión | `VLLM_ATTENTION_BACKEND=FLASHINFER` antes del `vllm serve`; si sigue, **quita** `--kv-cache-dtype fp8` (KV pasa a 96 KB/token → la mitad de capacidad: anótalo, cambia las cuentas del plan) |
| OOM al cargar el modelo | poco margen | `--gpu-memory-utilization 0.88`, o `--max-model-len 32768` |
| "KV cache size" mucho menor a 900K | el fp8 del KV no se aplicó | `grep -i "kv cache dtype\|fp8" /workspace/vllm.log` |
| Descarga lentísima | sin hf_transfer | `export HF_HUB_ENABLE_HF_TRANSFER=1` |
| TTFT altísimo desde la Mac, normal en el pod | el proxy de RunPod | usa el túnel SSH; es ruido de red, no del servidor |
| El pod muere solo | Community Cloud te desalojó | relanza; para Tier 2–3 usa Secure (regla 3) |
| Cuelgue con c=30 | cola normal, no error | mira `vllm:num_requests_waiting` en `/metrics`: si hay espera, es el techo del nodo |

---

## 10. Qué NO valida este Tier (para no engañarte en el informe)

- **Calidad.** Tu `datasets/evaluation.jsonl` tiene **5 tareas**; el plan pide 20–40.
  Sin eso no puedes responder el criterio "≥75% de tareas resueltas" (sección 11).
  El mensaje a los ingenieros ya está escrito en `notes/04-dataset-evaluacion.md` §4 —
  mándalo hoy, en paralelo con el Tier 1. El dataset tarda días de calendario; la GPU,
  horas. Que corran a la vez.
- **Un nodo solo.** Alta disponibilidad y fallback son Tier 2 (2 nodos + LiteLLM).
- **Sesiones largas.** 20 minutos de test ≠ una sesión agéntica de 3 días. La
  fragmentación del KV cache y la evicción LRU aparecen con el tiempo, no con la carga.

---

## 11. Qué escribir cuando termines

Una tabla en este mismo repo (`reports/tier1-resultados.md`) con:

| | Estimado (plan) | Medido (Tier 1) |
|---|---|---|
| KV cache por nodo | 1.15M tokens | |
| TTFT p50 con cache hit | < 500 ms | |
| TTFT p90 con 30 concurrentes | < 1.5 s | |
| tok/s por usuario (30 concurrentes) | 40–80 | |
| Costo real de la tarde | $15–30 | |

Cada fila donde el medido difiera del estimado es una corrección al plan **antes** de
gastar los $250 del Tier 2. Para eso pagaste la GPU.
