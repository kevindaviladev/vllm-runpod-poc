#!/usr/bin/env bash
# Barrido de performance contra el gateway (o directo contra vLLM).
#
#   ./bench_gateway.sh <base-url> <modelo> <api-key> [etiqueta]
#
# Ejemplo:
#   ./bench_gateway.sh https://POD-8888.proxy.runpod.net/v1 qwen3-coder-30b sk-xxx l40s-gateway
#
set -uo pipefail

URL="${1:?uso: ./bench_gateway.sh <base-url> <modelo> <api-key> [etiqueta]}"
MODEL="${2:?falta el modelo}"
KEY="${3:?falta la api key}"
TAG="${4:-run}"
PY="${PYTHON:-python}"

OUT="resultados/${TAG}-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"
LOG="$OUT/salida.txt"

run() {  # run <nombre> <concurrencia> <contexto> <modo>
  echo -e "\n########## $1  (c=$2, ctx=$3, $4) ##########" | tee -a "$LOG"
  $PY load_test.py --base-url "$URL" --model "$MODEL" --api-key "$KEY" \
    --concurrency "$2" --context-tokens "$3" --session-mode "$4" \
    --out "$OUT/$1.csv" 2>&1 | tee -a "$LOG"
}

echo "Destino: $URL" | tee "$LOG"
echo "Modelo : $MODEL" | tee -a "$LOG"
echo "Inicio : $(date)" | tee -a "$LOG"

# Calentamiento: la primera peticion siempre es atipica, no cuenta.
echo -e "\n--- calentando ---" | tee -a "$LOG"
$PY load_test.py --base-url "$URL" --model "$MODEL" --api-key "$KEY" \
  --concurrency 1 --context-tokens 4000 --session-mode unique >/dev/null 2>&1

# La curva: sesiones DISTINTAS, que es el caso real de N ingenieros.
run c01-16k   1  16000 unique
run c05-16k   5  16000 unique
run c10-16k  10  16000 unique

# Contexto grande: donde el KV cache empieza a apretar.
run c05-32k   5  32000 unique
run c10-32k  10  32000 unique

# El dato economico: los MISMOS 10 usuarios compartiendo prefijo.
# La diferencia contra c10-16k es el prefix caching -- lo que Anthropic
# cobra y esta GPU regala.
run c10-16k-shared 10 16000 shared

echo -e "\nFin: $(date)" | tee -a "$LOG"
echo "Resultados en $OUT/"
