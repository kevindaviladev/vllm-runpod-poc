# Recursos de lectura/estudio — en orden para mi nivel

> Regla: 20–30 min de lectura antes de cada sesión práctica. No leer todo de golpe.
> Marcar con [x] cuando terminado.

## Nivel 1 — Conceptual visual (lo que estoy viendo ahora)

- [ ] **3Blue1Brown — "But what is a GPT?"** (serie de videos, gratis, subtítulos ES)
  https://www.youtube.com/@3blue1brown — la mejor explicación visual de tokens,
  embeddings, attention y por qué el modelo predice el siguiente token.
  *Mapa: Lecciones 1–3 de este curso.*

- [ ] **Jay Alammar — The Illustrated Transformer** (post clásico, ilustrado)
  https://jalammar.github.io/illustrated-transformer/
  *Mapa: qué es Q/K/V por dentro. Solo primera lectura conceptual, sin ecuaciones.*

- [ ] **Andrej Karpathy — "Intro to Large Language Models"** (video 1h, charla)
  https://www.youtube.com/watch?v=zjkBMFhNj_g
  *Mapa: el panorama completo — training vs inference, model serving, escala.
  La charla más rentable por hora invertida que existe.*

## Nivel 2 — Internals con práctica

- [ ] **Hugging Face LLM Course** (gratis, online, capítulos 1–3)
  https://huggingface.co/learn/llm-course/chapter1/1
  *Mapa: tokenizers de verdad, arquitectura, fine-tuning ligero.*

- [ ] **Karpathy — "Let's build GPT: from scratch, in code"** (video 2h)
  https://www.youtube.com/watch?v=kCc8FmEb1nY
  *Mapa: Transformer implementado en Python puro. Hacerlo DESPUÉS del LLM Course.
  No es obligatorio para el negocio, pero es el que hace que todo "cierre".*

- [ ] **Sebastian Raschka — Build a LLM (From Scratch)** (libro, 2024)
  *Alternativa libro al video de Karpathy. Más lento, más profundo.*

## Nivel 3 — El libro del negocio (inference engineering práctico)

- [ ] **Chip Huyen — AI Engineering** (O'Reilly, 2025)
  https://a.co/d/gD1S0dA — capítulo de "Inference Optimization" y "Serving LLMs".
  *Es literalmente el roadmap-ii en forma de libro: serving, latencia, costo,
  evaluación, gateway. EL libro para tu proyecto.*

- [ ] **Chip Huyen — blog** (huyenchip.com) y **Lilian Weng — blog** (lilianweng.github.io)
  Posts sueltos sobre serving, batching, quantization. Leer según tema del día.

## Nivel 4 — Referencia de infraestructura (Track B/C, después)

- [ ] vLLM docs + blog de PagedAttention (https://blog.vllm.ai)
- [ ] Ollama docs (https://docs.ollama.com) — keep_alive, num_ctx, modelfiles
- [ ] MLX docs (https://ml-explore.github.io/mlx/)
- [ ] Papers: GPTQ, AWQ, FlashAttention (solo abstracts al principio)

## Anti-rabbit-hole

Si una lectura empieza a exigir CUDA, cálculo de gradientes o álgebra de tensores
profunda → cerrarla y anotarla para Track C. El objetivo es inference engineering,
no research scientist.
