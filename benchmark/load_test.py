import argparse
import csv
import json
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import requests

BASE_CHUNK = (
    "El sistema de inferencia procesa cada solicitud en dos fases: prefill y decode. "
    "Durante el prefill, el prompt completo se procesa en paralelo llenando la GPU de "
    "trabajo util. Durante el decode, cada token nuevo requiere leer los pesos del "
    "modelo desde la memoria, por lo que la velocidad depende del ancho de banda. "
)


def build_prompt(target_tokens: int, session_id: str = "") -> str:
    """session_id != "" mete un marcador unico AL INICIO: los prefijos divergen desde
    el primer token y el prefix caching NO puede compartir KV entre sesiones.
    Eso simula 30 ingenieros distintos. session_id == "" = prompt identico para todos
    (mide el mejor caso: cache hit total)."""
    chars = target_tokens * 4
    text = (BASE_CHUNK * (chars // len(BASE_CHUNK) + 1))[:chars]
    head = f"[sesion {session_id}] " if session_id else ""
    return (
        head + "A continuación encontrarás un documento técnico de contexto largo. "
        "Al final del documento responderás con un resumen de exactamente 3 líneas.\n\n"
        "=== DOCUMENTO ===\n" + text + "\n=== FIN DOCUMENTO ===\n\n"
        "Responde ahora con el resumen de 3 líneas."
    )


def run_one(base_url: str, model: str, prompt: str, max_tokens: int, api_key: str = "") -> dict:
    start = time.perf_counter()
    ttft_ms = None
    usage = None
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    with requests.post(
        f"{base_url.rstrip('/')}/chat/completions",
        headers=headers,
        json={
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
            "stream_options": {"include_usage": True},
            "max_tokens": max_tokens,
        },
        stream=True,
        timeout=600,
    ) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if not line:
                continue
            line = line.decode("utf-8")
            if not line.startswith("data: "):
                continue
            payload = line[len("data: "):]
            if payload.strip() == "[DONE]":
                break
            chunk = json.loads(payload)
            if chunk.get("usage"):
                usage = chunk["usage"]
            choices = chunk.get("choices") or []
            delta = choices[0].get("delta", {}) if choices else {}
            if (delta.get("content") or "") and ttft_ms is None:
                ttft_ms = (time.perf_counter() - start) * 1000

    total_s = time.perf_counter() - start
    out_tokens = usage.get("completion_tokens") if usage else None
    if out_tokens is None:
        out_tokens = max_tokens
    tok_s = out_tokens / (total_s - ttft_ms / 1000) if ttft_ms and total_s > ttft_ms / 1000 else 0.0
    return {
        "ttft_ms": round(ttft_ms or 0, 1),
        "total_s": round(total_s, 2),
        "tok_s": round(tok_s, 1),
        "prompt_tokens": usage.get("prompt_tokens") if usage else None,
        "output_tokens": out_tokens,
        "ok": ttft_ms is not None,
        "error": "",
    }


def run_one_safe(*a, **kw) -> dict:
    """Un fallo NO debe tumbar el test: el checklist cuenta fallos, no excepciones."""
    try:
        return run_one(*a, **kw)
    except Exception as e:  # noqa: BLE001
        return {"ttft_ms": 0, "total_s": 0, "tok_s": 0, "prompt_tokens": None,
                "output_tokens": 0, "ok": False, "error": f"{type(e).__name__}: {e}"[:200]}


def main():
    ap = argparse.ArgumentParser(description="Test de carga: N peticiones concurrentes con contexto largo")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--concurrency", type=int, default=30)
    ap.add_argument("--context-tokens", type=int, default=16000)
    ap.add_argument("--max-tokens", type=int, default=300)
    ap.add_argument("--api-key", default="", help="para LiteLLM o vLLM con --api-key")
    ap.add_argument("--session-mode", choices=["unique", "shared"], default="unique",
                    help="unique = N sesiones distintas (realista, mide capacidad de KV cache). "
                         "shared = mismo prompt para todos (mide el mejor caso de prefix caching)")
    ap.add_argument("--out", default=None, help="CSV opcional con el detalle por request")
    args = ap.parse_args()

    def prompt_for(i: int) -> str:
        return build_prompt(args.context_tokens,
                            f"{uuid.uuid4().hex[:8]}-{i}" if args.session_mode == "unique" else "")

    print(f"Lanzando {args.concurrency} peticiones concurrentes "
          f"(~{args.context_tokens} tokens de contexto, session-mode={args.session_mode})...")

    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        results = list(pool.map(
            lambda i: run_one_safe(args.base_url, args.model, prompt_for(i), args.max_tokens, args.api_key),
            range(args.concurrency)))
    wall_s = time.perf_counter() - start

    ok = [r for r in results if r["ok"]]
    failed = len(results) - len(ok)
    ttfts = sorted(r["ttft_ms"] for r in ok)
    tokss = sorted(r["tok_s"] for r in ok)

    def pct(lst, p):
        return lst[min(len(lst) - 1, int(len(lst) * p / 100))] if lst else 0

    print("\n=== RESULTADOS ===")
    print(f"Modelo: {args.model} | concurrencia: {args.concurrency} | "
          f"contexto: ~{args.context_tokens} tok | session-mode: {args.session_mode}")
    print(f"Exitos: {len(ok)}/{len(results)}  (fallos: {failed})")
    if failed:
        for e in sorted({r["error"] for r in results if not r["ok"] and r["error"]}):
            print(f"  ! {e}")
    print(f"Pared total: {wall_s:.1f}s")
    if ok:
        print(f"TTFT   p50: {pct(ttfts, 50)} ms | p90: {pct(ttfts, 90)} ms | max: {ttfts[-1]} ms")
        print(f"tok/s  min: {tokss[0]} | p50: {pct(tokss, 50)} | p90: {pct(tokss, 90)}")
        print(f"Throughput agregado: {sum(r['tok_s'] for r in ok):.0f} tok/s")
    print("\nCriterios del plan: TTFT p90 < 1500 ms | tok/s por usuario >= 40 | 0 fallos")

    if args.out:
        with open(args.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(results[0].keys()))
            w.writeheader()
            w.writerows(results)
        print(f"Detalle guardado en {args.out}")


if __name__ == "__main__":
    main()
