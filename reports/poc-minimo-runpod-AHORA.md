# PoC mínimo en RunPod — paso a paso, desde cero

> Objetivo: modelo + gateway con API keys + opencode conectado + métricas.
> **1 GPU. 1–2 personas. Unos minutos de prueba.**
> Tiempo: ~45 min la primera vez. Costo: **~$3** (L40S a ~$0.86/h).

Todo corre **dentro del pod**. Los pods de RunPod son contenedores: no tienen Docker
adentro, así que nada de `docker compose` allá. Se instala nativo. Está resuelto abajo.

```text
   Tu Mac (opencode)  ──https──►  pod de RunPod
                                   ├─ LiteLLM  :4000   (keys, UI, stats)
                                   │     └──localhost──►
                                   └─ vLLM     :8000   (el modelo)
                                        + Postgres :5432 (datos del gateway)
```

---

## PARTE 1 — Crear el pod (5 min)

1. Entra a **runpod.io** → crea cuenta → **Billing** → agrega **$20**.

2. **Pods** → **Deploy**.

3. **Elige la GPU: `L40S` (48 GB), cantidad 1.**

   > ⚠️ **No elijas A40, A100 ni A6000.** Son Ampere y no soportan FP8 por hardware:
   > el modelo no carga o carga lentísimo. Sirven: **L40S, L40, RTX 6000 Ada, H100**.
   > Si no hay L40S disponible, usa RTX 6000 Ada o L40.

4. **Template**: `RunPod PyTorch 2.x` (el que traiga CUDA 12.x).

5. Abre **Edit Template / Customize Deployment** y pon:

   ```text
   Container Disk:      30 GB
   Volume Disk:         80 GB      → Volume Mount Path: /workspace
   Expose HTTP Ports:   8000,4000
   Expose TCP Ports:    22
   ```

   > ⚠️ **Los puertos hay que declararlos AHORA.** Agregarlos después obliga a
   > recrear el contenedor: se borra el container disk (y con él los venvs), aunque
   > `/workspace` sobrevive. Si vas a querer Grafana en el pod, pon `8000,4000,3000,9090`.
   >
   > **Verifícalo cuando el pod esté Running**: botón *Connect* debe listar
   > `HTTP Service [Port 8000]` y `[Port 4000]`. El template de PyTorch trae
   > **solo 8888** (Jupyter) por defecto: si eso es lo único que ves, no declaraste
   > nada. **Plan B sin recrear el pod**: mata Jupyter (`pkill -f jupyter`) y corre
   > LiteLLM en el 8888, que ya está expuesto. Queda incluso mejor: vLLM se queda
   > privado en `localhost:8000` y solo el gateway sale a internet.

6. **Deploy On-Demand**. Espera 1–2 min a que diga **Running**.

7. Botón **Connect** → **Start Web Terminal** → **Connect to Web Terminal**.
   (Es una terminal en el navegador. Cero configuración. Ahí va todo lo que sigue.)

8. Anota tu **Pod ID** (lo ves en la tarjeta del pod, ej. `a1b2c3d4e5`). Tus URLs son:

   ```text
   vLLM:    https://<POD_ID>-8000.proxy.runpod.net
   LiteLLM: https://<POD_ID>-4000.proxy.runpod.net
   ```

---

## PARTE 2 — Instalar y levantar el modelo (20 min, casi todo espera)

Copia y pega bloque por bloque en la Web Terminal.

### 2.1 Preparar el entorno

> ⚠️ **Los binarios NO van en `/workspace`.** Si tu volumen es de red (tipo "Global"),
> no soporta `chmod` y la instalación revienta con
> `failed to set permissions ... Operation not permitted (os error 1)`.
> Además, en esta imagen `HOME=/workspace`, así que las cachés se van solas al
> volumen de red. Regla: **pesos en `/workspace`, binarios en el container disk.**

```bash
# Los PESOS al volumen (31 GB, es lo lento: vale la pena persistirlo)
export HF_HOME=/workspace/hf
echo 'export HF_HOME=/workspace/hf' >> ~/.bashrc

# El venv y la cache al CONTAINER DISK (necesitan permisos POSIX reales)
export UV_CACHE_DIR=/root/.cache/uv
echo 'export UV_CACHE_DIR=/root/.cache/uv' >> ~/.bashrc

df -h / /workspace          # necesitas ~20 GB libres en /

pip install -q uv
uv venv /root/venv-vllm --python 3.12
source /root/venv-vllm/bin/activate
uv pip install vllm hf_transfer
uv cache clean              # libera ~6-8 GB de wheels ya instalados

vllm --version     # ← ANÓTALA. Se fija igual en todos los tiers (regla 4 del runbook)
nvidia-smi         # ← debes ver 1× L40S con 48 GB
```

> Al reiniciar el pod, `/root` se borra y `/workspace` sobrevive: hay que repetir
> el `uv venv` + `uv pip install` (~2-3 min), pero NO la descarga del modelo (~12 min).
> Tu `~/.bashrc` también vive en `/workspace`, así que las variables persisten.

### 2.2 Descargar el modelo (~31 GB, 5–12 min)

```bash
export HF_HUB_ENABLE_HF_TRANSFER=1
hf download Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8
du -sh /workspace/hf      # debe dar ~31 GB
```

### 2.3 Inventar tus dos claves (guárdalas, las usarás 4 veces)

```bash
cat >> ~/.bashrc <<'EOF'
export VLLM_API_KEY=sk-vllm-cambia-esto-123
export LITELLM_MASTER_KEY=sk-master-cambia-esto-456
EOF
source ~/.bashrc
```

> La URL del pod es **pública**: cualquiera con tu Pod ID puede llegar. Por eso vLLM
> arranca con `--api-key`. No lo omitas.

### 2.4 Levantar vLLM

```bash
mkdir -p /workspace/poc && cd /workspace/poc

nohup vllm serve Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --served-model-name qwen3-coder-30b \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.92 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --api-key $VLLM_API_KEY \
  --host 0.0.0.0 --port 8000 \
  > /workspace/vllm.log 2>&1 &

tail -f /workspace/vllm.log
```

Espera 3–5 min. **Ctrl-C** cuando veas `Uvicorn running on http://0.0.0.0:8000`.

> `--enable-auto-tool-choice --tool-call-parser qwen3_coder` es **obligatorio**:
> sin eso opencode no funciona (el modelo escupe las llamadas a herramientas como
> texto en vez de ejecutarlas). Si vLLM se queja del nombre del parser:
> `vllm serve --help | grep -A5 tool-call-parser` y usa `hermes` en su lugar.

Anota el número clave del log:

```bash
grep -i "kv cache size" /workspace/vllm.log
```

Con 1× L40S deberías ver **~150K–200K tokens**. Para 1–2 personas sobra
(2 sesiones × 64K = 128K). Para los 30 del plan haría falta el nodo de 2 GPUs.

### 2.5 Probar que responde

```bash
curl -s localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer $VLLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Di hola en 3 palabras"}]}' \
  | head -c 400
```

Si ves un JSON con texto, **el modelo ya está sirviendo**. ✅

---

## PARTE 3 — El gateway: LiteLLM con keys y UI (10 min)

### 3.1 Postgres (lo necesita la UI para guardar keys y gasto)

```bash
apt-get update -qq && apt-get install -y -qq postgresql
service postgresql start
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD 'litellm';\""
su - postgres -c "createdb litellm"
```

### 3.2 LiteLLM (en su PROPIO entorno, no mezclar con vLLM)

```bash
uv venv /root/venv-litellm --python 3.12          # container disk, igual que vLLM
source /root/venv-litellm/bin/activate
uv pip install 'litellm[proxy]'
```

> Entornos separados a propósito: LiteLLM y vLLM piden versiones distintas de las
> mismas librerías. Si los mezclas, rompes vLLM.

### 3.3 La configuración

```bash
cat > /workspace/poc/litellm-config.yaml <<'EOF'
model_list:
  - model_name: qwen3-coder-30b
    litellm_params:
      model: openai/qwen3-coder-30b
      api_base: http://localhost:8000/v1
      api_key: os.environ/VLLM_API_KEY
      input_cost_per_token: 0
      output_cost_per_token: 0

litellm_settings:
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
```

### 3.4 Levantarlo

```bash
cd /workspace/poc
export DATABASE_URL="postgresql://postgres:litellm@localhost:5432/litellm"
export UI_USERNAME=admin
export UI_PASSWORD=cambia-esto
export STORE_MODEL_IN_DB=true

nohup litellm --config litellm-config.yaml --host 0.0.0.0 --port 4000 \
  > /workspace/litellm.log 2>&1 &

tail -f /workspace/litellm.log
```

El primer arranque tarda 1–2 min (prepara la base de datos). **Ctrl-C** cuando veas
`Uvicorn running on http://0.0.0.0:4000`.

### 3.5 Crear tu primera API key

```bash
curl -s -X POST localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"kevin","models":["qwen3-coder-30b"],"max_budget":5}'
```

Devuelve `{"key":"sk-..."}`. **Cópiala: es la que usará opencode.**

Para la otra persona, el mismo comando con `"key_alias":"persona2"`. Cada una
aparece por separado en la UI con sus tokens y su gasto.

### 3.6 La UI

Abre en tu navegador:

```text
https://<POD_ID>-4000.proxy.runpod.net/ui
```

Login: `admin` / `cambia-esto`. Ahí ves **Virtual Keys** (crear/borrar/presupuestos),
**Logs** (cada request con su key, tokens y latencia) y **Usage** (gasto por persona).

### 3.7 La prueba de seguridad (hazla, es el argumento de venta)

```bash
# SIN key → 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  https://<POD_ID>-4000.proxy.runpod.net/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"hola"}]}'

# CON key → 200
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  https://<POD_ID>-4000.proxy.runpod.net/v1/chat/completions \
  -H "Authorization: Bearer sk-TU-KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"hola"}]}'
```

---

## PARTE 4 — Conectar opencode desde tu Mac (5 min)

**En tu Mac**, no en el pod:

```bash
mkdir -p ~/.config/opencode
cat > ~/.config/opencode/opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "poc": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "PoC RunPod",
      "options": {
        "baseURL": "https://POD_ID-4000.proxy.runpod.net/v1",
        "apiKey": "sk-TU-KEY"
      },
      "models": {
        "qwen3-coder-30b": {
          "name": "Qwen3-Coder 30B FP8 (L40S)",
          "limit": { "context": 65536, "output": 8192 }
        }
      }
    }
  },
  "model": "poc/qwen3-coder-30b"
}
EOF
```

Reemplaza `POD_ID` y `sk-TU-KEY`. Luego:

```bash
opencode
/models          # debe aparecer "PoC RunPod"
```

Y dale una tarea real: *"lee este archivo, encuentra el bug y arréglalo"*.

> El `"limit": {"context": 65536}` no es decorativo: es la **política de contexto**
> (§5.4 del plan). Le dice a opencode que compacte antes de reventar el límite del
> servidor. Sin eso, la sesión falla cuando crece.

**Para la otra persona**: mismo archivo, cambiando solo `apiKey` por la suya.
No necesita VPN ni estar en tu red — la URL del pod es pública y la key la protege.

---

## PARTE 5 — Métricas (opcional, 5 min)

Ya tienes dos fuentes funcionando:

| Qué quieres ver | Dónde |
|---|---|
| Gasto y tokens **por persona**, logs por request | UI de LiteLLM → `/ui` |
| TTFT, tok/s, cola, KV cache en uso, prefix cache hits | `curl localhost:8000/metrics` en el pod |

> LiteLLM tiene su propio `/metrics`, pero es función **Enterprise**: sin licencia
> devuelve vacío. Las stats por persona salen de la UI, no de Prometheus.

Si quieres los dashboards bonitos, **no instales nada en el pod**: usa el
`docker-compose` que ya tienes en la Mac, solo esos dos servicios.

```bash
# en tu Mac
cd ~/Documents/ai/inference-poc/local-poc
# edita prometheus/prometheus.yml: cambia CAMBIAME-8000.proxy.runpod.net por tu pod
docker compose up -d prometheus grafana
open http://localhost:3001      # admin / el GRAFANA_PASSWORD de tu .env
```

En Grafana: Add data source → Prometheus → `http://prometheus:9090` → Save & Test.
Luego Dashboards → Import → ID **23991** (el dashboard oficial de vLLM).

---

## PARTE 6 — Apagar (¡no lo olvides!)

```text
Pods → Stop     ← el volumen con los pesos sobrevive; volver a arrancar toma ~3 min
```

Un pod parado sigue cobrando el almacenamiento (~$8/mes por 80 GB). Si no vuelves
esta semana: **Destroy**. Re-descargar el modelo son 10 minutos.

> Al reiniciar el pod: los entornos y los pesos están en `/workspace`, pero
> **los procesos no**. Hay que repetir 2.4 y 3.4 (y `service postgresql start`).

---

## Si algo falla

| Síntoma | Qué hacer |
|---|---|
| Error mencionando `fp8` al arrancar vLLM | Quita `--kv-cache-dtype fp8`. Pierdes la mitad de la capacidad de contexto; para 1–2 personas da igual. Anótalo. |
| `OOM` / `No available memory for the cache blocks` | Baja a `--gpu-memory-utilization 0.88` o `--max-model-len 32768` |
| La URL `*.proxy.runpod.net` da 502 | El servicio aún no arranca (mira el log) o no pusiste `--host 0.0.0.0` |
| El puerto 4000 no aparece en Connect | No lo declaraste al crear el pod. Hay que recrearlo. |
| opencode dice "model not found" | El `model_name` del config de LiteLLM debe ser idéntico al de `opencode.json` |
| opencode se conecta pero no usa herramientas | Falta `--enable-auto-tool-choice --tool-call-parser` en vLLM |
| LiteLLM no arranca, error de prisma/DB | Verifica `service postgresql status` y que `DATABASE_URL` esté exportada |
| Al cerrar el navegador se murió todo | Usa `nohup ... &` como en los comandos (ya está puesto) |
| `hf: command not found` | Te faltó `source /root/venv-vllm/bin/activate` |
| `Operation not permitted (os error 1)` al instalar | Estás instalando en el volumen de red. Venv y `UV_CACHE_DIR` van al container disk (ver 2.1) |
| `No space left on device` en `/` | `uv cache clean`, y si no alcanza, recrea el pod con más container disk |

---

## Qué habrás demostrado al terminar

- **Funciona**: un modelo open-source de 30B sirviendo código desde tu propia GPU.
- **Es gestionable**: keys por persona, presupuestos, y cada request registrado con
  su dueño, sus tokens y su latencia.
- **Es portable**: opencode habla con tu gateway igual que hablaría con Anthropic.
  Cambiar de backend es cambiar una URL.
- **Lo que falta para el plan real**: los 30 concurrentes necesitan el nodo de 2 GPUs
  (ver `tier1-runpod-instrucciones.md`), y la calidad necesita tu dataset de 20–40
  tareas, que hoy tiene 5.
