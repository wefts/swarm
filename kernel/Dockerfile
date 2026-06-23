# syntax=docker/dockerfile:1
#
# PRODUCTION image for the Swarm kernel (Elixir/OTP release).
# Dev does NOT use this — local dev runs on the host via `mix` (fast loop).
#
# Base: Docker Hardened Images (DHI). DHI has no Erlang/Elixir image, so we
# build the release on the official musl/alpine Elixir image and run it on the
# hardened DHI alpine-base (alpine 3.23 on BOTH sides → musl ABI matches).
# alpine-base is minimal: it ships busybox/sh (the release launcher needs it)
# but NOT the BEAM's shared libs, so we stage exactly those (resolved by ldd)
# from the build stage. Tags are pinned for offline mirroring (never :latest).
# Registry tier (override to point elsewhere): local mirror `localhost:5000`
# (offline) → Smile public aliases (default, safe to commit) → upstream. Digests
# are content-addressed, so the same pin resolves on any mirror.
ARG HUB_REGISTRY=dockerhub.smile.fr
ARG DHI_REGISTRY=dhi.smile.fr
ARG ELIXIR_IMAGE=${HUB_REGISTRY}/hexpm/elixir:1.19.5-erlang-28.5-alpine-3.23.4@sha256:ea9cea6b8c9cfc14e3278ade22eb664a3b64fbd4e4ec7edf6b2dab63c4b812f0
ARG RUNTIME_IMAGE=${DHI_REGISTRY}/alpine-base:3.23@sha256:59e5cd463df8a4ab8a457b639867e877a809f053f84cdeecc9b421c9b24385d9

# ---- build stage --------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build
WORKDIR /app
ENV MIX_ENV=prod LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
RUN mix compile && mix release swarm

# Stage the shared libs the BEAM needs (alpine-base has only musl libc).
# Explicit copies for the known hard deps (libstdc++/libgcc for beam.smp,
# openssl for :crypto, ncurses for the shell, zlib for :zlib), PLUS an
# ldd-resolved safety net for anything transitive. Paths differ across
# /lib and /usr/lib on alpine, so try both; tolerate misses.
RUN set -eux; mkdir -p /staged; \
    for p in \
      /usr/lib/libstdc++.so.6* /usr/lib/libgcc_s.so.1* \
      /lib/libcrypto.so.3 /lib/libssl.so.3 /usr/lib/libcrypto.so.3 /usr/lib/libssl.so.3 \
      /usr/lib/libncursesw.so.6* /lib/libncursesw.so.6* \
      /usr/lib/libz.so.1* /lib/libz.so.1* ; do \
        for f in $p; do [ -e "$f" ] && cp -vL "$f" /staged/ || true; done; \
    done; \
    find _build/prod/rel/swarm -type f \( -name '*.so*' -o -perm -u+x \) -print0 \
      | xargs -0 -r ldd 2>/dev/null \
      | awk '/=>/ && $3 ~ /^\// {print $3}' | sort -u \
      | while IFS= read -r lib; do cp -nL "$lib" /staged/ 2>/dev/null || true; done; \
    ls -la /staged

# ---- runtime stage (DHI hardened alpine-base, non-root) -----------------
FROM ${RUNTIME_IMAGE} AS runtime
LABEL org.opencontainers.image.title="swarm-kernel" \
      org.opencontainers.image.description="Swarm kernel: Elixir/OTP control-plane (graph, gate, consilium, Core API)" \
      org.opencontainers.image.source="https://github.com/wefts/swarm" \
      org.opencontainers.image.version="0.1.0"
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    LD_LIBRARY_PATH=/opt/swarm/lib \
    RELEASE_TMP=/app/tmp
# alpine-base ships /bin/sh, so RUN works here. DHI strips the `root` NAME from
# /etc/passwd (nonroot-only), so switch by numeric uid 0, not by name.
USER 0
RUN mkdir -p /app/tmp /opt/swarm/lib && chown -R 65532:65532 /app
COPY --from=build /staged/ /opt/swarm/lib/
COPY --from=build --chown=65532:65532 /app/_build/prod/rel/swarm /app
USER 65532

EXPOSE 50061
# Liveness: the release answers an RPC (BEAM up + app booted), no DB required.
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD ["/app/bin/swarm", "rpc", "1 + 1"]

ENTRYPOINT ["/app/bin/swarm"]
CMD ["start"]
