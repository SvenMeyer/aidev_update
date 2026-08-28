#!/bin/bash
# Re-apply local fix from headroom PR #391 to the pipx install.
#
# Bug: headroom's litellm-* / anyllm / openrouter backend-routed traffic
# is recorded in metrics totals but does not appear in `/stats` recent
# requests or the dashboard live feed, and streaming output_tokens is
# always 0. PR #391 fixes both upstream:
#   https://github.com/headroomlabs-ai/headroom/pull/391
#
# This script patches the freshly-installed pipx files in place. It is
# idempotent: running it twice is a no-op. It is intended to be invoked
# from headroom_update.sh AFTER `pipx install` and BEFORE the proxy
# restart. Remove this script once the upstream PR merges.
set -euo pipefail

PIPX_VENV_DIR="${PIPX_HOME:-${HOME}/.local/share/pipx}/venvs/headroom-ai"
SITE_PKG="${PIPX_VENV_DIR}/lib/python3.13/site-packages"

# Probe for the actual python3.X site-packages dir under the venv.
if [[ ! -d "$SITE_PKG" ]]; then
    SITE_PKG=$(find "${PIPX_VENV_DIR}/lib" -maxdepth 2 -type d -name 'site-packages' 2>/dev/null | head -1 || true)
fi

if [[ -z "$SITE_PKG" || ! -d "$SITE_PKG" ]]; then
    echo "⚠ Could not locate headroom site-packages dir under $PIPX_VENV_DIR. Skipping PR #391 patch." >&2
    exit 0
fi

OPENAI_PY="${SITE_PKG}/headroom/proxy/handlers/openai.py"
STREAMING_PY="${SITE_PKG}/headroom/proxy/handlers/streaming.py"

if [[ ! -f "$OPENAI_PY" || ! -f "$STREAMING_PY" ]]; then
    echo "⚠ Expected handler files not found under $SITE_PKG/headroom/proxy/handlers/. Skipping PR #391 patch." >&2
    exit 0
fi

python3 - "$OPENAI_PY" "$STREAMING_PY" <<'PY'
import ast
import re
import sys
from pathlib import Path

openai_py, streaming_py = (Path(p) for p in sys.argv[1:3])
PATCH_MARKER = "from headroom.proxy.models import RequestLog"


def repair_bad_sse_escapes(src: str) -> tuple[str, int]:
    """Repair an older patch-script bug where re.sub unescaped SSE newlines."""
    replacements = (
        (
            '                yield f"data: {json.dumps(error_data)}\n\n".encode()',
            '                yield f"data: {json.dumps(error_data)}\\n\\n".encode()',
        ),
        (
            '                yield b"data: [DONE]\n\n"',
            '                yield b"data: [DONE]\\n\\n"',
        ),
    )
    repairs = 0
    for broken, fixed in replacements:
        count = src.count(broken)
        if count:
            src = src.replace(broken, fixed)
            repairs += count
    return src, repairs


streaming_src = streaming_py.read_text()
streaming_src, repaired = repair_bad_sse_escapes(streaming_src)
if repaired:
    streaming_py.write_text(streaming_src)
    print("✓ streaming.py repaired escaped SSE newlines")

if PATCH_MARKER in openai_py.read_text() and PATCH_MARKER in streaming_py.read_text():
    for p in (openai_py, streaming_py):
        ast.parse(p.read_text())
    print("✓ PR #391 patches already applied — skipping.")
    sys.exit(0)

# ---------- openai.py: emit RequestLog after backend metrics.record_request ----
src = openai_py.read_text()
if PATCH_MARKER in src:
    print("✓ openai.py already patched")
else:
    needle = re.compile(
        r"(                    await self\.metrics\.record_request\(\n"
        r"                        provider=self\.anthropic_backend\.name,\n"
        r"                        model=model,\n"
        r"                        input_tokens=total_input_tokens,\n"
        r"                        output_tokens=output_tokens,\n"
        r"                        tokens_saved=tokens_saved,\n"
        r"                        latency_ms=total_latency,\n"
        r"                        cached=False,\n"
        r"                        overhead_ms=optimization_latency,\n"
        r"                        pipeline_timing=pipeline_timing,\n"
        r"                    \)\n)\n(                    if tokens_saved > 0:)"
    )
    inject = (
        "\n"
        "                    if getattr(self, \"logger\", None) is not None:\n"
        "                        from headroom.proxy.models import RequestLog\n\n"
        "                        self.logger.log(\n"
        "                            RequestLog(\n"
        "                                request_id=request_id,\n"
        "                                timestamp=datetime.now().isoformat(),\n"
        "                                provider=self.anthropic_backend.name,\n"
        "                                model=model,\n"
        "                                input_tokens_original=original_tokens,\n"
        "                                input_tokens_optimized=optimized_tokens,\n"
        "                                output_tokens=output_tokens,\n"
        "                                tokens_saved=tokens_saved,\n"
        "                                savings_percent=(tokens_saved / original_tokens * 100)\n"
        "                                if original_tokens > 0\n"
        "                                else 0,\n"
        "                                optimization_latency_ms=optimization_latency,\n"
        "                                total_latency_ms=total_latency,\n"
        "                                tags=tags or {},\n"
        "                                cache_hit=False,\n"
        "                                transforms_applied=transforms_applied,\n"
        "                                request_messages=body.get(\"messages\")\n"
        "                                if getattr(self.config, \"log_full_messages\", False)\n"
        "                                else None,\n"
        "                            )\n"
        "                        )\n\n"
    )
    new_src, n = needle.subn(lambda match: match.group(1) + inject + match.group(2), src, count=1)
    if n != 1:
        print("⚠ openai.py: anchor not found, skipping (file may have changed upstream)", file=sys.stderr)
    else:
        openai_py.write_text(new_src)
        print("✓ openai.py patched")

# ---------- streaming.py: stream_options + usage parsing + RequestLog ---------
src = streaming_py.read_text()
if PATCH_MARKER in src:
    print("✓ streaming.py already patched")
else:
    needle = re.compile(
        r"        assert self\.anthropic_backend is not None\n\n"
        r"        async def generate\(\):\n"
        r"            try:\n"
        r"                async for sse_chunk in self\.anthropic_backend\.stream_openai_message\(body, headers\):\n"
        r"                    yield sse_chunk\.encode\(\) if isinstance\(sse_chunk, str\) else sse_chunk\n"
        r"            except Exception as e:\n"
        r"                logger\.error\(f\"\[\{request_id\}\] Backend streaming error: \{e\}\"\)\n"
        r"                error_data = \{\n"
        r"                    \"error\": \{\n"
        r"                        \"message\": str\(e\),\n"
        r"                        \"type\": \"api_error\",\n"
        r"                        \"code\": \"backend_error\",\n"
        r"                    \}\n"
        r"                \}\n"
        r"                yield f\"data: \{json\.dumps\(error_data\)\}\\n\\n\"\.encode\(\)\n"
        r"                yield b\"data: \[DONE\]\\n\\n\"\n"
        r"            finally:\n"
        r"                total_latency = \(time\.time\(\) - start_time\) \* 1000\n"
        r"                await self\.metrics\.record_request\(\n"
        r"                    provider=self\.anthropic_backend\.name,\n"
        r"                    model=model,\n"
        r"                    input_tokens=optimized_tokens,\n"
        r"                    output_tokens=0,  # Unknown in streaming\n"
        r"                    tokens_saved=tokens_saved,\n"
        r"                    latency_ms=total_latency,\n"
        r"                    cached=False,\n"
        r"                    overhead_ms=optimization_latency,\n"
        r"                    pipeline_timing=pipeline_timing,\n"
        r"                \)\n"
        r"                if tokens_saved > 0:\n"
        r"                    logger\.info\(\n"
        r"                        f\"\[\{request_id\}\] \{model\}: \{original_tokens:,\} → \{optimized_tokens:,\} \"\n"
        r"                        f\"\(saved \{tokens_saved:,\} tokens\) via \{self\.anthropic_backend\.name\} \[stream\]\"\n"
        r"                    \)\n"
    )
    replacement = (
        "        assert self.anthropic_backend is not None\n\n"
        "        if \"stream_options\" not in body:\n"
        "            body[\"stream_options\"] = {\"include_usage\": True}\n"
        "        elif isinstance(body.get(\"stream_options\"), dict):\n"
        "            body[\"stream_options\"].setdefault(\"include_usage\", True)\n\n"
        "        stream_state: dict[str, Any] = {\n"
        "            \"output_tokens\": 0,\n"
        "            \"sse_buffer\": bytearray(),\n"
        "        }\n\n"
        "        async def generate():\n"
        "            try:\n"
        "                async for sse_chunk in self.anthropic_backend.stream_openai_message(body, headers):\n"
        "                    chunk_bytes = sse_chunk.encode() if isinstance(sse_chunk, str) else sse_chunk\n"
        "                    yield chunk_bytes\n\n"
        "                    try:\n"
        "                        stream_state[\"sse_buffer\"].extend(chunk_bytes)\n"
        "                        usage = self._parse_sse_usage_from_buffer(stream_state, \"openai\")\n"
        "                        if usage and \"output_tokens\" in usage:\n"
        "                            stream_state[\"output_tokens\"] = usage[\"output_tokens\"]\n"
        "                    except Exception as parse_err:  # noqa: BLE001\n"
        "                        logger.debug(\n"
        "                            f\"[{request_id}] usage parse error \"\n"
        "                            f\"via {self.anthropic_backend.name}: {parse_err}\"\n"
        "                        )\n"
        "            except Exception as e:\n"
        "                logger.error(f\"[{request_id}] Backend streaming error: {e}\")\n"
        "                error_data = {\n"
        "                    \"error\": {\n"
        "                        \"message\": str(e),\n"
        "                        \"type\": \"api_error\",\n"
        "                        \"code\": \"backend_error\",\n"
        "                    }\n"
        "                }\n"
        "                yield f\"data: {json.dumps(error_data)}\\n\\n\".encode()\n"
        "                yield b\"data: [DONE]\\n\\n\"\n"
        "            finally:\n"
        "                total_latency = (time.time() - start_time) * 1000\n"
        "                output_tokens = stream_state[\"output_tokens\"]\n"
        "                await self.metrics.record_request(\n"
        "                    provider=self.anthropic_backend.name,\n"
        "                    model=model,\n"
        "                    input_tokens=optimized_tokens,\n"
        "                    output_tokens=output_tokens,\n"
        "                    tokens_saved=tokens_saved,\n"
        "                    latency_ms=total_latency,\n"
        "                    cached=False,\n"
        "                    overhead_ms=optimization_latency,\n"
        "                    pipeline_timing=pipeline_timing,\n"
        "                )\n\n"
        "                if getattr(self, \"logger\", None) is not None:\n"
        "                    from headroom.proxy.models import RequestLog\n\n"
        "                    self.logger.log(\n"
        "                        RequestLog(\n"
        "                            request_id=request_id,\n"
        "                            timestamp=datetime.now().isoformat(),\n"
        "                            provider=self.anthropic_backend.name,\n"
        "                            model=model,\n"
        "                            input_tokens_original=original_tokens,\n"
        "                            input_tokens_optimized=optimized_tokens,\n"
        "                            output_tokens=output_tokens,\n"
        "                            tokens_saved=tokens_saved,\n"
        "                            savings_percent=(tokens_saved / original_tokens * 100)\n"
        "                            if original_tokens > 0\n"
        "                            else 0,\n"
        "                            optimization_latency_ms=optimization_latency,\n"
        "                            total_latency_ms=total_latency,\n"
        "                            tags=tags or {},\n"
        "                            cache_hit=False,\n"
        "                            transforms_applied=transforms_applied,\n"
        "                            request_messages=body.get(\"messages\")\n"
        "                            if getattr(self.config, \"log_full_messages\", False)\n"
        "                            else None,\n"
        "                        )\n"
        "                    )\n\n"
        "                if tokens_saved > 0:\n"
        "                    logger.info(\n"
        "                        f\"[{request_id}] {model}: {original_tokens:,} → {optimized_tokens:,} \"\n"
        "                        f\"(saved {tokens_saved:,} tokens) via {self.anthropic_backend.name} [stream]\"\n"
        "                    )\n"
    )
    new_src, n = needle.subn(lambda _match: replacement, src, count=1)
    if n != 1:
        print("⚠ streaming.py: anchor not found, skipping (file may have changed upstream)", file=sys.stderr)
    else:
        streaming_py.write_text(new_src)
        print("✓ streaming.py patched")

# Sanity: make sure both files still parse.
for p in (openai_py, streaming_py):
    ast.parse(p.read_text())
print("✓ syntax check ok")
PY

echo "✓ PR #391 patches applied to ${SITE_PKG}/headroom/proxy/handlers/"
