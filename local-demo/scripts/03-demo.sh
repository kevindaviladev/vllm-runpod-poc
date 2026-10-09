#!/usr/bin/env bash
# El demo de 3 pasos: directo a Ollama, LiteLLM sin key, LiteLLM con key.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

echo "=================================================="
echo " 1) DIRECTO a Ollama (sin auth)          -> :11434"
echo "=================================================="
curl -s http://localhost:11434/api/chat \
  -d "{\"model\":\"${OLLAMA_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Di hola en 5 palabras\"}],\"stream\":false}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['message']['content'])"

echo
echo "=================================================="
echo " 2) LiteLLM SIN key (debe responder 401)  -> :4000"
echo "=================================================="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"hola"}]}'

echo
echo "=================================================="
echo " 3) LiteLLM CON tu virtual key (${DEMO_KEY})"
echo "=================================================="
curl -s -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${DEMO_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"Di hola en 5 palabras"}]}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['choices'][0]['message']['content']);print('usage:',d.get('usage'))"
