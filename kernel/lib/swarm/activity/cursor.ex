defmodule Swarm.Activity.Cursor do
  @moduledoc """
  Opaque resume token for `Swarm.Activity` (swarm ADR-15) — the council headline.

  The ActivityFeed must not leak hidden-event volume or timing through sequence
  gaps. The internal position is the `outbox.seq` high-water mark, but the wire
  must carry **no raw `seq`**: a client that could read the seq would infer how
  many out-of-scope events were skipped between two polls. So the position is
  sealed with authenticated encryption (AES-256-GCM, a random IV per token) — the
  ciphertext is opaque and two tokens for the same seq are uncorrelatable, so the
  client can neither read the position nor diff two cursors to recover a gap.

  The key is taken from config (`:swarm, :activity_feed, :cursor_key`, a 32-byte
  binary) when set, else a process-lifetime key cached in `:persistent_term`. A
  cursor minted under a key that has since rotated (e.g. a kernel restart with no
  configured key) simply fails to decode — `Swarm.Activity` then resyncs to the
  tail (`"" ⇒ most recent`), never crashes. Cursors are short-lived poll tokens,
  so an ephemeral key is acceptable.
  """

  @aad "swarm.activity.cursor.v1"

  @doc "Seal a non-negative `seq` position into an opaque, base64url token."
  @spec encode(non_neg_integer()) :: String.t()
  def encode(seq) when is_integer(seq) and seq >= 0 do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, <<seq::64>>, @aad, true)
    Base.url_encode64(iv <> tag <> ct, padding: false)
  end

  @doc """
  Recover the sealed `seq` from a token, or `:error` for any malformed, tampered,
  or wrong-key token (the caller resyncs to the tail rather than trusting it).
  """
  @spec decode(String.t()) :: {:ok, non_neg_integer()} | :error
  def decode(token) when is_binary(token) do
    with {:ok, <<iv::binary-12, tag::binary-16, ct::binary>>} <-
           Base.url_decode64(token, padding: false),
         <<seq::64>> <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, @aad, tag, false) do
      {:ok, seq}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  @spec key() :: binary()
  defp key do
    case Application.get_env(:swarm, :activity_feed, [])[:cursor_key] do
      <<k::binary-32>> -> k
      _ -> cached_key()
    end
  end

  @spec cached_key() :: binary()
  defp cached_key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        k = :crypto.strong_rand_bytes(32)
        :persistent_term.put({__MODULE__, :key}, k)
        k

      k ->
        k
    end
  end
end
