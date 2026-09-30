# Plan técnico y de negocio — Inferencia self-hosted para 30 ingenieros

> Documento de referencia. Todo lo que hay que decidir, dimensionar y probar para
> reemplazar (parcialmente) la suscripción de Claude por modelos open-source servidos
> por nosotros.
>
> Convención: los conceptos técnicos van explicados entre paréntesis la primera vez.
> Los números son órdenes de magnitud calculados con supuestos explícitos — la Fase de
> pruebas (sección 10) existe precisamente para convertir estimaciones en mediciones.

---

## 0. Resumen ejecutivo (1 pantalla)

```text
HOY:   30 ingenieros usan Claude Code con modelos Opus/Sonnet.
       ~$200 por asiento → $6,000/mes.
       Consumo real medido: ~190,000 millones (190B) de tokens/mes,
       de los cuales el 97% son RE-LECTURAS de contexto (cache reads).

PROPUESTA: servir la mayoría del tráfico con modelos open-source en GPUs propias
       (rentadas), detrás de un gateway (puerta de entrada con control de acceso,
       presupuestos y métricas), usando opencode como herramienta de los ingenieros.

POR QUÉ FUNCIONA ECONÓMICAMENTE: en self-hosting, re-leer contexto que ya está en
       RAM (prefix caching) cuesta CERO, porque es memoria propia reutilizándose.
       Anthropic cobra cada re-lectura; nuestra GPU la regala.

COSTO ESTIMADO: $3,000–4,800/mes (infra + operaciones) vs $6,000/mes actual.
       El ahorro crece con cada ingeniero nuevo (los asientos crecen lineal;
       las GPUs, sublineal). Punto de equilibrio: ~40–60 ingenieros.

APUESTA PRINCIPAL Y SU RIESGO: los modelos open NO igualan a Opus en las tareas
       más duras → arquitectura híbrida (open para el 70-80% del tráfico,
       Claude como fallback). La calidad se valida con benchmark ANTES de comprar.
```

---

## 1. Lo que sabemos (datos reales, no supuestos)

De las estadísticas de Claude Code de 4 ingenieros (últimos 7-8 días):

| Métrica | Por ingeniero/semana | 30 ingenieros/mes |
|---|---:|---:|
| Cache read (re-lecturas de contexto) | ~1.45B | **~187B** |
| Cache write (contexto nuevo procesado) | ~29M | ~3.8B |
| Output (tokens generados) | ~3.4M | ~440M |
| Input sin cache | ~8K (despreciable) | ~0.3B |
| **Total** | **~1.5B** | **~192B** |

Otros hechos:
- Sesiones agénticas de LARGA duración (3-5 días corriendo).
- Horario pico: 9:00-18:00, horas de trabajo (8h fuertes, disponible 24/7).
- Pago actual: por asiento (~$200/ingeniero/mes → $6,000/mes).
- Modelos actuales: Opus 5 (los más exigentes) y Sonnet 5.

---

## 2. El workload explicado (por qué este documento dimensiona lo que dimensiona)

Una sesión agéntica (Claude Code / opencode) funciona así:

```text
Turno 1: envía contexto (archivos del repo + instrucciones) → modelo responde
Turno 2: MISMO contexto + resultado del paso anterior → modelo responde
Turno 3: MISMO contexto + más resultados → ...
...cientos de turnos, durante días
```

Cada turno re-envía TODO el contexto anterior. Por eso:

- El 97% del tráfico es "re-lectura" de lo mismo.
- La factura de Anthropic es, en esencia, **cobrar por recordar**.
- En self-hosting, ese recuerdo vive en RAM (KV cache — la memoria de trabajo del
  modelo por cada token procesado). Re-usarla se llama **prefix caching** y cuesta cero.

**Consecuencia de diseño número 1:** el hardware se dimensiona por MEMORIA (cuántos
tokens de contexto caben vivos a la vez), no por velocidad de cómputo.

**Consecuencia de diseño número 2:** el mayor riesgo operativo son las sesiones que
crecen sin límite (una sesión de 5 días puede acumular cientos de miles de tokens de
contexto). Necesitamos una **política de contexto** (sección 5.4) — igual que Claude
tiene la suya.

---

## 3. Requisitos (las respuestas directas a tus preguntas)

### 3.1 Tokens soportados por usuario

```text
Diseño por usuario (con 30% de margen sobre lo medido):
  Cache read:   ~8B tokens/mes
  Cache write:  ~170M tokens/mes
  Output:       ~20M tokens/mes
Límite blando (soft quota) por asiento en el gateway: 10B tokens/mes
  → si alguien lo supera, no se corta: se avisa y se revisa (probable sesión mal hecha)
```

### 3.2 Tiempo disponible de la API

```text
Objetivo de disponibilidad: 99.5% en horario laboral (≈ 1 hora de caída/mes)
Disponibilidad física: 24/7 (los agentes corren de noche y los fines de semana)
Mantenimiento: ventanas acordadas fuera de horario laboral.
Cómo se logra: 2 réplicas idénticas (si una cae, la otra absorbe — esquema "N+1").
```

### 3.3 Capacidad de prompt y output

```text
Ventana de contexto máxima por petición: 64K tokens (el modelo soporta más;
  lo limitamos por memoria — ver 5.4)
Contexto típico de trabajo (política del harness): 16–32K tokens
Output máximo por petición: 8K tokens (configurable; el 99% de las respuestas
  agénticas termina antes por sí solo)
Nota honesta: Claude Code hoy usa contextos de 200K+. Con nuestros modelos,
  el harness debe COMPACTAR (resumir/recortar el contexto cuando crece).
  opencode hace esto; es un requisito, no un extra.
```

### 3.4 Tiempos de respuesta (SLO — Service Level Objective: promesa medible)

| Escenario | Objetivo |
|---|---|
| TTFT p50 (mediana) — turno con cache hit | **< 500 ms** |
| TTFT p90 — 1 de cada 10 peticiones | **< 1.5 s** |
| Turno "frío" (contexto nuevo de 32K, sin cache) | 2–6 s de prefill (procesar el prompt) |
| Velocidad de generación por usuario (con 30 concurrentes) | **40–80 tok/s** (leer código en pantalla: fluido; un humano lee ~10) |
| Cola en hora pico | ocasional, 1–3 s (lo absorbe el p90) |

Para referencia: hoy con Claude Code los turnos tardan 1–4 s en arrancar cuando el
contexto es grande. Nuestros objetivos son equivalentes en percepción.

### 3.5 Concurrencia: ¿fluido si los 30 trabajan a la vez?

**Sí, con los números así** (detallados en sección 5). Resumen:

- 30 sesiones concurrentes de ≤32K tokens de contexto caben en 2 nodos de 96 GB.
- A las 8-10 sesiones por nodo la velocidad por usuario es ~80 tok/s; con 15 por
  nodo baja a ~40-60 tok/s. Ambos casos fluidos para trabajo con agentes.
- Si todos mandan contextos de 64K en el mismo minuto: hay cola breve (1-3 s).
  El p90 lo cubre. Si eso fuera frecuente, se agrega un tercer nodo.

---

## 4. El modelo: cuál usamos y por qué

### Decisión: **Qwen3-Coder-30B-A3B** (Instruct, FP8)

(Qwen3-Coder es la familia de Alibaba enfocada en código; "30B-A3B" significa 30
mil millones de parámetros TOTALES pero solo ~3B ACTIVOS por token — es un MoE,
Mixture of Experts: un modelo con muchos "expertos" internos de los cuales solo
algunos trabajan en cada token. Resultado: calidad de modelo grande, velocidad de
modelo chico. FP8 = pesos guardados con números de 8 bits, mitad de memoria que el
estándar de 16 bits, con pérdida de calidad casi nula en GPUs modernas.)

Por qué este:
1. **Enfocado en código y agentes** (entrenado específicamente para tool calling —
   usar herramientas como el harness le pide).
2. **Velocidad de 7B con calidad de 32B** gracias al MoE: en el decode, mover los
   pesos activos (~3 GB) por pasada, no los 30 GB completos. La ley
   `tok/s ≈ bandwidth / bytes activos` juega a nuestro favor.
3. **Licencia Apache 2.0** (uso comercial libre, sin regalías).
4. Cabe 2 veces en un nodo de 96 GB dejando room para el KV cache.

### Alternativas honestas (y cuándo usarlas)

| Modelo | Tamaño | Pros | Contras | Cuándo |
|---|---|---|---|---|
| Qwen3-Coder-30B-A3B | 30B MoE | rápido, barato, agéntico | no iguala a Opus en tareas duras | **primary (este plan)** |
| GLM-4.5-Air / GLM-4.6 | 106B+ MoE | calidad cercana a Sonnet en código | necesita 2-4 GPUs por réplica; costo ×2-3 | fase 2 si el benchmark exige más |
| Qwen2.5-Coder-32B | 32B denso | muy probado en código | denso = 4x más lento en decode | no recomendado hoy |
| DeepSeek-V3 / Qwen3-235B | 235B+ | calidad top open-source | multi-nodo, $$$ | otro negocio |

### La verdad incómoda (que el plan asume)

Ningún modelo open de este tamaño iguala a **Opus 5** en las tareas más duras de
ingeniería. Por eso la arquitectura es **híbrida**: el gateway enruta lo rutinario al
modelo open (la mayoría del volumen) y lo difícil a Claude (el resto). El benchmark
(sección 10) define qué porcentaje puede ir a cada lado.

---

## 5. Capacidad y concurrencia: la matemática

### 5.1 Memoria por nodo (la parte que dimensiona todo)

Nodo = 2 GPUs de 48 GB (L40S — ver sección 6) = **96 GB**:

```text
Pesos del modelo (FP8):        ~31 GB   (divididos entre las 2 GPUs)
Reserva del sistema/activos:   ~10 GB
PRESUPUESTO PARA KV CACHE:     ~55 GB
```

El KV cache pesa ~48 KB por token (con KV en FP8 — técnica que comprime también la
memoria de contexto a la mitad, con costo de calidad mínimo):

```text
55 GB ÷ 48 KB/token ≈ 1.15 MILLONES de tokens de contexto vivos por nodo
```

### 5.2 Los 30 concurrentes

```text
2 nodos × 1.15M tokens   = 2.3M tokens de contexto vivos en el sistema
30 sesiones × 32K tokens  = 0.96M tokens   → sobra 2.4x de margen
30 sesiones × 64K tokens  = 1.92M tokens   → cabe, sin margen para picos
```

Conclusión: **30 ingenieros simultáneos con contextos de 16-32K es fluido y cómodo**.
Con contextos de 64K sostenidos empiezan colas ocasionales → señal para crecer.

### 5.3 Velocidad por usuario (decode)

Cada token generado requiere leer los pesos activos (~3 GB en FP8) + el KV cache de
esa sesión. Con 15 sesiones por nodo y contextos de 32K:

```text
Lectura por pasada:  ~3 GB pesos + 15 × 32K × 48 KB ≈ 26 GB
Ancho de banda del nodo: 2 × 864 GB/s
Pasada completa: ~15 ms → produce 15 tokens (uno por sesión)
→ ~55 tok/s por usuario. Con 8 sesiones por nodo: ~90 tok/s.
```

Ambos casos muy por encima del umbral de fluidez (~20-30 tok/s).

### 5.4 La política de contexto (decisión de diseño clave)

Las sesiones agénticas crecen sin techo. Reglas del sistema:

```text
1. El harness (opencode) COMPACTA: cuando el contexto pasa de ~32K,
   resume/recorta lo viejo (igual hace Claude internamente).
2. max-model-len = 64K en el servidor (límite duro barato).
3. El gateway registra contexto por sesión → visibilidad de quién abusa.
```

Sin esta política, el KV cache se desborda y la caída de rendimiento es brusca
(no gradual). Esta decisión vale tanto como cualquier GPU.

### 5.5 Throughput agregado (validación contra el consumo real)

```text
Output: 440M tokens/mes ÷ 176 h laborales ≈ 700 tok/s promedio
        pico (~3-4x): 2,000-3,000 tok/s
        Capacidad de 2 nodos con batch: 1,500-4,000 tok/s  → CUBRE, con ajuste en picos

Prefill (contexto nuevo): 3.8B tokens/mes ≈ 6,000 tok/s promedio
        Con prefix caching, la mayor parte del "cache read" NO se reprocesa.
        Los misses (evicción de cache) agregan carga: asumir 2x → 12,000 tok/s promedio.
        Capacidad de prefill por nodo: ~15-30K tok/s  → CUBRE promedio; picos encolan 1-3 s
```

**Veredicto: 2 nodos sostienen el workload con margen moderado.** Las horas pico con
todos los ingenieros lanzando agentes grandes a la vez son el escenario límite — y el
motivo de tener (en el futuro) un tercer nodo elástico.

---

## 6. Arquitectura

### 6.1 Diagrama

```text
                    30 INGENIEROS (laptops, oficina/VPN)
                              │  opencode (harness CLI)
                              ▼
                 ┌────────────────────────────┐
                 │      GATEWAY (LiteLLM)     │   ← 1 VM pequeña (4-8 GB RAM)
                 │  llaves por persona        │   + Postgres (base de datos del
                 │  presupuestos, quotas      │     gateway: keys, budgets y
                 │  ruteo + fallback          │     registro de gasto por usuario)
                 │  logs de costo             │   + UI de administración (/ui):
                 │  UI de administración      │     crear keys, ver consumo y
                 └───────┬───────────┬────────┘     costos por persona en $
                         │           │
            ┌────────────▼───┐   ┌───▼────────────┐        ┌─────────────────┐
            │  NODO A        │   │  NODO B        │        │  Claude API     │
            │  2× L40S 48GB  │   │  2× L40S 48GB  │        │  (fallback para │
            │  vLLM + modelo │   │  vLLM + modelo │        │   tareas duras) │
            │  residente     │   │  residente     │        └─────────────────┘
            └────────────────┘   └────────────────┘
                         │           │
                 ┌───────▼───────────▼────────┐
                 │  OBSERVABILIDAD            │   ← 1 VM pequeña
                 │  Prometheus + Grafana      │
                 │  (métricas, dashboards)    │
                 └────────────────────────────┘
```

### 6.2 Cuántas GPUs y dónde

```text
4× NVIDIA L40S de 48 GB, en 2 nodos de 2 GPUs (tensor parallel 2 por nodo —
  técnica para repartir UN modelo entre varias GPUs del mismo servidor)

Alojamiento recomendado para el PoC: cloud GPU bajo demanda/reservado
  (proveedores: RunPod, Vast.ai, Lambda, Hetzner dedicated — NO hace falta
  AWS/GCP y su sobreprecio; la red del proveedor da acceso por VPN a la oficina)
  Región: la más cercana a la oficina (latencia de red < 30 ms)

Costo L40S: ~$550–900/GPU-mes reservada → 4 GPUs ≈ $2,200–3,600/mes
  + 2 VMs pequeñas (gateway, observabilidad) ≈ $50–100/mes
  + storage (pesos del modelo, ~60 GB por nodo) ≈ $20/mes

Alternativa futura: hardware propio on-prem (capex ~$25-35K por nodo) — solo si
  privacidad/finance lo pide. Para el PoC, renting: cero compra, cancelable.
```

Por qué L40S y no H100: el workload es **memory-bound** (ancho de banda de memoria y
GB de VRAM manda), no compute-bound. La L40S da 48 GB y 864 GB/s a 1/3 del precio de
una H100. Con MoE de 3B activos, la H100 estaría ociosa la mayor parte del tiempo.
(El día que subamos a modelos de 100B+, ahí sí hablamos de H100/B200.)

### 6.3 Alta disponibilidad

- 2 nodos idénticos detrás del gateway: si uno cae, el otro sirve a los 30 con
  ~la mitad de velocidad (degradación elegante, no apagón).
- Los pesos del modelo viven en un volumen compartido/réplica (60 GB, se restauran
  en minutos — no son datos: se re-descargan de Hugging Face si hace falta).
- Health checks: el gateway saca del ruteo cualquier nodo que no responda.

---

## 7. El stack de software (qué programa hace qué)

| Pieza | Rol | Por qué esa |
|---|---|---|
| **vLLM** | El motor: carga el modelo y lo sirve como API OpenAI-compatible. Continuous batching (atender a todos en cada pasada), prefix caching (re-usar KV de prefijos repetidos), métricas integradas | El estándar de la industria open-source; es el que aprenderás en el curriculum |
| **Docker** (+ NVIDIA Container Toolkit) | Empaquetar vLLM con todo (CUDA incluido) en un contenedor que corre en cualquier GPU host | Instalar CUDA a mano es un infierno; Docker lo borra |
| **LiteLLM** | Gateway: una API para los ingenieros que por detrás habla con vLLM y con Claude. Llaves por persona, presupuestos, ruteo por modelo, fallback automático, registro de costo por request, y **UI de administración** (crear keys, ver gasto por usuario en $) | Es la pieza que hace el sistema gestionable y es el "producto" que venderías |
| **Postgres** | Base de datos del gateway: donde viven las API keys, presupuestos y el registro de consumo por usuario | Sin DB, LiteLLM enruta pero no persiste nada: la UI y los presupuestos la exigen |
| **opencode** | El harness (herramienta CLI agéntica) que usan los ingenieros en su terminal. Apunta al gateway | Modelo-agnóstico (no queda amarrado a un proveedor), open-source, y ya lo conoces por dentro |
| **Prometheus + Grafana** (+ DCGM exporter para métricas de GPU) | Observabilidad: TTFT, tok/s, cola, uso de KV cache, temperatura/utilización de GPU — en dashboards | Sin esto, operas a ciegas. vLLM expone `/metrics` listo para Prometheus |
| **Git + compose files** | Todo el despliegue como código en un repo (docker-compose por nodo, configs del gateway, runbook de operación) | El día que un nodo muere, se levanta otro con `docker compose up` |
| Opcional: **Langfuse** | Trazas de conversaciones LLM (qué sesión, cuántos tokens, qué modelo) | Útil para el cost model por persona; se agrega en fase 2 |

### Lo que explícitamente NO necesitamos (día 1)

```text
✗ Kubernetes          → 2 nodos estáticos: docker-compose alcanza. K8s entra si
                        crecemos a 6+ nodos o queremos autoscaling real.
✗ Programación CUDA   → vLLM ya optimiza por nosotros.
✗ Multi-node inference→ cada nodo sirve el modelo completo; no repartimos un modelo
                        entre servidores (eso es Track C del curriculum).
✗ Fine-tuning         → los modelos van "de fábrica". Nunca digas "entrenaremos uno":
                        es otro proyecto, otro presupuesto, otro equipo.
```

---

## 8. Costos (la tabla para el equipo)

### Mensual propuesto

```text
4× L40S (2 nodos, reservadas)          $2,200 – 3,600
2 VMs pequeñas (gateway + obs)         $50 – 100
Storage/modelos/red                    $50
Operación (25% del tiempo de un ing)   $800 – 1,000
Claude fallback (10-20% del tráfico)   $600 – 1,200
────────────────────────────────────────────────
TOTAL                                  ≈ $3,700 – 6,000/mes
```

### Comparación honesta

| Escenario | Costo/mes | Nota |
|---|---|---|
| Hoy: 30 asientos Claude | $6,000 | crece lineal con cada ingeniero |
| Propuesto (30 ings) | $3,700–6,000 | ahorro realista 0–40% — NO prometas 50% a 30 ingenieros |
| Mismo sistema con 60 ings | ~$5,000–7,000 | las GPUs ya amortizan; ahorro ~40-55% |
| Con 100 ings | ~$7,000–9,000 | ahorro ~55-65%; ahí el negocio es evidente |

**La métrica que importa: el costo por ingeniero baja de $200 fijos a ~$120-200 hoy,
y sigue bajando al crecer.** El argumento fuerte HOY no es solo ahorro: es
privacidad (el código no sale de la infraestructura), control (sin lock-in de
proveedor), y curva de costo decreciente vs lineal.

**Regla del curriculum (sección 23 del roadmap): si los números dicen "no conviene
aún", el proyecto sigue siendo un éxito — es evidencia para no invertir.** Con 30
ingenieros el caso es marginal; con 60, claro. El PoC sirve para saber en qué lado
del punto de equilibrio está esta empresa Y para construir la capacidad que la
escala convertirá en rentable.

---

## 9. Riesgos y mitigaciones

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| El modelo open falla tareas críticas de código | ALTA (es un hecho, no un riesgo) | Híbrido: ruteo a Claude para lo que el benchmark repruebe |
| Sesiones crecen y desbordan el KV cache | MEDIA | Política de contexto + compactación del harness (5.4) |
| Los ingenieros rechazan cambiar de herramienta | MEDIA | Piloto voluntario; opencode es familiar; medir satisfacción |
| Pico simultáneo de 30 agentes con contexto grande | MEDIA | Cola con SLO p90; tercer nodo elástico on-demand (~$1/h) |
| Operación mal hecha (nadie lo mantiene) | MEDIA-ALTA | Runbook, dashboards, alertas, dueño designado del sistema |
| vLLM/modelo tiene bug con tool calling del harness | BAJA-MEDIA | El benchmark lo detecta antes del piloto; versiones fijadas (pin) |
| Proveedor de GPU sube precios / cae | BAJA | Compatibilidad OpenAI-API: migrar de proveedor = cambiar una URL |

---

## 10. Cómo probarlo TÚ (de la Mac al PoC, en 4 tiers)

### Tier 0 — Esta semana, en tu Mac, $0

Ya tienes el 80%: Ollama, benchmark.py, medición de calidad.

```bash
# 1. El modelo candidato, corriendo local (cabe sobrado en tus 128 GB)
ollama pull qwen3-coder:30b     # verificar el tag exacto en ollama.com/library

# 2. Tu benchmark.py contra él (mismo CSV, misma metodología)
python benchmark.py --model qwen3-coder:30b --prompt "..." --out results_qwen3coder.csv

# 3. Armar el dataset de evaluación: 20-50 tareas REALES de tus ingenieros
#    (un refactor, un bug, un review, extraer datos, generar tests...)
#    Formato: {"input": "...", "expected_behavior": "...", "dificultad": 1-3}
```

Qué validas aquí: **calidad** (¿el modelo resuelve tareas reales?) y fluidez básica.
Qué NO validas: concurrencia ni latencia de servidor (tu Mac no es un nodo de serving).

### Tier 1 — Una tarde, $10-30: el nodo real alquilado

Alquilas UNA L40S por hora (RunPod, Vast.ai o Lambda; ~$0.70-1.00/h) y levantas el
servidor EXACTO del plan:

```bash
# En el host con GPU (el proveedor ya da la imagen con CUDA/Docker):
docker run --gpus all -p 8000:8000 \
  vllm/vllm-openai:latest \
  --model Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.92 \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching
# Espera ~5-10 min: descarga el modelo (~30 GB) y lo carga.

# Prueba rápida:
curl http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8",
       "messages":[{"role":"user","content":"Hola"}]}'
```

Luego, el test que valida TODO el plan: **script de carga con 30 peticiones
simultáneas de contexto largo** (16-32K) midiendo TTFT, tok/s y cola. Tu benchmark.py
se adapta en 30 líneas (el endpoint cambia de Ollama a `/v1/chat/completions` — te lo
escribo cuando lleguemos aquí). Repites a concurrencia 1, 5, 10, 20, 30 y comparas
contra la tabla de la sección 3.4.

```text
CHECKLIST TIER 1 (tarde completa):
[ ] TTFT p50 < 500 ms con cache hit (mandar el MISMO prompt grande 2 veces:
    la 2ª debe volar — prefix caching en acción)
[ ] 30 concurrentes: todos ≥ 40 tok/s
[ ] Contexto de 64K que entre sin OOM (out of memory — quedarse sin VRAM)
[ ] Sesión de 1 hora corriendo sin degradarse
[ ] /metrics respondiendo (Prometheus lo comerá después)
Costo total: ~$15-30. Si algo falla aquí, el plan se corrige ANTES de gastar más.
```

### Tier 2 — Una semana, $100-300: piloto real

```text
[ ] 2 nodos alquilados + LiteLLM en una VM + opencode configurado al gateway
[ ] 3-5 ingenieros voluntarios trabajan 1 semana SOLO con este sistema
[ ] Cada tarea: rating 1-5 de calidad + "hubiera preferido Claude: sí/no"
[ ] Dashboard de uso real: tokens, TTFT, caídas
[ ] Resultado: el % de tráfico que el open resolvió sin queja
```

### Tier 3 — El PoC completo: 30 usuarios × 2 semanas

Con criterios de éxito definidos ANTES (sección 11). Al terminar, la propuesta se
presenta con datos propios, no con promesas.

---

## 11. Criterios de éxito del PoC (se acuerdan ANTES de empezar)

```text
Calidad:      ≥ 75% de tareas resueltas sin que el ingeniero eche de menos Claude
Latencia:     TTFT p90 < 1.5 s; tok/s por usuario ≥ 40 en horas pico
Disponibilidad: ≥ 99.5% en horario laboral durante las 2 semanas
Adopción:     ≥ 70% de los ingenieros lo usan a diario voluntariamente
Costo:        costo real medido ≤ $5,000/mes proyectado
Híbrido:      el % de tráfico a Claude queda medido y tiene costo acotado
```

Si 3+ criterios fallan → el informe recomienda NO migrar (y eso también vale: evita
gastar $40K/año en algo peor). Si pasan → propuesta de escalar a 60-100 ingenieros.

---

## 12. Glosario de este documento

| Término | Definición corta |
|---|---|
| Cache read / write | Re-leer contexto ya procesado / procesar contexto nuevo (así lo factura Anthropic) |
| KV cache | Memoria de trabajo del modelo: los vectores guardados por cada token procesado |
| Prefix caching | Re-usar el KV cache de un prefijo repetido en vez de recalcularlo. En tu GPU: gratis |
| MoE (Mixture of Experts) | Modelo con muchos expertos internos; solo unos pocos activos por token → velocidad de modelo chico, conocimiento de grande |
| FP8 | Números de 8 bits (mitad de memoria que FP16). En pesos y en KV cache |
| Tensor parallel | Repartir un modelo entre varias GPUs del mismo servidor |
| SLO | Promesa medible de servicio (percentiles, disponibilidad) |
| p50 / p90 | Percentil: punto bajo el cual cae el 50% / 90% de las peticiones |
| TTFT / tok/s | Espera hasta el primer token / velocidad de generación |
| Harness | La herramienta agéntica que orquesta el modelo (opencode, Claude Code) |
| Gateway | Puerta de entrada única: llaves, presupuestos, ruteo entre modelos |
| Compaction | Resumir/recortar el contexto de una sesión cuando crece demasiado |
| OOM | Out Of Memory: quedarse sin VRAM y crashear |
| N+1 | Tener una réplica más de las necesarias, para sobrevivir la caída de una |
| Capex/Opex | Comprar hardware / alquilarlo como servicio |
| LRU eviction | Cuando el KV cache se llena, se expulsa lo menos usado (y se reprocesa si vuelve) |

---

## 13. Checklist de levantamiento completo (resumen de fases)

```text
SEMANA 1-2 (Tier 0, Mac, $0)
  [ ] qwen3-coder corriendo local + benchmark.py adaptado
  [ ] Dataset de 20-50 tareas reales + rúbrica de evaluación
  [ ] Primera tabla de calidad open vs Claude en 10 tareas

SEMANA 3 (Tier 1, ~$30)
  [ ] L40S alquilada + vLLM en Docker corriendo
  [ ] Test de concurrencia 1→30 con contextos de 16-32K
  [ ] Validar checklist TTFT/tok/s/OOM/prefix-caching

SEMANA 4-5 (Tier 2, ~$200)
  [ ] 2 nodos + LiteLLM + opencode + observabilidad
  [ ] Piloto con 3-5 ingenieros, 1 semana, con ratings diarios
  [ ] Ajustes (modelo, quant, política de contexto)

SEMANA 6-7 (Tier 3, PoC completo)
  [ ] 30 usuarios × 2 semanas contra criterios de éxito
  [ ] Informe final: números reales + proyección a 60/100 ingenieros
  [ ] Presentación al equipo con la tabla de la sección 8

TODO el despliegue vive en un repo: compose files, configs, runbook,
dataset, scripts de benchmark y el informe.
```

---

## 14. Preguntas y respuestas del plan (estudio)

**1. ¿Por qué se dimensiona por memoria y no por velocidad de cómputo?**
Porque el 97% del tráfico real es re-lectura de contexto. Servir eso = mantener el KV cache vivo en RAM. El cuello de botella es cuántos tokens de contexto caben simultáneamente en VRAM, no la velocidad de cómputo: un MoE de 3B activos sobra rápido para el decode. Evidencia: 190B tokens/mes, 97% cache read (sección 1).

**2. ¿Cuántas sesiones de 200K caben y qué evita ese desastre?**
200K × 48 KB ≈ 9.6 GB por sesión. Capacidad total: 2.3M tokens → caben solo 11 sesiones así. Una sola sesión monstruo desplaza a ~11 sesiones normales de 32K. Lo evita la POLÍTICA DE CONTEXTO (5.4): el harness compacta a ~32K y el servidor pone techo duro en 64K. Sin eso, unas pocas sesiones despiertan expulsiones (LRU) que fuerzan recálculo para todos.

**3. ¿Por qué MoE 30B-A3B y no denso de 32B?**
La ley del decode: tok/s ≈ bandwidth / bytes leídos por token. Denso 32B FP8 = ~32 GB por pasada. MoE = solo ~3 GB activos por pasada (los demás expertos no trabajan en ese token). ~10x menos bytes movidos → ~10x más rápido, con calidad total de 30B (el conocimiento está todo; solo se consulta selectivamente).

**4. ¿Quién es el competidor real?**
No la API medida de Claude ($76K/mes — nadie la paga a este volumen). Es la SUSCRIPCIÓN por asiento: ~$200 × 30 = $6,000/mes, que es lo que se paga hoy a precio de lista. Toda la propuesta debe vencer ESE número con la misma calidad percibida.

**5. ¿Por qué marginal a 30 y claro a 60?**
El asiento crece LINEAL ($200 × N). El self-hosting es casi todo costo FIJO (GPUs + ops) con crecimiento marginal pequeño. Costo fijo ÷ más usuarios = costo unitario decreciente: ~$130-200/ing a 30, ~$85-115 a 60, ~$70-90 a 100. Punto de equilibrio ~40-60 ingenieros.

**6. ¿Qué hace gratis lo que Anthropic cobra y dónde ocurre?**
El prefix caching de vLLM: el KV cache de los prefijos repetidos permanece en RAM y se reutiliza. Ocurre en la capa de serving (el paso 7 de la cadena — KV cache — y su consulta en cada decode). Anthropic cobra $0.30/M por esa lectura; la nuestra es reutilización de RAM propia: $0.

**7. ¿Qué pasa cuando un nodo muere un martes a las 11 AM?**
El health check del gateway lo detecta en segundos y enruta todo al nodo B. Los ingenieros notan: respuestas algo más lentas (~la mitad de capacidad: ~40 tok/s por usuario, alguna cola de 1-3 s) pero nada se cae y no hay cold starts (el modelo vive residente en B). Por qué no colapsa: esquema N+1 + modelos residentes + health checks.

**8. ¿Por qué gastar $30 en una GPU antes del PoC?**
Porque los números del plan son estimaciones y $30 los convierte en mediciones. Valida: (a) TTFT con prefix caching (la 2ª petición idéntica debe volar), (b) 30 concurrentes a ≥40 tok/s c/u, (c) contexto de 64K sin OOM. Si algo falla, se corrige el plan (GPU mayor, política de contexto, otra quant) ANTES de gastar miles. Es falsación barata: el método científico aplicado al gasto.

**9. Si el modelo open solo resuelve el 40% de las tareas, ¿muere el plan?**
No muere: la arquitectura ya es HÍBRIDA. Con ese dato, el gateway enruta más a Claude (el costo del fallback sube y el caso de negocio se debilita — quizá la respuesta honesta es "todavía no" o "subamos a GLM-4.5-Air"). También se revisa el benchmark: ¿eran todas tareas del nivel más duro? Los criterios de éxito (≥75%) existen para que la decisión go/no-go sea objetiva, no emocional. Y "no migrar todavía" con datos también es un resultado valioso: evita gastar peor.

