import argparse
import csv
import json
import os
import time

import requests

OLLAMA = "http://localhost:11434/api/chat"


def run_once(model: str, prompt: str) -> dict:
    start = time.perf_counter()
    ttft_ms = None
    final = None
    message = ""

    with requests.post(
        OLLAMA,
        json={
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
            "options": {"num_ctx": 8192},
        },
        stream=True,
    ) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if not line:
                continue
            chunk = json.loads(line)
            content = chunk.get("message", {}).get("content", "")
            if content and ttft_ms is None:
                ttft_ms = (time.perf_counter() - start) * 1000
            if chunk.get("done"):
                final = chunk
            # Acumular el contenido del mensaje
            message += content

    if final is None:
        raise RuntimeError("El stream termino sin recibir el chunk 'done'")

    total_ms = (time.perf_counter() - start) * 1000

    prompt_tokens = final.get("prompt_eval_count", 0)
    output_tokens = final.get("eval_count", 0)
    eval_duration_s = final.get("eval_duration", 0) / 1e9
    prefill_ms = final.get("prompt_eval_duration", 0) / 1e6

    tok_s_reported = output_tokens / eval_duration_s if eval_duration_s > 0 else 0.0

    prefill_tok_s = prompt_tokens / (prefill_ms / 1000) if prefill_ms > 0 else 0.0

    decode_wall_s = (total_ms - (ttft_ms or 0.0)) / 1000
    tok_s_measured = output_tokens / decode_wall_s if decode_wall_s > 0 else 0.0

    return {
        "model": model,
        "prompt_tokens": prompt_tokens,
        "output_tokens": output_tokens,
        "message": message,
        "ttft_ms": round(ttft_ms, 1),
        "prefill_ms": round(prefill_ms, 1),
        "prefill_tok_s": round(prefill_tok_s, 1),
        "total_ms": round(total_ms, 1),
        "tok_s_reported": round(tok_s_reported, 1),
        "tok_s_measured": round(tok_s_measured, 1),
    }


def append_csv(path: str, row: dict) -> None:
    file_exists = os.path.exists(path)
    with open(path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(row.keys()))
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)


def main():
    ap = argparse.ArgumentParser(description="Benchmark simple contra Ollama")
    ap.add_argument("--model", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--out", default="results.csv")
    args = ap.parse_args()

    row = run_once(args.model, args.prompt)
    append_csv(args.out, row)
    print(json.dumps(row, indent=2))


if __name__ == "__main__":
    main()
