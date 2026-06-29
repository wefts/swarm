defmodule Swarm.Activity.CursorTest do
  @moduledoc """
  ADR-15 — the opaque ActivityFeed cursor. The wire must carry no readable `seq`:
  a client must not be able to read the position or diff two cursors to infer a
  gap. Authenticated encryption (random IV) makes tokens opaque and uncorrelatable.
  """
  use ExUnit.Case, async: true

  alias Swarm.Activity.Cursor

  test "round-trips a position" do
    for seq <- [0, 1, 42, 1_000_000, 9_223_372_036_854_775_807] do
      assert {:ok, ^seq} = Cursor.decode(Cursor.encode(seq))
    end
  end

  test "the token does not reveal the raw seq (not the integer, not reversible base64)" do
    token = Cursor.encode(123_456)
    refute token == "123456"
    refute token == Integer.to_string(123_456)
    # A client decoding the token as a plain base64 integer learns nothing usable.
    assert {:ok, raw} = Base.url_decode64(token, padding: false)
    refute raw == <<123_456::64>>
  end

  test "two tokens for the same seq are uncorrelatable (random IV) — no gap diffing" do
    a = Cursor.encode(100)
    b = Cursor.encode(100)
    assert a != b
    assert {:ok, 100} = Cursor.decode(a)
    assert {:ok, 100} = Cursor.decode(b)
  end

  test "tampered / malformed / wrong-shaped tokens decode to :error (caller resyncs)" do
    token = Cursor.encode(7)
    # flip a byte → GCM tag fails
    <<h, rest::binary>> = token
    tampered = <<Bitwise.bxor(h, 1), rest::binary>>
    assert Cursor.decode(tampered) == :error
    assert Cursor.decode("not base64!!") == :error
    assert Cursor.decode("") == :error
    assert Cursor.decode(nil) == :error
    assert Cursor.decode(:nope) == :error
  end
end
