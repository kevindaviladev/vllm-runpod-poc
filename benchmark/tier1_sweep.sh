#!/usr/bin/env bash
# Barrido completo de Tier 1. Correr DENTRO del pod (URL=http://localhost:8000/v1)
# para medir el servidor, no la red del proxy de RunPod.
#
#   ./tier1_sweep.sh http://localhost:8000/v1 qwen3-coder-30b
#
set -euo pipefail

URL="${1:?uso: ./tier1_sweep.sh <base-url> <model>}"
MODEL="${2:?uso: ./tier1_sweep.sh <base-url> <model>}"
OUT="${3:-results_tier1}"
PY="${PYTHON:-python3}"

echo "### 1. Prefix caching: mismo prompt 2 veces (la 2a debe volar)"
for i in 1 2; do
  $PY benchmark_openai.py --base-url "$URL" --model "$MODEL" \
    --prompt "$(cat prompt_largo.txt)" --out "${OUT}_cache.csv" > /dev/null
  echo "  corrida $i -> ${OUT}_cache.csv"
done

echo
echo "### 2. Curva de concurrencia, 16K de contexto, sesiones DISTINTAS"
for C in 1 5 10 20 30; do
  echo "--- concurrencia $C"
  $PY load_test.py --base-url "$URL" --model "$MODEL" \
    --concurrency "$C" --context-tokens 16000 --session-mode unique \
    --out "${OUT}_c${C}_16k.csv"
  echo
done

echo "### 3. Contexto 32K con 30 concurrentes (el escenario limite del plan)"
$PY load_test.py --base-url "$URL" --model "$MODEL" \
  --concurrency 30 --context-tokens 32000 --session-mode unique \
  --out "${OUT}_c30_32k.csv"

echo
echo "### 4. Mejor caso: 30 concurrentes compartiendo prefijo (prefix caching a tope)"
$PY load_test.py --base-url "$URL" --model "$MODEL" \
  --concurrency 30 --context-tokens 16000 --session-mode shared \
  --out "${OUT}_c30_16k_shared.csv"

echo
echo "### 5. Metricas del servidor"
curl -s "${URL%/v1}/metrics" | grep -E 'vllm:(num_requests|gpu_cache_usage|prefix_cache)' | head -20

echo
echo "Listo. CSVs: ${OUT}_*.csv"
