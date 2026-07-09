defmodule Swarm.CoreConversationContextTest do
  @moduledoc """
  Chat-thread epic 2 (hive/docs/design/chat-thread-ui.md): `Core.ask/2` folds
  recent conversation history into the consilium grounding when a
  `conversation_id` is present, reusing the ADR-16 `Conversations`
  owner-enforcement predicate exactly — a `viewer` that doesn't own the
  conversation (or isn't a real actor uuid) must silently get NO history,
  never an error or a leak.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.Conversations

  # escalate_opts mirrors core_test.exs's helper — a generator that ALSO
  # captures the prompt it was asked to synthesize/panel-take on, so tests can
  # assert on what grounding actually reached the "LLM".
  defp escalate_opts_capturing(test_pid) do
    generator = fn _model, prompt, opts ->
      send(test_pid, {:prompt, prompt})

      if Keyword.get(opts, :json),
        do: {:ok, ~s({"answer": "synthesized verdict", "confidence": 0.8, "supported": true})},
        else: {:ok, "panel take"}
    end

    [
      scopes: ["public"],
      prototypes: [%{intent: :recall, tier: :tier_tools, text: "T"}],
      embedder: fn
        "T" -> {:ok, [1.0, 0.0, 0.0]}
        _ -> {:ok, [0.0, 0.0, 1.0]}
      end,
      bands: %Swarm.Gate.Bands{handle: 0.5},
      fleet: %{panel: ["m1"], judge: "j"},
      generator: generator,
      retriever: fn _q, _s, _o -> {:ok, []} end
    ]
  end

  defp provision(login) do
    {:ok, u} =
      Swarm.Identity.upsert_from_claims(%{provider: "local", subject: login, login: login})

    u
  end

  defp all_prompts do
    receive do
      {:prompt, p} -> [p | all_prompts()]
    after
      0 -> []
    end
  end

  test "conversation_id folds recent history into the consilium grounding" do
    alice = provision("alice")
    {:ok, c} = Conversations.create(alice.id, %{title: "t"})
    {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "what is Foo?"})

    {:ok, _} =
      Conversations.add_message(alice.id, c.id, %{role: "assistant", body: "Foo is a service."})

    # `verified: true` = a VERIFIED owner (server derives it from a resolved assertion). History is
    # folded ONLY for a verified viewer (dual-mode-history-leak) — a forged plaintext viewer gets none.
    opts =
      escalate_opts_capturing(self()) ++ [viewer: alice.id, conversation_id: c.id, verified: true]

    a = Swarm.Core.ask("and its dependencies?", opts)

    assert a.tier == "escalate"
    prompts = all_prompts()
    assert prompts != []
    assert Enum.any?(prompts, &(&1 =~ "what is Foo?" and &1 =~ "Foo is a service."))
  end

  test "no conversation_id ⇒ no history block (unchanged behavior)" do
    alice = provision("alice")
    {:ok, c} = Conversations.create(alice.id, %{title: "t"})
    {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "secret turn"})

    opts = escalate_opts_capturing(self()) ++ [viewer: alice.id]
    a = Swarm.Core.ask("anything", opts)

    assert a.tier == "escalate"
    refute Enum.any?(all_prompts(), &(&1 =~ "secret turn"))
  end

  test "dual-mode impersonation: an UNVERIFIED viewer never folds history, even with the owner's own uuid + conversation (dual-mode-history-leak)" do
    # The attack: under :dual, `viewer` is attacker-controllable plaintext. Set it to the VICTIM's
    # real uuid + the victim's conversation id — the owner predicate would be satisfied. The
    # verified? gate blocks it: without a resolved assertion (verified: false) history is NEVER folded.
    alice = provision("alice")
    {:ok, c} = Conversations.create(alice.id, %{title: "t"})

    {:ok, _} =
      Conversations.add_message(alice.id, c.id, %{role: "user", body: "alice-secret-XYZ"})

    opts =
      escalate_opts_capturing(self()) ++
        [viewer: alice.id, conversation_id: c.id, verified: false]

    _ = Swarm.Core.ask("summarize our conversation", opts)
    refute Enum.any?(all_prompts(), &(&1 =~ "alice-secret-XYZ"))
  end

  test "a viewer who does NOT own the conversation gets no history (no-leak, no error)" do
    alice = provision("alice")
    bob = provision("bob")
    {:ok, c} = Conversations.create(alice.id, %{title: "t"})
    {:ok, _} = Conversations.add_message(alice.id, c.id, %{role: "user", body: "alice-secret"})

    opts = escalate_opts_capturing(self()) ++ [viewer: bob.id, conversation_id: c.id]
    a = Swarm.Core.ask("anything", opts)

    assert a.tier == "escalate"
    refute Enum.any?(all_prompts(), &(&1 =~ "alice-secret"))
  end

  test "a plaintext (non-uuid) viewer — the legacy dual-accept fallback — never crashes and gets no history" do
    {:ok, c} = Conversations.create(provision("alice").id, %{title: "t"})

    opts = escalate_opts_capturing(self()) ++ [viewer: "not-a-uuid-login", conversation_id: c.id]
    a = Swarm.Core.ask("anything", opts)

    assert a.tier == "escalate"
  end
end
