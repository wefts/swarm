defmodule Swarm.IdentityTest do
  @moduledoc """
  Workspace ADR-16 step 1 — the kernel identity store. The kernel owns the
  minimal authorization record (uuid + login + emails + identity-links + group/
  scope grants + roles). JIT-provisioned from *already-verified* claims (the
  cryptographic verification is step 2); the store here trusts its caller to have
  verified, and is the sole record of who-may-do-what.

  No credentials or SSO subjects-as-secrets live here beyond the opaque link
  subject; password hashes stay channel-side (hive).
  """
  use Swarm.IdentityCase, async: false

  # A representative set of verified OIDC-shaped claims (the shape step 2 hands in).
  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        provider: "keycloak",
        subject: "sub-penta-0001",
        login: "penta",
        first_name: "Pentti",
        last_name: "Tester",
        nickname: nil,
        emails: [%{email: "penta@example.test", verified: true, primary: true}],
        groups: ["staff"]
      },
      overrides
    )
  end

  describe "uuid7/0" do
    test "generates a syntactically valid, version-7 UUID" do
      u = Identity.uuid7()

      assert u =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      # Distinct calls are distinct.
      refute Identity.uuid7() == u
    end

    test "is time-ordered: a uuid minted in a later millisecond sorts after an earlier one" do
      a = Identity.uuid7()
      # v7 embeds a MILLISECOND timestamp in the high 48 bits → index locality.
      # Same-ms uuids order by random bits (RFC 9562); across a ms boundary they
      # sort chronologically, which is the property the PK relies on.
      Process.sleep(2)
      b = Identity.uuid7()
      assert a < b
    end
  end

  describe "upsert_from_claims/1 — JIT provisioning" do
    test "creates a new active user with login, names, email and group membership" do
      assert {:ok, u} = Identity.upsert_from_claims(claims())

      assert u.login == "penta"
      assert u.first_name == "Pentti"
      assert u.last_name == "Tester"
      assert u.status == "active"
      assert u.id =~ ~r/^[0-9a-f-]{36}$/

      # email recorded, primary + verified
      assert [%{email: "penta@example.test", is_primary: true} = e] = Identity.emails_for(u.id)
      assert e.verified_at != nil

      # group membership recorded (idp-sourced)
      assert "staff" in Identity.groups_for(u.id)
    end

    test "is idempotent on (provider, subject): a second login resolves to the SAME uuid" do
      {:ok, u1} = Identity.upsert_from_claims(claims())
      {:ok, u2} = Identity.upsert_from_claims(claims())
      assert u1.id == u2.id
      # one user, one identity_link
      assert Identity.count_users() == 1
    end

    test "updates mutable attributes and last_login_at on re-login" do
      {:ok, u1} = Identity.upsert_from_claims(claims())
      first_login = Identity.get_user(u1.id).last_login_at

      {:ok, u2} =
        Identity.upsert_from_claims(claims(%{first_name: "Penny", groups: ["staff", "admins"]}))

      assert u2.id == u1.id
      assert u2.first_name == "Penny"
      assert Enum.sort(Identity.groups_for(u2.id)) == ["admins", "staff"]
      assert first_login != nil
      assert DateTime.compare(Identity.get_user(u2.id).last_login_at, first_login) != :lt
    end

    test "matches on stable subject, not login: a renamed login stays one uuid" do
      {:ok, u1} = Identity.upsert_from_claims(claims())
      {:ok, u2} = Identity.upsert_from_claims(claims(%{login: "penta2"}))
      assert u2.id == u1.id
      assert u2.login == "penta2"
      assert Identity.by_login("penta") == nil
      assert Identity.by_login("penta2").id == u1.id
    end

    test "revokes group membership no longer present in the claims (default-deny)" do
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["staff", "admins"]}))
      assert Enum.sort(Identity.groups_for(u.id)) == ["admins", "staff"]

      {:ok, _} = Identity.upsert_from_claims(claims(%{groups: ["staff"]}))
      assert Identity.groups_for(u.id) == ["staff"]
    end
  end

  describe "scope resolution (group → group_scope_map, default-deny)" do
    test "no group_scope_map ⇒ only the authenticated public baseline" do
      # default-deny holds ABOVE public: an unmapped group confers nothing, but any
      # active authenticated actor reads public knowledge (the channel's documented
      # boundary semantic, restored kernel-side after the staging KB-dead regression).
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["staff"]}))
      assert Identity.scopes_for(u.id) == ["public"]
    end

    test "a group's mapped scopes are conferred, unioned across groups, deduped" do
      Identity.put_group_scopes("staff", ["public"])
      Identity.put_group_scopes("nebula", ["public", "group"])
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["staff", "nebula"]}))
      assert Enum.sort(Identity.scopes_for(u.id)) == ["group", "public"]
    end
  end

  describe "grant-boundary scope validation (person-scope-leak-guard)" do
    # `private` is the default-deny floor AND the chat-privacy mechanism — conferring
    # it to any group would expose every user's private facts. Hard-denied here,
    # the deepest grant boundary (Admin + the RPC route through this).
    test "put_group_scopes hard-denies private as a grantable scope, writing nothing" do
      assert Identity.put_group_scopes("nebula", ["public", "private"]) ==
               {:error, :ungrantable_scope}

      # nothing was written — a member of the group derives only the baseline
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["nebula"]}))
      assert Identity.scopes_for(u.id) == ["public"]
    end

    test "put_group_scopes accepts source scopes but still rejects private" do
      assert Identity.put_group_scopes("nebula", ["src:wiki", "public"]) == :ok
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["nebula"]}))
      assert Enum.sort(Identity.scopes_for(u.id)) == ["public", "src:wiki"]

      assert Identity.put_group_scopes("nebula", ["private"]) ==
               {:error, :ungrantable_scope}
    end

    test "put_group_scopes rejects out-of-vocabulary scopes (Contract check)" do
      assert Identity.put_group_scopes("nebula", ["group", "secret"]) ==
               {:error, :ungrantable_scope}

      assert Identity.grantable_scopes() == ["group", "public"]
    end

    test "scopes_for never derives private even from a corrupted scope map (belt)" do
      # Simulate legacy/raw-SQL corruption that bypassed the grant boundary.
      Identity.put_group_scopes("staff", ["public"])
      {:ok, u} = Identity.upsert_from_claims(claims(%{groups: ["staff"]}))

      Swarm.Repo.query!(
        "UPDATE group_scope_map SET scopes = $2 WHERE group_id = $1",
        ["staff", ["public", "private"]]
      )

      assert Identity.scopes_for(u.id) == ["public"]
    end
  end

  describe "seed_superadmin/1 — the root/uid-0 mechanism" do
    test "creates a local active user with a superadmin role_grant, idempotently" do
      vanity = "01920000-0000-7000-8000-00000000da7a"
      assert {:ok, u} = Identity.seed_superadmin(%{id: vanity, login: "rootuser"})
      assert u.id == vanity
      assert u.status == "active"
      assert "superadmin" in Identity.roles_for(u.id)

      # idempotent — no duplicate user, no duplicate grant
      assert {:ok, u2} = Identity.seed_superadmin(%{id: vanity, login: "rootuser"})
      assert u2.id == vanity
      assert Identity.count_users() == 1
      assert Identity.roles_for(u.id) == ["superadmin"]
    end
  end

  describe "roles (default-deny, source-agnostic)" do
    test "a fresh user holds no roles" do
      {:ok, u} = Identity.upsert_from_claims(claims())
      assert Identity.roles_for(u.id) == []
    end
  end
end
