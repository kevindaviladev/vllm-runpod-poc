#!/usr/bin/env bash
# Parada limpia. Lo critico: matar TAMBIEN el EngineCore de vLLM, que queda
# huerfano reteniendo toda la VRAM y hace fallar el siguiente arranque.
set -uo pipefail

# La base de datos vive en el container disk y se BORRA al parar el pod.
# Exportar antes es la unica forma de conservar los datos de la sesion.
M="${LITELLM_MASTER_KEY:-sk-master-CAMBIAME}"
STAMP=$(date +%F-%H%M)
if curl -sf localhost:8888/health/liveliness >/dev/null 2>&1; then
  mkdir -p /workspace/datos
  curl -s "localhost:8888/spend/logs" -H "Authorization: Bearer $M" \
    > "/workspace/datos/spend-logs-$STAMP.json"
  curl -s "localhost:8888/key/list" -H "Authorization: Bearer $M" \
    > "/workspace/datos/keys-$STAMP.json"
  echo "Datos exportados a /workspace/datos/ (sobreviven al apagado)"
fi

pkill -9 -f "litellm --config" 2>/dev/null
PID=$(ss -lntpH 2>/dev/null | grep ':8888' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "${PID:-}" ] && kill -9 "$PID"

pkill -9 -f "vllm serve" 2>/dev/null
pkill -9 -f "VLLM::EngineCore" 2>/dev/null
sleep 5

echo "VRAM en uso (debe ser 0 MiB):"
nvidia-smi --query-gpu=memory.used --format=csv,noheader
echo "Puertos (debe estar vacio):"
ss -lntp | grep -E ':8000|:8888' || echo "  libres"
echo
echo "Ahora sí: Pods -> Stop en el dashboard de RunPod."
