defmodule Swarm.ElevationTest do
  @moduledoc """
  Workspace ADR-20 D9 — `superadmin` is a time-boxed, session-bound, re-authenticated,
  audited-before-effect elevation of a local Wheel member; never a standing role.
  """
  use Swarm.IdentityCase, async: false

  alias Swarm.{Actor, Audit, Elevation}

  @sid "sess-1"

  defp wheel_user(login \\ "rootuser") do
    {:ok, u} = Identity.seed_wheel(%{id: Identity.uuid7(), login: login})
    u
  end

  defp reauth(login, opts \\ []) do
    now = System.system_time(:second)

    Actor.sign(
      %{
        "aud" => Keyword.get(opts, :aud, Actor.reauth_audience()),
        "sub" => login,
        "provider" => Keyword.get(opts, :provider, "local"),
        "sid" => Keyword.get(opts, :sid, @sid),
        "jti" =>
          Keyword.get(opts, :jti, "jti-" <> Integer.to_string(System.unique_integer([:positive]))),
        "auth_time" => Keyword.get(opts, :auth_time, now)
      },
      exp_in: Keyword.get(opts, :exp_in, 60)
    )
  end

  defp actor(u, sid \\ @sid), do: %{uuid: u.id, sid: sid}

  defp audit_rows(u, action), do: Audit.for_actor(u.id) |> Enum.filter(&(&1.action == action))

  describe "happy path" do
    test "a local Wheel member elevates: caps appear for THIS session only, roles show superadmin" do
      u = wheel_user()
      # unelevated: daily admin (via admins), no superadmin caps
      assert Identity.roles_for({u.id, @sid}) == ["admin"]
      refute "read_any_conversation" in Identity.caps_for({u.id, @sid})

      assert {:ok, e} = Elevation.request(actor(u), "ticket #42", reauth("rootuser"))
      assert e.user_id == u.id and e.sid == @sid and e.reason == "ticket #42"
      assert DateTime.compare(e.expires_at, DateTime.utc_now()) == :gt

      assert "superadmin" in Identity.roles_for({u.id, @sid})
      caps = Identity.caps_for({u.id, @sid})

      for c <-
            ~w(read_any_conversation manage_wheel manage_roles manage_auth manage_publicness manage_access),
          do: assert(c in caps)

      # another session of the same user is NOT elevated; a bare uuid never is
      refute "read_any_conversation" in Identity.caps_for({u.id, "other-session"})
      refute "read_any_conversation" in Identity.caps_for(u.id)
      assert Elevation.active?(u.id, @sid)
      refute Elevation.active?(u.id, nil)
      assert Elevation.active_holder_count() == 1
    end

    test "Actor.resolve derives the elevated caps for the session in the assertion" do
      u = wheel_user()
      {:ok, _} = Elevation.request(actor(u), "why", reauth("rootuser"))

      t = Actor.sign(%{"sub" => "rootuser", "provider" => "local", "sid" => @sid})
      assert {:ok, a} = Actor.resolve(t)
      assert "read_any_conversation" in a.caps
      assert %DateTime{} = a.elevation_expires_at

      other = Actor.sign(%{"sub" => "rootuser", "provider" => "local", "sid" => "another"})
      assert {:ok, b} = Actor.resolve(other)
      refute "read_any_conversation" in b.caps
      assert b.elevation_expires_at == nil
    end

    test "the audit row exists with the reason and the elevation details" do
      u = wheel_user()
      {:ok, e} = Elevation.request(actor(u), "incident 7", reauth("rootuser"))
      [row] = audit_rows(u, "elevate")
      assert row.decision == "allowed" and row.reason == "incident 7"

      %{rows: [[detail]]} =
        Repo.query!("SELECT detail FROM admin_action_audit WHERE action = 'elevate'")

      assert detail["elevation_id"] == e.id and detail["sid"] == @sid
    end

    test "ttl is clamped to [60, max]" do
      u = wheel_user()
      {:ok, e} = Elevation.request(actor(u), "r", reauth("rootuser"), ttl_s: 999_999)
      assert DateTime.diff(e.expires_at, DateTime.utc_now()) <= Elevation.max_ttl_s()
      :ok = Elevation.end_elevation(actor(u))
      {:ok, e2} = Elevation.request(actor(u), "r", reauth("rootuser"), ttl_s: 1)
      assert DateTime.diff(e2.expires_at, DateTime.utc_now()) >= 55
    end
  end

  describe "the elevation ends" do
    test "expiry: caps vanish without any revocation step" do
      u = wheel_user()
      {:ok, e} = Elevation.request(actor(u), "r", reauth("rootuser"))

      Repo.query!("UPDATE elevation SET expires_at = now() - interval '1 second' WHERE id = $1", [
        Ecto.UUID.dump!(e.id)
      ])

      refute Elevation.active?(u.id, @sid)
      refute "read_any_conversation" in Identity.caps_for({u.id, @sid})
      assert Elevation.active_holder_count() == 0
    end

    test "revocation by the holder is audited; a stranger cannot revoke it" do
      u = wheel_user()
      other = wheel_user("other")
      {:ok, e} = Elevation.request(actor(u), "r", reauth("rootuser"))

      assert Elevation.end_elevation(actor(other), e.id) == :not_authorized
      assert Elevation.active?(u.id, @sid)

      assert :ok = Elevation.end_elevation(actor(u))
      refute Elevation.active?(u.id, @sid)
      assert [%{decision: "allowed"}] = audit_rows(u, "end_elevation")
      assert Elevation.end_elevation(actor(u)) == :not_found
    end

    test "leaving wheel, deactivation and a new external link all kill a live elevation" do
      u = wheel_user()
      {:ok, _} = Elevation.request(actor(u), "r", reauth("rootuser"))
      :ok = Identity.remove_from_group(u.id, "wheel")
      refute Elevation.active?(u.id, @sid)

      v = wheel_user("second")
      {:ok, _} = Elevation.request(actor(v), "r", reauth("second"))
      :ok = Identity.deactivate_user(v.id)
      refute Elevation.active?(v.id, @sid)

      w = wheel_user("third")
      {:ok, _} = Elevation.request(actor(w), "r", reauth("third"))
      # an IdP link appearing on a Wheel account ends its eligibility immediately
      Repo.query!(
        "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'keycloak', 'sub-third')",
        [Ecto.UUID.dump!(w.id)]
      )

      refute Elevation.active?(w.id, @sid)
    end
  end

  describe "refusals (every one audited as a denial)" do
    test "not a Wheel member / not local-only / inactive" do
      {:ok, plain} =
        Identity.upsert_from_claims(%{
          provider: "keycloak",
          subject: "s",
          login: "plain",
          groups: []
        })

      assert Elevation.request(actor(plain), "r", reauth("plain")) == {:error, :not_wheel}
      assert [%{decision: "denied", reason: "not_wheel"}] = audit_rows(plain, "elevate")

      u = wheel_user()

      Repo.query!(
        "INSERT INTO identity_link (user_id, provider, subject) VALUES ($1, 'keycloak', 'sub-root')",
        [Ecto.UUID.dump!(u.id)]
      )

      assert Elevation.request(actor(u), "r", reauth("rootuser")) == {:error, :not_local}
    end

    test "blank reason / missing session" do
      u = wheel_user()
      assert Elevation.request(actor(u), "   ", reauth("rootuser")) == {:error, :reason_required}
      assert Elevation.request(actor(u), nil, reauth("rootuser")) == {:error, :reason_required}

      assert Elevation.request(%{uuid: u.id, sid: nil}, "r", reauth("rootuser")) ==
               {:error, :no_session}
    end

    test "the re-auth proof: stale, wrong audience, wrong subject, wrong session, non-local, too long, garbage" do
      u = wheel_user()
      _other = wheel_user("other")
      now = System.system_time(:second)

      assert Elevation.request(actor(u), "r", reauth("rootuser", auth_time: now - 1000)) ==
               {:error, :reauth_stale}

      # an ACTOR assertion is not a re-auth proof (audience binding)
      actor_token = Actor.sign(%{"sub" => "rootuser", "provider" => "local", "sid" => @sid})
      assert Elevation.request(actor(u), "r", actor_token) == {:error, :reauth_invalid}

      assert Elevation.request(actor(u), "r", reauth("other")) ==
               {:error, :reauth_subject_mismatch}

      assert Elevation.request(actor(u), "r", reauth("rootuser", sid: "elsewhere")) ==
               {:error, :reauth_session_mismatch}

      assert Elevation.request(actor(u), "r", reauth("rootuser", provider: "keycloak")) ==
               {:error, :reauth_subject_mismatch}

      assert Elevation.request(actor(u), "r", reauth("rootuser", exp_in: 290)) ==
               {:error, :reauth_invalid}

      assert Elevation.request(actor(u), "r", "garbage") == {:error, :reauth_invalid}
      assert Elevation.request(actor(u), "r", nil) == {:error, :reauth_invalid}

      refute Elevation.active?(u.id, @sid)
      assert Enum.all?(audit_rows(u, "elevate"), &(&1.decision == "denied"))
      assert length(audit_rows(u, "elevate")) == 8
    end

    test "a replayed proof (same jti) cannot re-elevate" do
      u = wheel_user()
      proof = reauth("rootuser", jti: "one-time")
      assert {:ok, _} = Elevation.request(actor(u), "r", proof)
      :ok = Elevation.end_elevation(actor(u))
      assert Elevation.request(actor(u), "again", proof) == {:error, :reauth_replayed}
      refute Elevation.active?(u.id, @sid)
    end
  end
end
