# Apuntes 03 — La cadena completa de una petición de inferencia

> El mapa total: qué pasa desde que tu app escribe "Hola" hasta que ve la respuesta.
> Cada paso: qué sucede → consideraciones (dónde se gana o pierde tiempo, memoria y dinero).
> Tus mediciones reales están como evidencia en los pasos clave.

---

## El mapa completo

```text
 TU APP                          SERVIDOR DE INFERENCIA
 ───────                          ─────────────────────────
 1. Construye la petición
        │
 2. Envía por HTTP ──────────►  3. Admisión (cola / scheduler)
                                 4. Tokenización del prompt
                                 5. Carga del modelo (solo si cold start)
                                 6. Prefill (lee tu prompt, paralelo)
                                 7. KV cache (memoria de lo procesado)
        │                        8. Decode: token por token, en loop
        │                           └─ Sampling: elige cuál token
 9. Recibe chunks ◄─────────     10. Streaming de vuelta
 11. Usa la respuesta               12. Limpieza / métricas / reutilización
```

---

## Paso 1 — Tu app construye la petición

**Qué sucede:** tu aplicación arma el JSON: mensajes (system, user, assistant),
qué modelo usar, y parámetros (temperature, max_tokens, etc.).

```json
{
  "model": "qwen2.5:7b",
  "messages": [
    {"role": "system", "content": "Eres un asistente interno..."},
    {"role": "user", "content": "Hola, ¿quién eres?"}
  ],
  "stream": true
}
```

**Consideraciones:**
- Todo lo que pongas aquí SON tokens que el modelo procesará y que alguien pagará.
  System prompt enorme = costo fijo en cada petición (a menos que haya prefix caching).
- El "contexto" que le das define la calidad. Mandar poco = modelo adivina;
  mandar todo = prefill caro + KV cache enorme. El punto medio profesional es RAG:
  buscar solo los fragmentos relevantes del documento y mandar esos.
- Gestión del historial: en un chat de 50 turnos, ¿reenvías todo cada vez?
  (es lo que hace la mayoría de las apps). Ese reenvío crece y crece.

---

## Paso 2 — Transporte (HTTP + streaming)

**Qué sucede:** el JSON viaja por HTTP al servidor. Con `"stream": true`, la conexión
se mantiene abierta y el servidor empuja fragmentos (chunks) a medida que genera.

**Consideraciones:**
- Sin streaming, el usuario espera la respuesta COMPLETA: el TTFT deja de existir
  como concepto y la percepción de lentitud se dispara. Streaming siempre.
- La red agrega overhead mínimo (tu `tok_s_reported` vs `tok_s_measured` diferían
  en ~0.2 tok/s: tu Python y la red casi no carcomen al backend). En producción
  esta comparación es un chequeo de salud de tu propia capa.

---

## Paso 3 — Admisión en el servidor (cola y scheduling)

**Qué sucede:** la petición entra. El scheduler decide: ¿entra al lote (batch) ahora,
o espera en cola? En producción aquí también viven autenticación, rate limits,
budgets (LiteLLM, cap. 8 de tu curriculum).

**Consideraciones:**
- El tiempo en cola Cuenta como TTFT para el usuario. Un servidor saturado no se
  ve "lento en calcular": se ve lento en responder la primera palabra.
- El continuous batching revisa el lote en cada paso: entra y sale sin esperar
  lotes completos. Decisión constante: admitir ahora vs proteger a los que ya
  están dentro (latencia) — con SLOs (promesas medibles) como árbitro.

---

## Paso 4 — Tokenización

**Qué sucede:** el texto se convierte en IDs de tokens usando la tabla (vocabulario)
del modelo. Fragmentos subword: palabras comunes = 1 token; raras = varios.
Se agregan tokens especiales de la plantilla de chat.

**Consideraciones:**
- El MISMO texto produce conteos DISTINTOS en tokenizadores distintos (Qwen vs
  Llama vs GLM). Por eso el costo del mismo documento varía por proveedor.
- Nunca estimes: cuenta. Tu script ya lo hace (`prompt_tokens`).
- Tu artículo real: 1,700 palabras → 2,032 tokens ≈ 1.2 tokens/palabra (español).

---

## Paso 5 — Carga del modelo (cold start)

**Qué sucede:** si el modelo no está en RAM, se copian los pesos desde disco.
Es una copia física de gigabytes, no una "inicialización".

**Evidencia tuya:**

| Estado | TTFT del 7B |
|---|---:|
| Frío (copiando ~4.7 GB a RAM) | ~1,015 ms |
| Caliente (ya en RAM) | 46 ms |

**Consideraciones:**
- `keep_alive` decide cuánto vive el modelo en RAM entre peticiones (5 min por
  defecto en Ollama; `-1` = nunca descargar).
- Decisión de producción: modelo residente (RAM pagada 24/7, cero cold starts)
  vs descargar (ahorras memoria, castigas al usuario esporádico). Con tráfico
  cada 20 minutos, el residente gana.

---

## Paso 6 — Prefill

**Qué sucede:** el modelo procesa TODO tu prompt de una vez. Los miles de núcleos
trabajan en paralelo sobre los tokens, que ya existen todos. Una (o pocas) pasadas
por los pesos rinden miles de tokens. Cada token procesado deja sus vectores listos.

**Evidencia tuya (7B):**

| Prompt | prefill tok/s |
|---:|---:|
| 41 tokens | ~380 |
| 2,032 tokens | ~929 |
| 6,038 tokens | ~1,224 |

**Consideraciones:**
- Compute-bound: la velocidad depende del PODER del chip y del tamaño del modelo
  (tu 0.5B leía a 11,700 tok/s; el 7B a 1,200 — 10x menos poder de cómputo necesario).
- Sube con prompts más largos (los costos fijos se amortizan) hasta saturar el hardware.
- El prefill es EL componente del TTFT cuando el prompt es grande: 20,000 tokens
  a 1,224 tok/s ≈ 16 segundos antes de la primera palabra. Por eso el serving
  profesional corre prefill en GPUs de datacenter y usa chunked prefill.

---

## Paso 7 — El KV cache

**Qué sucede:** por cada token procesado, el modelo guarda sus vectores internos
(Keys y Values). En el decode, cada token nuevo consulta ese archivo en vez de
recalcular todo el historial.

**Consideraciones:**
- Sin KV cache: cada token nuevo re-procesaría TODO el historial. La generación
  sería inserviblemente lenta. Es la optimización más importante del inference.
- Su memoria crece LINEAL con (longitud del contexto × usuarios simultáneos).
  Es el recurso que determina cuántos usuarios caben — el muro, no la velocidad.
- Se administra por páginas (PagedAttention) para no desperdiciar memoria, y
  páginas con el mismo prefijo se COMPARTEN entre usuarios (prefix caching).

---

## Paso 8 — El loop de decode + sampling (nuevo)

**Qué sucede, iteración a iteración:**

```text
REPETIR hasta condición de paro:
  a) El modelo hace UNA pasada por todos los pesos,
     consultando el KV cache (cada vez más grande)
  b) Salida: logits — una puntuación para CADA token del vocabulario (~150K)
  c) SAMPLING: convertir puntuaciones en una elección
  d) El token elegido: se envía por streaming y se agrega al KV cache
```

### El sampling (cómo se elige la palabra)

Los logits dan probabilidades. Elegir el más alto siempre = **greedy** (determinista).
Los LLMs en chat usan algo de azar controlado:

- **Temperature (0 a 1+)**: controla cuánto arriesga. Cerca de 0 = casi greedy
  (repetible, aburrido, ideal para extracción de datos). Alta = más variedad
  (ideal para brainstorming), más riesgo de disparates.
- **Top-p**: "solo considera tokens que juntos sumen p% de probabilidad".
  Recorta la cola de opciones absurdas.
- **Top-k**: "solo considera los k tokens más probables".

**Evidencia tuya del no-determinismo:** mismo prompt, 3 corridas → 167, 143 y 136
tokens de salida. Ese era el sampling trabajando (temperature > 0 por defecto).
Para benchmarks comparables: temperature 0, o promediar varias corridas.

**Consideraciones del decode:**
- Memory-bound: cada pasada mueve todos los bytes del modelo →
  tok/s ≈ bandwidth / GB. Tu 7B: techo 116, mediste 90.
- Cada pasada consulta un KV cache más grande → decode se frena levemente con
  contextos largos (89.8 → 72 tok/s en tus datos).
- Paro: cuando el modelo emite el token especial de fin (EOS) o se alcanza
  `max_tokens`. La longitud de la respuesta la decide el modelo — y el output
  es la parte cara de la factura.

---

## Paso 9-10 — Streaming de vuelta

**Qué sucede:** cada token elegido sale como un chunk JSON. Tu script mide el TTFT
con el primero y acumula el texto. El último chunk (`done: true`) trae la boleta:
`prompt_eval_count`, `eval_count`, `eval_duration`, `prompt_eval_duration`…

**Consideraciones:**
- La percepción del usuario la dominan TTFT + TPOT, no el total.
- La boleta final es tu fuente de verdad para benchmarks y costeo. Regla:
  instrumenta SIEMPRE con la boleta + tu reloj de pared (dos capas, como hiciste).

---

## Paso 11-12 — Limpieza y reutilización

**Qué sucede:** la petición termina. El KV cache de esa conversación se libera
(o se reutiliza si sigue el turno). El scheduler llena el hueco del lote. Las
métricas van a logs/monitoreo.

**Consideraciones:**
- En chats multi-turno, el historial se re-tokeniza y re-procesa en cada petición
  (a menos que el servidor soporte reutilizar el KV cache del turno anterior).
  Ese reprocesamiento es costo invisible que escala con la conversación.
- Sin keep_alive suficiente, el modelo se descarga → el siguiente usuario paga
  el cold start. Todo esto aparece en la factura como "costo operativo".

---

## La cadena en un ejemplo real tuyo (recorrido con números)

Petición: `qwen2.5:7b`, artículo de 2,032 tokens, respuesta de ~90 tokens, modelo ya cargado:

```text
 0.0 ms    Tu app envía JSON (~2,032 tokens de texto)
 ~5 ms     Red local + admisión (sin cola, un solo usuario)
 ~0 ms     Tokenización (ya contó: 2,032)
    —      Modelo residente: NO hay cold start (si no: +900 ms)
 46 ms     Prefill de 2,032 tokens TERMINA → sale el primer token (TTFT)
 46→1080ms Decode: ~90 pasadas a ~11 ms c/u, un token por pasada
           (KV cache creciendo; sampling eligiendo con temperature)
 1,080 ms  Última chunk + boleta de métricas
```

Cada paso que optimices en tu carrera apunta a uno de estos números:
que el modelo esté cargado (5), que el prefill sea rápido (6), que el KV cache
quepa (7), que las pasadas muevan menos bytes (quantization), o que cada pasada
sirva a más usuarios (batching).

## Auto-test final

Sin mirar: dibuja el mapa completo en una hoja, de memoria, y escribe al lado de
cada paso UNA consideración. Lo que no recuerdes, es lo que hay que releer.
