# Kids chat guard

`kids_guard_filter.py` is an Open WebUI filter for the kids' model. Two local guard models in LM Studio check every kid message and every reply, and it fails closed. See the homelab wiki (`services/fort.md`).

- `eval/`: labeled kid test cases and scoring. Re-run before changing thresholds. `score.py` needs jinja2 and Qwen3Guard's `tokenizer_config.json`.
- `test/`: a throwaway Open WebUI plus `mock_llm.py` (canned replies), API checks, a browser leak check, and a real-Gemma run.

Models (LM Studio): `qwen3guard-gen-4b` and `shieldstral-1.0-3b`, loaded with those names as identifiers.
