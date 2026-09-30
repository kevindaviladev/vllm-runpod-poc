# Apuntes 01 — Fundamentos de inferencia (con mis propios datos)

> Regla: si no puedo explicar esto con mis palabras, no avanzo a lo siguiente.

## La cadena completa (lo que pasa desde que envías un prompt)

```text
1. Tu script envía JSON por HTTP al servidor (Ollama, puerto 11434)
2. Si el modelo NO está en RAM → se cargan los pesos (~800 ms: "cold start")
3. PREFILL: el servidor procesa tu prompt completo, en paralelo
4. Cada token procesado guarda sus vectores en el KV cache
5. DECODE: genera UN token, consulta el KV cache, repite hasta terminar
6. Cada token generado viaja a tu script como un chunk JSON (streaming)
7. El último chunk trae la boleta: tokens, tiempos, etc.
```

Evidencia medida (Mac M4 Max, 546 GB/s de bandwidth):

| Qué | 0.5B | 7B (Q4) |
|---|---:|---:|
| Pesos en disco | ~0.4 GB | ~4.7 GB |
| Decode tok/s | ~350 | ~90 |
| TTFT caliente | ~34 ms | ~46 ms |
| TTFT frío | ~50 ms | ~1000 ms |
| Prefill tok/s (prompt largo) | ~11,700 | ~1,200 |

## Las 3 reglas que explican toda la tabla

1. **Tamaño en GB ≈ parámetros × bytes/parámetro**
   (FP16 = 2 bytes, INT8 = 1, INT4 = 0.5 → 7B: 14 / 7 / ~4 GB)

2. **Decode es memory-bound: cada token generado obliga a leer TODOS los pesos**
   → tok/s máx ≈ bandwidth / GB del modelo
   → 546/4.7 ≈ 116 techo, medí 91. El modelo grande es lento porque pesa.
   → Por eso cuantizar (menos bytes) = más RAM libre + más tok/s.

3. **Prefill es compute-bound: procesa el prompt en paralelo**
   → Su velocidad no colapsa con prompts largos (380 → 929 → 1224 tok/s según crece el prompt: se amortizan costos fijos).
   → Pero escala con el TAMAÑO del modelo (0.5B lee 12x más rápido que 7B).

## Conceptos y su razón de ser (una línea cada uno)

- **Token**: fragmento de texto (~¾ palabra). Unidad de entrada, salida, precio y memoria.
- **Pesos**: los miles de millones de números entrenados. Vivir en RAM es obligatorio para inferir.
- **Inference**: usar los pesos para predecir el siguiente token, en loop (autoregresivo).
- **API / streaming**: el modelo vive en un servidor HTTP; la respuesta llega chunk por chunk.
- **KV cache**: memoria de trabajo que evita recalcular el prompt en cada token. Crece con el contexto.
- **Context window (num_ctx)**: máximo de tokens que el modelo puede "ver". Lo que no cabe se TRUNCA en silencio.
- **TTFT**: espera hasta el primer token = carga (si es fría) + prefill. Lo que percibe el usuario.
- **tok/s**: velocidad de decode. Casi invisible para un humano leyendo; crítica para costo con muchos usuarios.
- **Cold/warm start**: primera llamada carga pesos (~900 ms de impuesto). keep_alive decide cuánto vive el modelo en RAM.
- **Quantization**: comprimir pesos con menos bits (FP16→INT4). Menos memoria, más velocidad, algo de calidad.
- **Modelo residente**: mantener el modelo siempre cargado = cero cold starts = RAM pagada 24/7.
- **Prefill vs decode**: leer es paralelo y barato; escribir es secuencial y caro. Por eso el output cuesta más que el input en las APIs.

## Las dos analogías (mi explicación de cabecera)

**El camión de reparto (por qué el modelo grande es lento):**
Para escribir CADA palabra, el procesador debe consultar el libro completo de pesos (4.7 GB en mi 7B). El límite es la entrega de memoria: 546 GB/s. Techo de velocidad = bandwidth / GB del libro. Libro más liviano (quantization) = más palabras por segundo. GPU de datacenter = camión más rápido (H100: 3,350 GB/s).

**La pasada (por qué leer es 13x más rápido que escribir):**
La unidad cara es UNA pasada completa por los pesos. En prefill, los miles de tokens del prompt ya existen → todos los núcleos los procesan a la vez → pocas pasadas, miles de tokens por pasada. En decode, cada palabra nueva depende de la anterior → UNA pasada por palabra. Mismo libro, mismo camión: distinto rendimiento por pasada.

Mi evidencia: prefill 1,224 tok/s vs decode 90 tok/s en el mismo modelo y run.

