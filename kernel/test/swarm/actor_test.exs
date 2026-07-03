defmodule Swarm.ActorTest do
  @moduledoc """
  Workspace ADR-16 step 2 (Decision 9) — the crux. The kernel does NOT trust a
  plaintext `{viewer, scopes}`. Each request carries a **signed** actor assertion
  (HS256 JWT, shared secret, single box); the kernel verifies it and **derives**
  the effective `{uuid, scopes, caps}` from its OWN records (identity_link →
  app_user → group_scope_map / role_grant). A channel bug / stale session /
  confused deputy cannot spoof identity or widen scope.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.Actor

  @secret "actor-test-secret-do-not-ship"

  # Sign with a chosen secret/exp for adversarial cases; Actor.sign uses config.
  defp token(claims, opts) do
    Actor.sign(claims, Keyword.put_new(opts, :secret, @secret))
  end

  defp provision_penta(groups \\ ["staff"]) do
    {:ok, u} =
      Identity.upsert_from_claims(%{
        provider: "keycloak",
        subject: "sub-penta-0001",
        login: "penta",
        emails: [%{email: "penta@example.test", verified: true, primary: true}],
        groups: groups
      })

    u
  end

  describe "sign/verify (HS256, strict)" do
    test "round-trips the claims" do
      t = token(%{"sub" => "s1", "provider" => "keycloak", "sid" => "sess1"}, exp_in: 300)
      assert {:ok, claims} = Actor.verify(t, secret: @secret)
      assert claims["sub"] == "s1"
      assert claims["provider"] == "keycloak"
      assert claims["sid"] == "sess1"
    end

    test "rejects a tampered payload (signature mismatch)" do
      t = token(%{"sub" => "s1", "provider" => "keycloak"}, exp_in: 300)
      [h, _p, s] = String.split(t, ".")

      forged_payload =
        Base.url_encode64(~s({"sub":"admin","provider":"keycloak"}), padding: false)

      tampered = Enum.join([h, forged_payload, s], ".")
      assert {:error, :bad_signature} = Actor.verify(tampered, secret: @secret)
    end

    test "rejects a token signed with a different secret" do
      t = token(%{"sub" => "s1", "provider" => "keycloak"}, exp_in: 300, secret: "other-secret")
      assert {:error, :bad_signature} = Actor.verify(t, secret: @secret)
    end

    test "rejects an expired token (past the clock-skew leeway)" do
      t = token(%{"sub" => "s1", "provider" => "keycloak"}, exp_in: -300)
      assert {:error, :expired} = Actor.verify(t, secret: @secret)
    end

    test "accepts a just-expired token within the small clock-skew leeway" do
      t = token(%{"sub" => "s1", "provider" => "keycloak"}, exp_in: -5)
      assert {:ok, _} = Actor.verify(t, secret: @secret, leeway_s: 30)
    end

    test "rejects the alg-confusion 'none' token (unsigned)" do
      header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
      payload = Base.url_encode64(~s({"sub":"admin","provider":"keycloak"}), padding: false)
      none_token = header <> "." <> payload <> "."
      assert {:error, _} = Actor.verify(none_token, secret: @secret)
    end

    test "rejects a malformed token" do
      assert {:error, _} = Actor.verify("not-a-token", secret: @secret)
      assert {:error, _} = Actor.verify("", secret: @secret)
    end

    test "rejects a well-signed token with the wrong audience (cross-JWT confusion)" do
      # A token correctly signed with our secret but for a DIFFERENT purpose/audience
      # (e.g. a session cookie JWT that happens to share the secret) must not resolve
      # as an actor assertion. Sign a raw payload bypassing sign/2's aud injection.
      now = System.system_time(:second)
      header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{
            "sub" => "s1",
            "provider" => "keycloak",
            "aud" => "other-app",
            "exp" => now + 3600
          }),
          padding: false
        )

      si = header <> "." <> payload
      sig = Base.url_encode64(:crypto.mac(:hmac, :sha256, @secret, si), padding: false)
      assert {:error, :bad_audience} = Actor.verify(si <> "." <> sig, secret: @secret)
    end
  end

  describe "resolve/1 — verify then DERIVE from the kernel's own records" do
    test "a valid assertion resolves to the derived uuid, scopes and caps" do
      Identity.put_group_scopes("staff", ["public"])
      Identity.put_group_scopes("nebula", ["public", "group"])
      u = provision_penta(["staff", "nebula"])

      t =
        token(%{"sub" => "sub-penta-0001", "provider" => "keycloak", "sid" => "x"}, exp_in: 300)

      assert {:ok, actor} = Actor.resolve(t, secret: @secret)
      assert actor.uuid == u.id
      assert actor.login == "penta"
      # scopes come from the STORE, not the token (which carries none)
      assert Enum.sort(actor.scopes) == ["group", "public"]
      # a plain user has no capabilities (default-deny)
      assert actor.caps == []
    end

    test "scopes are DERIVED — a token cannot widen them (it carries no scopes)" do
      Identity.put_group_scopes("staff", ["public"])
      provision_penta(["staff"])
      t = token(%{"sub" => "sub-penta-0001", "provider" => "keycloak"}, exp_in: 300)
      assert {:ok, actor} = Actor.resolve(t, secret: @secret)
      assert actor.scopes == ["public"]
    end

    test "superadmin caps include read_any_conversation (local account resolves via its link)" do
      vanity = "01920000-0000-7000-8000-00000000da7a"
      {:ok, u} = Identity.seed_superadmin(%{id: vanity, login: "rootuser"})
      # a local superadmin logs in with provider "local"; seed_superadmin created the
      # matching local identity_link (subject = login) so resolve finds them uniformly.
      t = token(%{"sub" => "rootuser", "provider" => "local"}, exp_in: 300)
      assert {:ok, actor} = Actor.resolve(t, secret: @secret)
      assert actor.uuid == u.id
      assert "read_any_conversation" in actor.caps
      assert "manage_access" in actor.caps
      assert "manage_users" in actor.caps
    end

    test "an unknown (provider, subject) ⇒ :unknown_actor (not provisioned)" do
      t = token(%{"sub" => "ghost", "provider" => "keycloak"}, exp_in: 300)
      assert {:error, :unknown_actor} = Actor.resolve(t, secret: @secret)
    end

    test "a bad signature never reaches the store ⇒ :bad_signature" do
      provision_penta()

      t =
        token(%{"sub" => "sub-penta-0001", "provider" => "keycloak"},
          exp_in: 300,
          secret: "wrong"
        )

      assert {:error, :bad_signature} = Actor.resolve(t, secret: @secret)
    end

    test "an expired assertion ⇒ :expired (even for a real user)" do
      provision_penta()
      t = token(%{"sub" => "sub-penta-0001", "provider" => "keycloak"}, exp_in: -300)
      assert {:error, :expired} = Actor.resolve(t, secret: @secret)
    end
  end

  describe "TTL sanity + audience binding (jit-provision hardening, council codex)" do
    test "a token whose lifetime exceeds the 300s wire contract is rejected" do
      t = token(%{"sub" => "s1", "provider" => "keycloak"}, exp_in: 3600)
      assert {:error, :invalid_claims} = Actor.verify(t, secret: @secret)
    end

    test "a token with iat in the future is rejected" do
      now = System.system_time(:second)

      t =
        token(%{"sub" => "s1", "provider" => "keycloak", "iat" => now + 600},
          exp: now + 700
        )

      assert {:error, :invalid_claims} = Actor.verify(t, secret: @secret)
    end

    test "verify/2 binds the audience — an actor token is not a provision token" do
      actor_t = token(%{"sub" => "s1", "provider" => "keycloak"}, exp_in: 300)

      assert {:error, :bad_audience} =
               Actor.verify(actor_t, secret: @secret, audience: "swarm.provision.v1")

      prov_t =
        token(
          %{"aud" => "swarm.provision.v1", "sub" => "s1", "provider" => "keycloak"},
          exp_in: 300
        )

      # the provision token is NOT a valid actor assertion (default audience)
      assert {:error, :bad_audience} = Actor.verify(prov_t, secret: @secret)

      assert {:ok, _} =
               Actor.verify(prov_t, secret: @secret, audience: "swarm.provision.v1")
    end
  end

  describe "verify_provision/2 — the ADR-16 D3 JIT wire contract" do
    test "extracts the full bound claim set from a valid provision token" do
      t =
        token(
          %{
            "aud" => "swarm.provision.v1",
            "sub" => "sub-newbie",
            "provider" => "keycloak",
            "login" => "newbie",
            "first_name" => "New",
            "email" => "new@example.test",
            "groups" => ["staff", 42, ""]
          },
          exp_in: 300
        )

      assert {:ok, claims} = Actor.verify_provision(t, secret: @secret)
      assert claims.provider == "keycloak"
      assert claims.subject == "sub-newbie"
      assert claims.login == "newbie"
      assert claims.first_name == "New"
      # non-string / blank group entries are dropped, never crash
      assert claims.groups == ["staff"]
      assert [%{email: "new@example.test", verified: true, primary: true}] = claims.emails
    end

    test "a provision token without a login is invalid (fail-closed)" do
      t =
        token(
          %{"aud" => "swarm.provision.v1", "sub" => "s", "provider" => "keycloak"},
          exp_in: 300
        )

      assert {:error, :invalid_claims} = Actor.verify_provision(t, secret: @secret)
    end
  end
end
