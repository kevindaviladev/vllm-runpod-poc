#!/usr/bin/env bash
# Descarga el modelo pequeño de Qwen dentro del contenedor de Ollama.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

echo "Descargando '$OLLAMA_MODEL' en el contenedor de Ollama..."
docker compose exec ollama ollama pull "$OLLAMA_MODEL"
echo "Modelos disponibles:"
docker compose exec ollama ollama list
