#!/usr/bin/env bash
# Crea tu "virtual key" de demo en LiteLLM, con límites.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

echo "Esperando a LiteLLM en :4000..."
for _ in $(seq 1 30); do
  curl -sf http://localhost:4000/health/liveliness >/dev/null 2>&1 && break
  sleep 2
done

echo "Creando virtual key '${DEMO_KEY_ALIAS}' -> ${DEMO_KEY}"
curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"${DEMO_KEY}\",\"key_alias\":\"${DEMO_KEY_ALIAS}\",\"models\":[\"qwen-local\",\"qwen-local-7b\"],\"tpm_limit\":50000,\"rpm_limit\":30,\"max_budget\":5}" \
  | python3 -m json.tool 2>/dev/null || cat
