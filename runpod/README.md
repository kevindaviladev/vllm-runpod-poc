# Operar el PoC en RunPod

Cómo reanudar, apagar y arreglar el PoC (vLLM + LiteLLM en una L40S).

```text
opencode ──https──► RunPod proxy :8888 ──► LiteLLM (keys, UI, logs)
                                              └──localhost──► vLLM :8000 (privado)
                                                              + Postgres
```

---

## Qué sobrevive a un Stop y qué no

| | Tras Stop → Start |
|---|---|
| Modelo (`/workspace/models/qwen3-coder-30b`, 31 GB) | ✅ se conserva |
| `litellm-config.yaml`, `keys.txt`, scripts, `/workspace/datos/` | ✅ se conservan |
| Venvs de vLLM y LiteLLM (`/root`) | ❌ se borran → el script los reinstala |
| Postgres y las API keys | ❌ se borran → el script los recrea desde `keys.txt` |
| URL pública | ✅ igual si le das **Start al mismo pod** · ❌ cambia si creas uno nuevo |

Regla: **todo lo que importa vive en `/workspace`**. Lo demás es desechable.

---

## Reanudar (el caso normal)

**1.** RunPod → Pods → **Start** en el pod existente. No uses *Deploy* (daría un Pod ID
nuevo y una URL nueva).

**2.** Connect → **Web Terminal**.

**3.** Si el `start-poc.sh` del pod es de antes del 25/09, reemplázalo por el de este
repo:

```bash
cat > /workspace/start-poc.sh <<'SCRIPT_EOF'
# ... pega aquí el contenido de runpod/start-poc.sh ...
SCRIPT_EOF
```

> El `chmod +x` falla en el volumen de red. Da igual: se ejecuta con `bash`.

**4.** Arranca todo:

```bash
bash /workspace/start-poc.sh
```

Tarda **12–15 min**: Postgres → reinstala venvs → carga el modelo → gateway → keys.
Al final imprime algo así:

```text
=== Restaurando keys del equipo ===
  engineer-a -> HTTP 200
  engineer-b  -> HTTP 200
=== Listo ===
Gateway : https://<POD_ID>-8888.proxy.runpod.net/v1
UI      : https://<POD_ID>-8888.proxy.runpod.net/ui/  (admin / cambia-esto)
```

**5.** Comprueba que responde de punta a punta:

```bash
curl -s -X POST localhost:8888/v1/chat/completions \
  -H "Authorization: Bearer sk-master-CAMBIAME" -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Di hola"}]}' | head -c 200
```

---

## Las keys del equipo (`keys.txt`)

Postgres se borra en cada Stop. Para que tus compañeros **no tengan que cambiar de key**,
el script recrea las mismas desde este archivo:

```bash
cat > /workspace/poc/keys.txt <<'EOF'
# alias   key
engineer-a  sk-VALOR-REAL
engineer-b  sk-VALOR-REAL
EOF
```

- Se crea **una sola vez**. Vive en el volumen.
- Para sumar a alguien: agrega su línea y vuelve a correr `start-poc.sh`, o créale la
  key desde la UI y anótala aquí.
- La UI muestra el valor de una key **una sola vez**. Si lo perdiste, crea una nueva.
- ⚠️ Son secretos en texto plano. **No subas `keys.txt` a git.** Aceptable para el PoC;
  en producción van en un gestor de secretos.

Cada key se crea con **60 peticiones/min y 200,000 tokens/min**. Un humano no llega a
eso trabajando; sirve para frenar una sesión desbocada.

---

## Configurar opencode (lo que le pasas a cada persona)

`~/.config/opencode/opencode.json` (en Windows: `C:\Users\<usuario>\.config\opencode\opencode.json`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "poc": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "PoC RunPod",
      "options": {
        "baseURL": "https://<POD_ID>-8888.proxy.runpod.net/v1",
        "apiKey": "sk-SU-KEY"
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
```

El `limit.context` es lo que hace que opencode compacte antes de reventar el límite del
servidor. No lo quites.

---

## Apagar

```bash
bash /workspace/stop-poc.sh
```

Exporta los logs y las keys a `/workspace/datos/`, mata **también** el `EngineCore` de
vLLM y verifica que la VRAM quede en 0. Luego: **Pods → Stop**.

Confirma que el export no quedó vacío:

```bash
ls -la /workspace/datos/
```

---

## URLs

| Qué | Dónde |
|---|---|
| API (para opencode) | `https://<POD_ID>-8888.proxy.runpod.net/v1` |
| UI de LiteLLM | `https://<POD_ID>-8888.proxy.runpod.net/ui/` · `admin` / `cambia-esto` |
| Master key | `sk-master-CAMBIAME` (cámbiala si esto sale del PoC) |
| Métricas de vLLM | `curl localhost:8000/metrics` desde el pod |

El Pod ID sale en la tarjeta del pod, o con `echo $RUNPOD_POD_ID` en la terminal.

---

## Si algo falla

| Síntoma | Causa | Arreglo |
|---|---|---|
| `Operation not permitted` al instalar o hacer `chmod` | El volumen de red no soporta `chmod` | Binarios en `/root`, nunca en `/workspace`. Los scripts ya lo hacen. |
| `config.json is not a valid JSON` / archivos del modelo en 0 bytes | El volumen no conserva los symlinks de la caché de Hugging Face | Descargar siempre con `--local-dir` (el script ya usa `/workspace/models/`) |
| vLLM muere al arrancar sin razón clara | Un `VLLM::EngineCore` huérfano retiene la VRAM | `nvidia-smi` → `kill -9 <pid>` → confirmar `0 MiB` → relanzar |
| `address already in use` en el 8888 | Proceso viejo de LiteLLM o Jupyter vivo | `ss -lntp \| grep 8888` → `kill -9 <pid>` |
| `/key/generate` devuelve `{"detail":"Not Found"}` | LiteLLM sin la capa de base de datos | Instalar `litellm[proxy,extra_proxy]` y `prisma generate` **con el venv en el PATH** |
| `prisma-client-py: not found` | `prisma generate` llamado con ruta absoluta | `export PATH=/root/venv-litellm/bin:$PATH` antes |
| La UI queda en pantalla morada vacía | Placeholder `/litellm-asset-prefix` sin sustituir | El script corre el `sed` que lo cambia por `/ui` |
| La UI redirige a `http://100.65.x.x:.../ui/` | uvicorn no confía en las cabeceras del proxy | `FORWARDED_ALLOW_IPS='*'` (ya en el script) |
| opencode: `Connection error` | vLLM caído detrás del gateway | `tail -40 /workspace/vllm.log` y `ss -lntp \| grep 8000` |
| El proxy devuelve 404 | Puerto no expuesto en el pod | El template solo expone el **8888**: LiteLLM va ahí |
| Pegar un bloque largo lo corrompe | La terminal web mezcla la salida con lo que pegas | Pega los heredocs **solos**, sin otro comando corriendo |

---

## Crear un pod desde cero

Solo si el pod se destruyó o no hay L40S disponible.

- **GPU:** L40S, L40 o RTX 6000 Ada (Ada soporta FP8). **No** A40, A100 ni A6000.
- **Template:** RunPod PyTorch 2.x · Container disk 30 GB · volumen montado en `/workspace`.
- Si reusas el mismo volumen, el modelo ya está. Si es nuevo, `start-poc.sh` lo
  descarga solo (~10 min).
- Vas a tener que recrear `litellm-config.yaml` (ver `reports/poc-minimo-runpod-AHORA.md`)
  y `keys.txt`.
- **La URL cambia:** actualiza el `baseURL` en el `opencode.json` de cada persona.
