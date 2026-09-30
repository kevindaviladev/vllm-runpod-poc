import argparse
import csv
import json
import os
import time

import requests


def run_once(base_url: str, model: str, prompt: str, api_key: str = "") -> dict:
    start = time.perf_counter()
    ttft_ms = None
    content = ""
    usage = None

    with requests.post(
        f"{base_url.rstrip('/')}/chat/completions",
        headers={"Authorization": f"Bearer {api_key}"} if api_key else {},
        json={
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
            "stream_options": {"include_usage": True},
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
            if usage is None or chunk.get("usage"):
                if chunk.get("usage"):
                    usage = chunk["usage"]
            choices = chunk.get("choices") or []
            delta = choices[0].get("delta", {}) if choices else {}
            piece = delta.get("content") or ""
            if piece and ttft_ms is None:
                ttft_ms = (time.perf_counter() - start) * 1000
            content += piece

    if ttft_ms is None:
        raise RuntimeError("No llego ningun token con contenido")

    total_ms = (time.perf_counter() - start) * 1000

    prompt_tokens = usage.get("prompt_tokens") if usage else None
    output_tokens = usage.get("completion_tokens") if usage else None
    if output_tokens is None:
        output_tokens = max(1, round(len(content) / 4))

    decode_wall_s = (total_ms - ttft_ms) / 1000
    tok_s_measured = output_tokens / decode_wall_s if decode_wall_s > 0 else 0.0

    return {
        "model": model,
        "prompt_tokens": prompt_tokens,
        "output_tokens": output_tokens,
        "ttft_ms": round(ttft_ms, 1),
        "total_ms": round(total_ms, 1),
        "tok_s_measured": round(tok_s_measured, 1),
        "response": content,
    }


def append_csv(path: str, row: dict) -> None:
    file_exists = os.path.exists(path)
    with open(path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(row.keys()))
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)


def main():
    ap = argparse.ArgumentParser(description="Benchmark contra API OpenAI-compatible (Ollama, vLLM, LiteLLM...)")
    ap.add_argument("--base-url", required=True, help="ej: http://localhost:11434/v1")
    ap.add_argument("--model", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--out", default="results_openai.csv")
    ap.add_argument("--api-key", default=os.environ.get("OPENAI_API_KEY", ""),
                    help="para LiteLLM o vLLM con --api-key (por defecto: $OPENAI_API_KEY)")
    args = ap.parse_args()

    row = run_once(args.base_url, args.model, args.prompt, args.api_key)
    append_csv(args.out, row)
    print(row["response"])
    print("---")
    print(json.dumps({k: v for k, v in row.items() if k != "response"}, indent=2))


if __name__ == "__main__":
    main()
