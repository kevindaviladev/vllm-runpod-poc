# Modelos de IA propios para el equipo de ingeniería — Resultados de la prueba

**Para:** stakeholders del equipo
**De:** Kevin Dávila
**Fecha:** 25 de septiembre de 2026
**Estado:** prueba técnica terminada, calidad pendiente de medir

---

## En una página

Durante dos días levantamos un modelo de IA para código, de código abierto, en una
GPU alquilada. Delante pusimos un gateway que da una llave de acceso a cada persona
y registra todo el uso. Dos ingenieros lo usaron con opencode desde Mac y Windows
para trabajo real.

**Lo que funcionó:**

- Una GPU de **$796/mes** atiende a unas **10 personas trabajando a la vez**, con
  respuestas fluidas y sin un solo error en todas las pruebas.
- El **87% del tráfico real fue re-lectura de contexto**. Es justo lo que Anthropic
  cobra una y otra vez; en nuestra GPU no cuesta nada. La idea central del proyecto
  queda confirmada con datos propios.
- El gateway nos da algo que hoy no tenemos con Claude: **saber quién usa qué,
  cuánto y con qué resultado**, y poder dar o quitar acceso en segundos.

**Lo que todavía no sabemos:** si la calidad del modelo alcanza para el trabajo
diario. Es la pregunta más importante y esta prueba no la contesta.

**Lo que costaría:** con nuestros 30 ingenieros el ahorro sería modesto, entre
**8% y 37%** según cómo contratemos las GPUs. El ahorro crece con el equipo: a 100
ingenieros llega a **41–62%**.

**Recomendación:** no decidir la migración todavía. Aprobar un **piloto de dos
semanas con 5 a 8 ingenieros voluntarios (~$1,000)** para medir calidad con trabajo
real, con criterios de éxito acordados antes de empezar.

---

## 1. Qué levantamos

Tres piezas, todas de código abierto:

```text
   Ingenieros (opencode en Mac, Windows, Linux)
                    │
                    │  cada uno con su llave personal
                    ▼
   ┌─────────────────────────────────────┐
   │  GATEWAY (LiteLLM)                  │  ← decide quién entra, registra todo,
   │  llaves · límites · registro de uso │    y puede mandar tareas a Claude
   └─────────────────┬───────────────────┘
                     ▼
   ┌─────────────────────────────────────┐
   │  MODELO (vLLM + Qwen3-Coder 30B)    │  ← corre en una GPU que alquilamos
   │  1× NVIDIA L40S, 48 GB              │
   └─────────────────────────────────────┘
```

- **El modelo:** Qwen3-Coder 30B, de Alibaba. Está entrenado para programar y para
  usar herramientas (leer archivos, editar, correr comandos), que es lo que hace un
  agente como opencode. Licencia Apache 2.0: uso comercial libre, sin regalías.
- **El servidor (vLLM):** el estándar de la industria para servir modelos abiertos.
  Atiende a varias personas a la vez y reutiliza el contexto que ya procesó.
- **El gateway (LiteLLM):** la puerta de entrada. Los ingenieros nunca hablan
  directo con la GPU.
- **Dónde:** una GPU alquilada por hora en RunPod. Nada comprado.

**Costo de toda la prueba: menos de $15 en GPU.**

---

## 2. Qué medimos

Todos estos números salen de pruebas reales, no de estimaciones.

### Capacidad y velocidad

| Qué | Resultado | Qué significa en la práctica |
|---|---|---|
| Velocidad con 1 persona | **135 tokens/s** | Más rápido de lo que alguien puede leer |
| Velocidad con 10 personas a la vez (**prefijo compartido**) | **58–73 tokens/s cada una** | Solo cuando comparten contexto; con sesiones distintas baja a ~16 tok/s (ver resultados) |
| Memoria de trabajo | **220,000 tokens** | Unas 9 sesiones reales abiertas a la vez |
| Errores | **0** en todas las pruebas | Aun pidiendo más memoria de la que hay, no falla: pone en fila |
| Uso de herramientas | **Funciona** | opencode lee, edita y ejecuta sin problemas |

### El dato clave: reutilizar el contexto multiplica la capacidad

Mandamos la misma carga dos veces: 10 personas a la vez. La primera con contextos
distintos, la segunda con contexto compartido.

| | Tiempo total | Tiempo hasta la primera palabra |
|---|---:|---:|
| Contexto nuevo cada vez | 16.1 s | 9.7 s |
| Contexto ya procesado | **5.2 s** | **3.8 s** |

**3 veces más rápido** solo por reutilizar lo que ya estaba en memoria. En una
sesión de trabajo normal cada turno reenvía casi todo lo anterior, así que este es
el régimen en el que el sistema pasa la mayor parte del tiempo.

### Cómo trabaja un ingeniero de verdad

Medimos 14 turnos de otra persona del equipo trabajando con opencode:

- **Cada sesión arranca con 12,000 tokens** antes de hacer nada (las instrucciones
  internas de la herramienta).
- **Crece unos 2,400 tokens por turno.** En 14 turnos llegó a 43,500.
- **Por cada token que el modelo escribe, lee 157.** Este trabajo es de leer
  contexto, no de generar texto.
- **El 87% de lo que se envió ya se había enviado antes.** En Anthropic eso se paga
  cada vez. En nuestra GPU es memoria reutilizándose.

### Latencia: casi todo es la red

| Tramo | Tiempo |
|---|---:|
| El modelo responde | 56 ms |
| El gateway añade | 15 ms |
| La red pública hasta la GPU alquilada | ~1,000 ms |

**El 94% de la espera es el camino de internet**, no el sistema. En producción la
GPU estaría en una red privada o en nuestra propia nube, y ese segundo se reduciría
a unas decenas de milisegundos. El gateway, con todo lo que aporta, cuesta 15 ms.

---

## 3. Qué nos da el gateway

Esta es la parte que vale la pena aunque el ahorro fuera cero.

**Una llave por persona.** Se crea o se revoca en segundos desde un panel web.
Si alguien sale del equipo, se le corta el acceso con un clic.

**Límites por persona.** Cuántos tokens por minuto, cuántas peticiones, qué
modelos puede usar, hasta qué fecha. Protegen a todo el equipo de una sesión que se
desboca.

**Visibilidad completa.** Cada petición queda registrada: quién, cuándo, qué modelo,
cuántos tokens, cuánto tardó. En esta prueba ya teníamos 76 peticiones registradas,
cada una con su dueño. Hoy no tenemos nada parecido sobre cómo usamos Claude.

**Una sola dirección para todo.** Cualquier herramienta compatible con la API de
OpenAI se conecta igual: opencode, scripts, extensiones de IDE.

**Sin atarnos a nadie.** Cambiar de modelo o de proveedor de GPU es cambiar una
línea de configuración en el gateway. Los ingenieros no se enteran.

**Modelo propio y Claude en el mismo lugar.** El gateway puede mandar el trabajo
rutinario al modelo propio y lo difícil a Claude, y pasar a Claude automáticamente
si nuestro servidor se cae. Está disponible pero **no lo probamos todavía**.

**Privacidad, con un matiz importante.** Con un modelo propio, ningún proveedor de
IA ve nuestro código ni lo usa para entrenar. Pero en esta prueba la GPU estaba en
RunPod, que es un tercero. Para decir "el código no sale de casa" la GPU tiene que
vivir en infraestructura que controlemos: nuestra cuenta de nube o hardware propio.

---

## 4. Cuánto costaría

### Supuestos

- **GPU:** $1.09/hora por L40S, el precio que pagamos en la prueba ($796/mes si
  está siempre encendida). Con contrato reservado, unos 30% menos.
- **Personas trabajando a la vez en hora pico:** entre 30% y 40% del equipo
  (supuesto, no medido). Una sesión pasa buena parte del tiempo esperando al humano.
- **Operación:** un cuarto del tiempo de un ingeniero, ~$800–1,000/mes. Casi fijo,
  no crece mucho con el equipo.
- **Claude para lo difícil:** entre 10% y 20% del trabajo seguiría yendo a Claude.
- **Redundancia:** desde 30 ingenieros, siempre un servidor de más, para que la
  caída de uno no deje a nadie sin servicio.

### Por tamaño de equipo (costo mensual)

| Ingenieros | Hoy (Claude, $200/asiento) | Propio, precio por hora | Ahorro | Propio, contrato reservado | Ahorro |
|---:|---:|---:|---:|---:|---:|
| 10 | $2,000 | $1,900 – 2,300 | ninguno | $1,650 – 2,050 | 0 – 17% |
| **30** | **$6,000** | **$4,700 – 5,500** | **8 – 21%** | **$3,800 – 4,600** | **24 – 37%** |
| 60 | $12,000 | $7,000 – 8,400 | 30 – 41% | $5,600 – 7,000 | 42 – 53% |
| 100 | $20,000 | $9,600 – 11,900 | 41 – 52% | $7,700 – 10,000 | 50 – 62% |

### El desglose para nuestros 30 ingenieros

| Concepto | Por hora | Reservado |
|---|---:|---:|
| 4 GPUs (2 servidores de 2 GPUs, uno de respaldo) | $3,184 | ~$2,230 |
| Gateway, monitoreo y almacenamiento | $150 | $150 |
| Operación | $800 – 1,000 | $800 – 1,000 |
| Claude para tareas difíciles | $600 – 1,200 | $600 – 1,200 |
| **Total** | **$4,700 – 5,500** | **$3,800 – 4,600** |

### Lo importante de esta tabla

**El costo deja de ser por persona y pasa a ser por capacidad.** Hoy cada ingeniero
nuevo son $200 más al mes, para siempre. Con esto pagamos por servidor, y un servidor
atiende a muchos: el costo por ingeniero **baja** cada vez que el equipo crece.

- Con 30 ingenieros: ~$155–185 por persona.
- Con 100 ingenieros: ~$96–119 por persona.

**Con 30 ingenieros el caso económico es modesto.** No conviene prometer un ahorro
grande a este tamaño. Lo que sí es claro hoy es lo de la sección 3: control,
visibilidad y no depender de un solo proveedor.

---

## 5. Lo que todavía no sabemos

Esta sección es tan importante como las anteriores.

**Calidad.** No la medimos. Este modelo no iguala a los mejores de Anthropic en las
tareas más difíciles, y eso está asumido en el diseño (por eso Claude sigue para lo
difícil). Lo que no sabemos es **qué porcentaje del trabajo diario** resuelve bien.
De eso depende casi todo el caso de negocio.

> Opinión de la persona que lo probó: _[PENDIENTE — puntaje 1 a 5 y si hubiera
> preferido Claude]_

**Sesiones largas.** Probamos minutos y horas, no sesiones de varios días. Cuando
una sesión llena su memoria, la herramienta la resume y se pierde la ventaja de
reutilizar contexto. Eso pasará varias veces al día por ingeniero y todavía no lo
medimos.

**30 personas a la vez.** Probamos 10 en una GPU. Los números para 30 están
calculados con una fórmula que validamos hoy (predijo 78 tokens/s, medimos 73),
pero no los probamos con un servidor de 2 GPUs.

**Cuántos trabajan a la vez.** El supuesto de 30–40% en hora pico cambia bastante
el número de GPUs. Se mide en el piloto.

**Operarlo no es gratis.** Montarlo nos tomó dos sesiones de trabajo y encontramos
siete problemas propios del entorno alquilado (discos, puertos, procesos que
quedaban vivos). Todos quedaron resueltos y automatizados en un script de arranque,
pero confirman que la línea de "operación" en los costos es real.

---

## 6. Qué proponemos

**Un piloto de dos semanas**, antes de cualquier decisión de migración.

| | |
|---|---|
| **Quiénes** | 5 a 8 ingenieros voluntarios |
| **Con qué** | 1 servidor de 2 GPUs, el mismo gateway, opencode |
| **Costo** | ~$1,000 (GPU por hora + Claude para lo difícil) |
| **Qué medimos** | calidad por tarea, satisfacción, cuántos trabajan a la vez, sesiones largas |

**Criterios de éxito, acordados antes de empezar:**

- Al menos **75% de las tareas** resueltas sin que el ingeniero eche de menos Claude.
- Velocidad de **40 tokens/s o más** por persona en hora pico.
- Tiempo hasta la primera palabra **menor a 1.5 s** en 9 de cada 10 peticiones,
  medido desde una red privada.
- **Ninguna caída** sin explicación.

**Si pasa**, proponemos una implementación para los 30 ingenieros con contrato
reservado. **Si no pasa**, el resultado también es valioso: evitamos gastar ~$50,000
al año en algo peor, y nos quedamos con el gateway, que sirve igual para ordenar y
medir nuestro uso de Claude.

**Lo que necesitamos para arrancar:**

1. Aprobación del presupuesto del piloto (~$1,000).
2. 5 a 8 voluntarios dispuestos a calificar sus tareas durante dos semanas.
3. Definir dónde viviría en producción (nuestra nube o proveedor con red privada).

---

## Glosario mínimo

| Término | Qué es |
|---|---|
| **Token** | Un pedazo de palabra. Unos 3 a 4 caracteres. Es la unidad con la que se mide y se cobra la IA. |
| **Contexto** | Todo lo que el modelo tiene "a la vista" en una conversación: instrucciones, archivos leídos, historial. |
| **Tokens/s** | Qué tan rápido escribe el modelo. Una persona lee unos 5–10 por segundo. |
| **GPU** | El procesador donde corre el modelo. Se alquila por hora. |
| **Gateway** | La puerta de entrada única: decide quién entra, registra el uso y reparte el trabajo. |
| **Re-lectura de contexto** | Cuando cada turno de una conversación reenvía todo lo anterior. En Anthropic se cobra cada vez; en una GPU propia se reutiliza gratis. |

---

_Detalle técnico, scripts y datos crudos: `inference-poc/` (plan técnico en
`reports/plan-self-hosted-30-ingenieros.md`, mediciones en
`benchmark/resultados/`, scripts de arranque en `runpod/`)._
