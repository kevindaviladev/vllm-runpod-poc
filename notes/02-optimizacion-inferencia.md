# Apuntes 02 — Optimización de inferencia (en español, desde cero)

> Este es tu "capítulo de libro" en español. Cubre lo mismo que el capítulo de
> inferencia del libro de Chip Huyen (*AI Engineering*), pero con ejemplos basados
> en TUS mediciones. Léelo antes de seguir con los experimentos.
>
> Regla: cada sigla se explica la primera vez que aparece. Si alguna se te escapa,
> está toda en el glosario final.

---

## Repaso de 30 segundos (lo que ya sabes de 01-fundamentos)

```text
Tu app → HTTP (protocolo web) → servidor con el modelo cargado en RAM
                                   │
                                   ├─ PREFILL: lee tu prompt completo (paralelo)
                                   ├─ KV cache: memoria de lo ya procesado
                                   └─ DECODE: genera 1 token por pasada (secuencial)
Tu app recibe chunks (streaming) ← ┘
```

Tus números de referencia (Mac M4 Max, 128 GB, bandwidth 546 GB/s):

| Modelo | Pesos | Decode | Lectura (prefill) |
|---|---:|---:|---:|
| Qwen 0.5B | ~0.4 GB | ~350 tok/s | ~11,700 tok/s |
| Qwen 7B (4-bit) | ~4.7 GB | ~90 tok/s | ~1,200 tok/s |

---

## 1. Las métricas de latencia (y los famosos percentiles)

### TTFT — Time To First Token
Tiempo desde que envías la petición hasta que aparece la primera palabra.
Es lo que un usuario percibe como "la app está lenta". Ya lo mides: tu 7B frío = 1,015 ms, caliente = 46 ms.

### TPOT — Time Per Output Token (nuevo)
Tiempo PROMEDIO por cada token generado después del primero.

```text
TPOT = (tiempo total − TTFT) / tokens generados
```

Con tu run del 7B: (1948 − 1016) / 85 ≈ 11 ms por token ≈ 90 tok/s. Es la misma
información que tu `tok/s` vista "por token" — las APIs profesionales reportan TPOT.

### Percentiles: p50, p90, p99 (nuevo y CRÍTICO)

Decir "el promedio es rápido" miente. Los percentiles cuentan la historia completa:

```text
Hiciste 100 peticiones. Ordenas sus latencias de menor a mayor:
  p50 = la petición número 50   → "el usuario típico"
  p90 = la petición número 90   → "1 de cada 10 usuarios sufrió esto"
  p99 = la petición número 99   → "el peor caso de 100"
```

Ejemplo real: si tu p50 es 200 ms pero tu p99 es 8,000 ms, la mitad de usuarios
experimenta algo rápido, pero el 1% espera 8 segundos — y en una empresa con 1,000
usuarios, ese 1% son 10 personas furiosas cada día. **Las promesas de servicio se
escriben sobre percentiles, no sobre promedios.**

### Latencia individual vs Throughput

- **Latencia**: cuánto espera UN usuario (importa para la experiencia).
- **Throughput**: cuánto trabajo total hace el sistema por segundo (importa para el costo).

Son tensiones opuestas: puedes hacer el sistema más "rentable" (más throughput)
haciendo que cada usuario individual espere un poco más. Todo el arte está en
negociar ese intercambio con datos.

---

## 2. Batching: no dejes el camión medio vacío

### El problema

Recuerda la ley de tu hardware: cada token generado requiere leer TODOS los pesos
(el camión entrega el libro completo por cada palabra). Si el servidor atiende a UN
usuario a la vez, el libro se entrega 90 veces por segundo… para producir palabras
de una sola persona. Los miles de núcleos de la GPU pasan aburridos.

### La idea

Si varios usuarios generan al mismo tiempo, **cada pasada por los pesos puede
producir UN token para CADA usuario del lote** ("batch" = lote). El libro se entrega
una vez y sirve para todos:

```text
Sin batching:  1 pasada → 1 token para 1 usuario
Con batch de 20: 1 pasada → 20 tokens (1 por usuario), casi al mismo costo
```

El throughput se multiplica; el costo por token se desploma. **Esta es la razón
económica principal por la que existe el serving profesional** — y por qué una API
comercial puede cobrar tan poco por token: miles de usuarios comparten el mismo
camión.

### Los tres tipos

- **Static batching**: esperas a juntar N peticiones, procesas el lote completo,
  entregas todo al final. Simple, pero el usuario A espera a que termine el lento
  usuario Z. Nadie lo usa para LLMs.
- **Dynamic batching**: juntas las peticiones que llegan dentro de una ventana de
  tiempo (ej. 50 ms). Mejor, pero sigue esperando.
- **Continuous batching** (el estándar en LLMs): el lote se revisa en CADA paso.
  Cuando el usuario A termina, su lugar se libera al instante; si llega el usuario D,
  entra en el siguiente paso. Nadie espera a nadie:

```text
Paso:    1    2    3    4    5    6
User A:  t1   t2   t3   t4   FIN
User B:  t1   t2   t3   t4   t5   t6 …
User C:  t1   t2   FIN
User D:                      t1   t2 …  ← entró sin esperar
```

### El precio

Más usuarios en el lote = más KV cache en memoria = cada pasada consulta más cosas.
El TTFT puede subir y el TPOT degradarse suavemente. El servidor profesional decide
constantemente: **¿admito esta petición ahora o la pongo en cola?** (scheduling).
Por eso existe la métrica "queue time" (tiempo de espera en cola) en los dashboards.

---

## 3. KV cache y PagedAttention

### Cuánto pesa el KV cache (aproximación que sí puedes usar)

```text
KV cache ≈ 2 × capas × contexto × dimensión × bytes
```

No memorices la fórmula; graba la forma: **crece lineal con el contexto y con la
concurrency**. Un 7B con contexto de 8K y varios usuarios puede necesitar GBs
adicionales además de sus 4.7 GB de pesos. La memoria, no la velocidad, es lo que
limita cuántos usuarios caben en una GPU.

### El problema de la fragmentación

Si reservas memoria del KV cache "por bloques grandes y fijos", surge el mismo
problema que en cualquier sistema: huecos inutilizables. El usuario A reservó sitio
para 4,096 tokens pero solo usa 500 → se desperdicia el resto.

### PagedAttention (la idea de vLLM)

Roba la idea de la memoria virtual de los sistemas operativos: divide el KV cache
en **páginas pequeñas** que se asignan bajo demanda. Resultado: casi cero
desperdicio, más usuarios por GPU, y —bonus— páginas compartidas entre usuarios que
comparten el mismo prefijo de prompt.

---

## 4. Quantization en detalle

### El truco básico, con números

Los pesos originales (FP16: floats de 16 bits) son números como `0.0231`, `-1.4702`.
La cuantización de 8 bits funciona así:

```text
1. Tomo un GRUPO de pesos (ej. 64 valores seguidos)
2. Anoto el máximo y el mínimo del grupo
3. Guardo: cada peso como entero 0-255 + UN factor de escala para todo el grupo
   peso_real ≈ escala × entero
```

Ejemplo: grupo con mínimo -0.04 y máximo 0.04, escala = 0.04/127 ≈ 0.0003.
El peso `0.0231` se guarda como el entero `77`. Al usarlo, 77 × 0.0003 ≈ 0.0231.
Error máximo: ±0.0003. Para casi todo uso, imperceptible.

En 4 bits el grupo tiene solo 16 niveles → error mayor, pero aún usable con
esquemas buenos. Los nombres que viste (`Q4_K_M`) son variantes de cómo se agrupan
y escalan los bloques en el formato GGUF (el formato de archivo de llama.cpp/Ollama).

### Los formatos que verás en el mercado

- **GGUF**: formato de archivo cuantizado (ecosistema llama.cpp/Ollama). Tu mundo Mac.
- **GPTQ / AWQ**: técnicas de cuantización para GPUs NVIDIA, usadas por vLLM.
- **FP8**: cuantización "de fábrica" en GPUs modernas (H100+); los modelos nuevos
  cada vez se publican ya en FP8.

### Dónde se rompe (lo que vas a medir en la Lección 4)

| Quant | 7B pesa | Calidad típica | Uso sensato |
|---|---:|---|---|
| FP16 | 14 GB | referencia | servir con GPU grande |
| Q8 | ~8 GB | casi idéntica | producción con margen |
| Q4 | ~4.7 GB | pequeña caída | el caballo de batalla |
| Q2 | ~3 GB | caída visible | hardware mínimo, tareas fáciles |

Regla de oro: **la calidad se mide con TU workload, no se asume**. Un resumen
tolera 4-bit; generar código complejo quizás no.

---

## 5. Speculative decoding (decodificación especulativa)

La cadena autoregresiva no se puede paralelizar… ¿o sí? El truco:

```text
1. Un modelo PEQUEÑO (rápido) redacta 5 tokens candidatos
2. El modelo GRANDE verifica los 5 en UNA sola pasada (verificar es paralelo)
3. Los que coinciden con lo que el grande habría dicho: se aceptan
   Los que no: se descartan y el grande corrige desde ahí
```

Ejemplo: el chico propone 5, el grande acepta 3 → produjiste 3 tokens con 1 pasada
en vez de 3. Aceptación típica 50-80% → aceleración real, sin perder calidad
(porque el grande siempre tiene la última palabra).

Pagas con: memoria extra (dos modelos) y variabilidad (si el chico acierta poco,
hasta puede ir más lento). Por eso se activa/desactiva según el caso.

---

## 6. Optimizaciones del prefill

### Prefix caching (cache de prefijo)

Si 10,000 peticiones empiezan con el MISMO system prompt de 2,000 tokens, ¿por qué
recalcularlo cada vez? Se procesa UNA vez, sus vectores del KV cache se guardan, y
cada petición nueva empieza desde el token 2,001. Tu primer curl ya mostró esto:
`prompt_eval_cached_count: 24` — Ollama cacheando el prefijo de la plantilla.

**Cómo funciona de verdad (por prefijo, no por turno):**

```text
Turno 1: [500 tokens]        → procesa 500 (62 ms) → guarda "prefijo 500"
Turno 2: [500 + 15,500 nuevos] → HIT del prefijo → procesa solo los NUEVOS (1.9 s)
Turno 3: [16,000 + 500 nuevos] → HIT del prefijo → procesa solo 500 (62 ms)
```

El prompt de cada turno agéntico = todo lo anterior + un apéndice. Solo el apéndice
se procesa. Condiciones para el HIT: prefijo idéntico token a token (por eso el
system prompt y las tools deben ser estables y la historia append-only) y que el
cache siga vivo (Anthropic ~5 min; vLLM hasta que LRU expulse). El cache brilla
cuando el prefijo acumulado es gigante: reenviar 32K y pagar 500 nuevos.

### Chunked prefill (prefill por trozos)

Un prompt de 100K tokens procesado de golpe bloquearía a todos los demás usuarios
durante segundos. Solución: procesarlo por trozos intercalando decodes de otros
usuarios. Nada lo evita, pero nadie sufre un bloqueo completo.

---

## 7. Cómo se decide todo: el triángulo y las promesas de servicio

Toda decisión de serving vive en un triángulo:

```text
        CALIDAD
       /       \
  LATENCIA — COSTO
```

Ejemplos con tu hardware:
- ¿Chat interno tolerante? → Q4, batch agresivo, contexto justos: mínimo costo.
- ¿Agente de código? → mejor quant (Q8), contexto 32K, prefix caching: más costo.
- ¿Miles de usuarios? → continuous batching + PagedAttention: throughput ante todo.

Las decisiones se escriben como **SLO** (Service Level Objective = objetivo medible
de servicio), por ejemplo:

```text
TTFT p90  < 500 ms
TPOT p90  < 30 ms   (≈ 33 tok/s mínimos percibidos)
Errores   < 0.1%
Costo     < $X por 1M tokens
```

Si el sistema no cumple el SLO, no importa cuán elegante sea la infraestructura:
falló. Si los cumple con margen sobrado, probablemente estés pagando hardware de más.
El inference engineering es mantener ese equilibrio con datos, no con fe.

---

## Glosario de siglas

| Sigla | Significado | En una frase |
|---|---|---|
| LLM | Large Language Model | Modelo de lenguaje grande |
| API | Application Programming Interface | La "ventanilla" HTTP por la que hablas al modelo |
| HTTP | HyperText Transfer Protocol | El protocolo de la web |
| JSON | JavaScript Object Notation | Formato de texto estructurado que viaja en las APIs |
| GPU | Graphics Processing Unit | Procesador masivamente paralelo |
| VRAM | Video RAM | La memoria de la GPU |
| RAM | Random Access Memory | Memoria del sistema |
| TTFT | Time To First Token | Espera hasta la primera palabra |
| TPOT | Time Per Output Token | Tiempo promedio por token generado |
| p50/p90/p99 | Percentiles | El punto por debajo del cual cae el 50/90/99% de las peticiones |
| KV cache | Key-Value cache | Memoria de trabajo por token procesado |
| FP16/BF16 | Floating Point 16 / Brain Float 16 | Números decimales de 16 bits |
| INT8/INT4 | Integer 8/4 bits | Enteros de 8/4 bits (cuantización) |
| GGUF | GPT-Generated Unified Format | Formato de archivo de modelos cuantizados (llama.cpp/Ollama) |
| Q4_K_M | variante de cuantización 4-bit | Nombra cómo se agrupan/escalan los bloques |
| GPTQ/AWQ | técnicas de cuantización para GPU | Compresión post-entrenamiento |
| SLO | Service Level Objective | Promesa medible de servicio (percentiles, errores) |
| Batching | (inglés: lote) | Procesar varias peticiones por pasada |

## Auto-evaluación (respóndeme cuando termines de leer)

1. ¿Por qué el batching multiplica el throughput pero apenas el costo?
2. Tu servidor atiende 5 usuarios: ¿qué recurso se agota primero, velocidad o memoria? ¿Por qué?
3. Si tu p50 de TTFT es 200 ms y tu p99 es 6 s, ¿qué le dirías al cliente que se queja "a veces va lento"?
4. ¿Por qué el speculative decoding NO degrada la calidad aunque use un modelo pequeño?
5. Un cliente quiere contexto de 128K para 50 usuarios simultáneos. ¿Cuál es tu primera preocupación como proveedor?

## Respuestas modelo (para repaso)

**1. Batching: porque lo caro es entregar el libro, y el libro ya está en la mesa.**
Lo costoso de cada pasada es leer TODOS los pesos (el camión entregando 4.7 GB). Ese costo es fijo por pasada, venga 1 usuario o 20. Con batch de 20, la MISMA pasada produce 20 tokens (uno por usuario). El costo extra por usuario es pequeño: unos cálculos más (los núcleos estaban ociosos) y su KV cache. Resultado: throughput ×20, costo por token ÷20. Por eso las APIs comerciales pueden cobrar centavos: miles de usuarios comparten el mismo camión.

**2. Memoria — degrada suave y corta duro.**
Con más usuarios, la velocidad por usuario cae poco a poco (TPOT sube levemente: más KV cache que consultar por pasada). Pero la memoria del KV cache crece LINEAL con usuarios × contexto, y cuando se llena la VRAM, el servidor debe poner usuarios en cola o rechazarlos: límite duro, no degradación. Velocidad = degradación gradual; memoria = muro. El tamaño del servidor lo fija la memoria.

**3. Primero validar con datos, luego perseguir la cola.**
"Tienes razón, y los datos lo confirman: la mitad de las peticiones va en 200 ms, pero el 1% más lento espera 6 segundos. No es tu percepción: es nuestra cola." Después, ingeniería: el promedio esconde exactamente lo que él siente. Causas típicas de la cola: cold starts (modelo descargado), horas pico con cola de admisión, prompts gigantes bloqueando. Fixes: modelo residente (keep_alive), prefix caching, chunked prefill, scheduling. Nunca discutas una queja de usuario con el promedio: su queja ES el p99.

**4. Porque el pequeño solo PROPONE; el grande tiene la última palabra.**
El modelo grande verifica cada token propuesto contra SU PROPIA distribución en una pasada paralela; lo que no habría dicho, lo rechaza y lo regenera él mismo. El output final es, por construcción, el mismo que habría producido solo. El asistente redacta borradores; el jefe firma línea por línea y reescribe lo que no le gusta. La carta final siempre es del jefe — solo llega antes.

**5. Memoria — específicamente el KV cache.**
El KV cache pesa decenas de KB por token por usuario. Aproximación para un 7B: ~56 KB/token → 128K tokens ≈ 7 GB POR USUARIO → 50 usuarios ≈ 350 GB solo de cache (antes de los pesos). Ni una H100 (80 GB) lo sostiene. Como proveedor: o multiplicas GPUs (costo brutal), o reduces contexto, o cambias la estrategia del cliente por RAG (mandar solo lo relevante). La pregunta profesional es "¿de verdad necesitas 128K × 50 simultáneos?", no "¿qué GPU compro?".

**6. (Pendiente de la escalera) ¿Por qué cuantizar acelera?**
Porque el decode está limitado por ENTREGA de bytes, no por cálculo. Menos bytes por peso → menos que entregar por pasada → la pasada termina antes → más pasadas (tokens) por segundo con el mismo camión. Y de regalo: sobra memoria para KV cache de más usuarios. No es que la matemática sea "más fácil": es que se mueven menos GB.

