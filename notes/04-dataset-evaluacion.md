# Apuntes 04 — Cómo armar el dataset de evaluación (Fase 6)

> El dataset es el activo más valioso del proyecto: sin él, "calidad" es una opinión.
> Con él, es una tabla. Objetivo: 20 tareas esta semana, 40 al final.

## 1. De dónde salen las tareas (3 fuentes, en orden de valor)

1. **Los ingenieros mismos** (fuente principal): pídeles prompts que usaron ESTA
   semana con Claude Code. El workload real define el dataset — no puzzles de entrevista.
2. **Tu historial de sesiones**: tus propias sesiones de Claude Code/opencode tienen
   prompts reales. Reusa y anonimiza (borra nombres de clientes, credenciales, datos
   de negocio).
3. **Casos límite a propósito** (solo 2-3): tareas donde SABES que los modelos chicos
   suelen fallar (refactor grande, código con sintaxis estricta, razonamiento
   multi-paso). Definen dónde va el fallback a Claude.

## 2. La mezcla de categorías (para un dataset de ~40)

| Categoría | Cantidad | Por qué |
|---|---:|---|
| Coding (funciones, bugs, refactors) | 12-15 | Es el 80% de tu workload real |
| Extraction (datos → JSON) | 5 | Determinístico: fácil de calificar |
| Summarization | 4 | Tolerante, útil para modelos chicos |
| Structured output (JSON/schema estricto) | 4 | Falla visible y medible |
| Reasoning (explicar, decidir) | 4 | Mide profundidad |
| Tool calling / agéntico (multi-paso) | 3-4 | El caso de uso real de los ingenieros |
| Long context (preguntar sobre documento de 20K+) | 2-3 | La capacidad que diferencia modelos |

Regla de oro: **la mezcla debe parecerse a tu factura**. Si el 90% de tu uso es
código, no hagas un dataset de poesía.

## 3. Anatomía de una tarea buena

```json
{
  "id": 7,
  "categoria": "coding",
  "dificultad": 2,
  "input": "Esta función React useFetch tiene 3 bugs: no cancela la petición al desmontar, no maneja el error 429 y causa re-render infinito. Encuéntralos y corrígelos: [pegar código]",
  "expected_behavior": "Identifica los 3 bugs, entrega código corregido completo, explica cada fix en una línea. NO inventa bugs que no existen."
}
```

Reglas:

- **Calificable en 30 segundos** por un humano: correcto (2) / parcial (1) / incorrecto (0).
- **`expected_behavior` específico**: "código correcto" no sirve; "identifica los 3
  bugs y no inventa otros" sí.
- **Dificultad 1-3 honesta**: 1 = lo resuelve cualquier modelo; 3 = solo los buenos.
  Sin difíciles, tu dataset aprobará todo y no distinguirá nada.
- **Contexto autocontenido**: la tarea debe incluir TODO lo que el modelo necesita.
- **2-3 tareas con trampa conocida**: ej. un bug sutil que solo un modelo atento ve.

## 4. El mensaje para tus ingenieros (cópialo)

> Estoy evaluando si podemos correr modelos open-source localmente para reducir el
> costo de Claude. Necesito que me manden 2-3 prompts REALES que hayan usado con
> Claude Code esta semana — los de su día a día, no retos de entrevista. Si el prompt
> incluye código de la empresa, anonimicenlo (nombres, credenciales, datos de
> clientes). Con eso armo el benchmark que decide si vale la pena el proyecto.

## 5. Cómo se califica (el proceso)

```text
1. Cada tarea se corre por cada modelo (mismo prompt, temperature 0 para comparar)
2. TÚ calificas a ciegas (no mires qué modelo respondió: mezcla las respuestas)
   0 = incorrecto o inútil
   1 = parcialmente correcto (resuelve la mitad, o con errores que un dev arregla rápido)
   2 = correcto, listo para usar
3. Tabla final: score por modelo = (suma de puntos) / (máximo posible)
4. Las tareas de dificultad 3 definen el % de fallback a Claude
```

Extras baratos y objetivos (cuando aplique): ¿el JSON parsea? ¿el código corre?
¿compila? — la máquina califica eso antes que tú.

## 6. Errores que arruinan un dataset

- **Tareas triviales**: si todo scorea 100%, no sabes nada. Incluye dificultad.
- **Tareas ambiguas**: si TÚ no sabes cuál es la respuesta correcta, no puedes calificar.
- **Dataset de un solo tipo**: 40 tareas de "escribe una función" no representan nada.
- **Sesgo de favoritismo**: calificar sabiendo qué modelo es. A ciegas, siempre.
- **Un solo intento**: corre 2-3 veces las tareas clave (sampling ≠ determinista) y
  promedia. Ya lo viviste: 474 vs 589 tokens en el mismo prompt.

## 7. Tu plan concreto

```text
Hoy:      escribir el mensaje a los ingenieros y enviarlo
Esta semana: juntar 15-20 tareas reales + las 2-3 trampas
Semana 2: completar 40, calificar qwen3-coder vs qwen2.5:7b vs (opcional) Claude
Entrega:  tabla de evaluación v1 → insumo directo del informe para el equipo
```

El runner (script que ejecuta el JSONL contra cada modelo y arma la tabla) te lo
escribo cuando el dataset tenga sus primeras 10 tareas — no antes: primero los datos,
después la herramienta.
