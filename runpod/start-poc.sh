#!/usr/bin/env bash
# Arranque completo del PoC en un pod de RunPod.
#   bash /workspace/start-poc.sh
#
# Levanta, en orden: Postgres -> vLLM (8000, privado) -> LiteLLM (8888, publico).
# Reinstala los venvs si el pod se reinicio (/root se borra, /workspace no).
set -uo pipefail

# ---- Configuracion (cambia las claves) --------------------------------------
export VLLM_API_KEY="${VLLM_API_KEY:-sk-vllm-CAMBIAME}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-master-CAMBIAME}"
export UI_USERNAME="${UI_USERNAME:-admin}"
export UI_PASSWORD="${UI_PASSWORD:-cambia-esto}"
MODEL_REPO="Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
MODEL_NAME="qwen3-coder-30b"
# Carpeta PLANA, no la cache de HF: en un volumen de red los symlinks de
# ~/.cache/huggingface no sobreviven al reinicio del pod y el modelo aparece
# como archivos de 0 bytes. Descargar siempre con --local-dir.
MODEL_DIR="/workspace/models/qwen3-coder-30b"

# ---- Rutas: pesos en el volumen, binarios en el container disk ---------------
export HF_HOME=/workspace/hf
export UV_CACHE_DIR=/root/.cache/uv
export XDG_CACHE_HOME=/root/.cache
export HOME=/root                      # prisma no puede escribir en el volumen de red
export DATABASE_URL="postgresql://postgres:litellm@localhost:5432/litellm"
export STORE_MODEL_IN_DB=true
export FORWARDED_ALLOW_IPS='*'         # uvicorn confia en el proxy de RunPod
POD="${RUNPOD_POD_ID:-}"
[ -n "$POD" ] && export PROXY_BASE_URL="https://${POD}-8888.proxy.runpod.net"

say() { echo -e "\n=== $* ==="; }

# ---- 1. Postgres -------------------------------------------------------------
say "Postgres"
# El container disk se borra en cada Stop: Postgres hay que reinstalarlo,
# y la base arranca VACIA (las virtual keys no sobreviven al apagado).
if ! command -v pg_isready >/dev/null 2>&1; then
  echo "instalando postgresql..."
  apt-get update -qq && apt-get install -y -qq postgresql
fi
service postgresql start >/dev/null 2>&1
for _ in $(seq 1 30); do pg_isready -h localhost -q 2>/dev/null && break; sleep 2; done
pg_isready -h localhost -q || { echo "Postgres no arranco"; exit 1; }
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD 'litellm';\"" >/dev/null 2>&1
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='litellm'\"" \
  | grep -q 1 || su - postgres -c "createdb litellm"
echo "ok"

# ---- 2. Venvs (se pierden al reiniciar el pod) -------------------------------
if [ ! -x /root/venv-vllm/bin/vllm ]; then
  say "Reinstalando vLLM (el pod se reinicio)"
  pip install -q uv
  uv venv /root/venv-vllm --python 3.12
  /root/venv-vllm/bin/uv pip install --python /root/venv-vllm/bin/python vllm hf_transfer \
    || uv pip install --python /root/venv-vllm/bin/python vllm hf_transfer
fi

if [ ! -x /root/venv-litellm/bin/litellm ]; then
  say "Reinstalando LiteLLM"
  uv venv /root/venv-litellm --python 3.12
  uv pip install --python /root/venv-litellm/bin/python 'litellm[proxy,extra_proxy]'
  # prisma lanza un /bin/sh que busca 'prisma-client-py' en el PATH:
  # con ruta absoluta falla. Hay que meter el venv en el PATH.
  ( export PATH="/root/venv-litellm/bin:$PATH"
    cd /root/venv-litellm/lib/python3.12/site-packages/litellm/proxy
    prisma generate )
fi

# La UI viene con un placeholder que LiteLLM no sustituye en la instalacion pip.
UI_OUT=/root/venv-litellm/lib/python3.12/site-packages/litellm/proxy/_experimental/out
if grep -rlq 'litellm-asset-prefix' "$UI_OUT" 2>/dev/null; then
  say "Corrigiendo rutas de assets de la UI"
  grep -rl 'litellm-asset-prefix' "$UI_OUT" | xargs sed -i 's|/litellm-asset-prefix|/ui|g'
fi

# ---- 3. vLLM -----------------------------------------------------------------
say "vLLM"
if [ ! -s "$MODEL_DIR/config.json" ]; then
  say "Descargando el modelo a $MODEL_DIR (~10 min)"
  HF_HUB_ENABLE_HF_TRANSFER=1 /root/venv-vllm/bin/hf download "$MODEL_REPO" \
    --local-dir "$MODEL_DIR"
fi

# Matar SIEMPRE tambien el EngineCore: si queda huerfano, retiene la VRAM
# y el siguiente arranque muere sin explicacion.
pkill -9 -f "vllm serve" 2>/dev/null; pkill -9 -f "VLLM::EngineCore" 2>/dev/null
sleep 5
nvidia-smi --query-gpu=memory.used --format=csv,noheader

nohup /root/venv-vllm/bin/vllm serve "$MODEL_DIR" \
  --served-model-name "$MODEL_NAME" \
  --max-model-len 65536 --gpu-memory-utilization 0.92 \
  --kv-cache-dtype fp8 --enable-prefix-caching \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --api-key "$VLLM_API_KEY" \
  --host 0.0.0.0 --port 8000 \
  > /workspace/vllm.log 2>&1 &

echo -n "cargando el modelo (3-6 min)"
for _ in $(seq 1 120); do
  curl -sf localhost:8000/health >/dev/null 2>&1 && break
  echo -n "."; sleep 5
done
echo
curl -sf localhost:8000/health >/dev/null 2>&1 || { echo "FALLO. tail -40 /workspace/vllm.log"; exit 1; }
grep -i "kv cache size" /workspace/vllm.log | tail -1

# ---- 4. LiteLLM --------------------------------------------------------------
say "LiteLLM"
# jupyter ocupa el 8888, el unico puerto que expone el template por defecto
pkill -9 -f jupyter 2>/dev/null
PID=$(ss -lntpH 2>/dev/null | grep ':8888' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "${PID:-}" ] && kill -9 "$PID"
sleep 3

cd /workspace/poc
nohup /root/venv-litellm/bin/litellm --config litellm-config.yaml \
  --host 0.0.0.0 --port 8888 > /workspace/litellm.log 2>&1 &

echo -n "arrancando el gateway"
for _ in $(seq 1 30); do
  curl -sf localhost:8888/health/liveliness >/dev/null 2>&1 && break
  echo -n "."; sleep 3
done
echo

# ---- 5. Restaurar las keys del equipo ----------------------------------------
# La DB se borra en cada Stop. Si existe keys.txt (una linea por persona:
# "alias sk-valor-de-la-key"), se recrean LAS MISMAS keys y nadie tiene que
# cambiar su opencode.json.
KEYS_FILE=/workspace/poc/keys.txt
if [ -f "$KEYS_FILE" ]; then
  say "Restaurando keys del equipo"
  while read -r ALIAS KEY; do
    { [ -z "${ALIAS:-}" ] || [ "${ALIAS:0:1}" = "#" ]; } && continue
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST localhost:8888/key/generate \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
      -d "{\"key\":\"$KEY\",\"key_alias\":\"$ALIAS\",\"models\":[\"$MODEL_NAME\"],\"tpm_limit\":200000,\"rpm_limit\":60}")
    echo "  $ALIAS -> HTTP $code"
  done < "$KEYS_FILE"
fi

# ---- 6. Resumen --------------------------------------------------------------
say "Listo"
ss -lntp | grep -E ':8000|:8888'
if [ -n "$POD" ]; then
  echo
  echo "Gateway : https://${POD}-8888.proxy.runpod.net/v1   (con virtual key)"
  echo "UI      : https://${POD}-8888.proxy.runpod.net/ui/  ($UI_USERNAME / $UI_PASSWORD)"
fi
echo
echo "Crear una key:"
echo "  curl -s -X POST localhost:8888/key/generate \\"
echo "    -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"key_alias\":\"NOMBRE\",\"models\":[\"$MODEL_NAME\"],\"max_budget\":5}'"
