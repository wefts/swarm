"""Swarm ML service — the Intelligence pillar (system architecture §2).

Embeddings and model inference live here, reached by the Elixir kernel over
gRPC. The kernel embeds no model code; this package is the only home for it.
"""
