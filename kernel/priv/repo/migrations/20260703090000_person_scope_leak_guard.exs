defmodule Swarm.Repo.Migrations.PersonScopeLeakGuard do
  use Ecto.Migration

  # ADR-16 person-scope-leak-guard — data repair behind the new write-boundary
  # rules (Contract pins `user`-typed nodes to `private`; Identity denies
  # `private` as a grantable scope). The boundary governs new writes; this
  # repairs anything already at rest and adds the DB belt:
  #
  #   1. any edge touching a legacy-wide person node is narrowed FIRST (else
  #      re-pinning the node would leave edge scope wider than an endpoint —
  #      the ADR-5 invariant; council codex);
  #   2. any person (`user`-typed) node wider than `private` is re-pinned —
  #      a wide person node would surface chat-derived facts to scoped reads;
  #   3. any `group_scope_map` row that confers `private` loses it (the read
  #      path also clamps it, belt-and-suspenders);
  #   4. a CHECK constraint makes `user ⇒ private` hold at the DB for any
  #      future raw-SQL writer (defense-in-depth behind the Contract).
  #
  # Idempotent by shape; `down` drops only the constraint (the repaired wide
  # state was the bug, not a restorable feature).

  def up do
    execute("""
    UPDATE edge e
       SET visibility_scope = 'private'
      FROM node n
     WHERE (e.src = n.id OR e.dst = n.id)
       AND n.type = 'user'
       AND e.visibility_scope <> 'private'
    """)

    execute("UPDATE node SET scope = 'private' WHERE type = 'user' AND scope <> 'private'")

    execute("""
    UPDATE group_scope_map
       SET scopes = array_remove(scopes, 'private')
     WHERE 'private' = ANY(scopes)
    """)

    execute("""
    ALTER TABLE node
      ADD CONSTRAINT node_person_scope_private
      CHECK (type <> 'user' OR scope = 'private')
    """)
  end

  def down do
    execute("ALTER TABLE node DROP CONSTRAINT IF EXISTS node_person_scope_private")
  end
end
