defmodule Swarm.ConversationAccessGuardTest do
  @moduledoc """
  Structural guard (workspace ADR-16 step 3, council: codex + gemini). While RLS is
  dormant under the superuser connection, the per-user privacy invariant rests on
  the `Swarm.Conversations` choke point. This test fails if any OTHER kernel source
  reaches the `conversation` / `message` tables in raw SQL — so a future export /
  admin / search path cannot silently bypass the owner predicate. (Step 4's admin
  break-glass must also route through the choke point, not raw SQL.)
  """
  use ExUnit.Case, async: true

  @allowed ["conversations.ex"]
  # SQL table access verbs immediately followed by the owned table names.
  @forbidden ~r/\b(from|into|update|join)\s+(conversation|message)\b/i

  test "no kernel source outside Swarm.Conversations reads/writes the owned tables in raw SQL" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(fn path -> Enum.any?(@allowed, &String.ends_with?(path, &1)) end)
      |> Enum.filter(fn path -> path |> File.read!() |> String.match?(@forbidden) end)

    assert offenders == [],
           """
           These kernel sources touch the `conversation`/`message` tables in raw SQL
           outside Swarm.Conversations — route them through the choke point (owner
           predicate + RLS GUC) so per-user privacy cannot be bypassed:

           #{Enum.join(offenders, "\n")}
           """
  end
end
