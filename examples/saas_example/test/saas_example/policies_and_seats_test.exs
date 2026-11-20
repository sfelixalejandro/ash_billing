defmodule SaasExample.PoliciesAndSeatsTest do
  use SaasExampleWeb.ConnCase, async: false

  alias SaasExample.{Accounts, Billing, Workspace}
  alias SaasExample.Billing.Catalog

  test "enforces AshBilling.Checks.Subscribed and AshBilling.Checks.HasPrice across Free, Starter, Pro, Enterprise, and Canceled tiers" do
    free_user = create_user!(%{email: "tier_free@example.com"})

    starter_user =
      create_user!(%{email: "tier_starter@example.com", stripe_customer_id: "cus_t_s"})

    pro_user = create_user!(%{email: "tier_pro@example.com", stripe_customer_id: "cus_t_p"})
    ent_user = create_user!(%{email: "tier_ent@example.com", stripe_customer_id: "cus_t_e"})

    starter_sub =
      create_subscription!(starter_user, %{
        provider_subscription_id: "sub_t_starter",
        price_id: Catalog.price_id!(:starter),
        quantity: 2
      })

    _pro_sub =
      create_subscription!(pro_user, %{
        provider_subscription_id: "sub_t_pro",
        price_id: Catalog.price_id!(:pro),
        quantity: 5
      })

    _ent_sub =
      create_subscription!(ent_user, %{
        provider_subscription_id: "sub_t_ent",
        price_id: Catalog.price_id!(:enterprise),
        quantity: 10
      })

    {:ok, starter_user} = Accounts.load_fresh_actor(starter_user.id)
    {:ok, pro_user} = Accounts.load_fresh_actor(pro_user.id)
    {:ok, ent_user} = Accounts.load_fresh_actor(ent_user.id)

    # Free user denied by Subscribed
    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.create_report(free_user, %{title: "Blocked"})

    assert {:error, :subscription_required} =
             Workspace.assign_seat(free_user, "blocked@example.com")

    # Starter user: allowed by Subscribed, DENIED by HasPrice (Pro Export & Enterprise Audit)
    {:ok, starter_report} = Workspace.create_report(starter_user, %{title: "Starter Report"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.export_report(starter_user, starter_report.id)

    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.audit_report(starter_user, starter_report.id)

    # Pro user: allowed by Pro/Enterprise HasPrice (Export), DENIED by Enterprise-only HasPrice (Audit)
    {:ok, pro_report} = Workspace.create_report(pro_user, %{title: "Pro Report"})
    assert {:ok, exported} = Workspace.export_report(pro_user, pro_report.id)
    assert %DateTime{} = exported.exported_at
    assert {:error, %Ash.Error.Forbidden{}} = Workspace.audit_report(pro_user, pro_report.id)

    # Enterprise user: allowed for both Pro Export and Enterprise Audit
    {:ok, ent_report} = Workspace.create_report(ent_user, %{title: "Enterprise Report"})
    assert {:ok, ent_exp} = Workspace.export_report(ent_user, ent_report.id)
    assert %DateTime{} = ent_exp.exported_at
    assert {:ok, ent_aud} = Workspace.audit_report(ent_user, ent_report.id)
    assert %DateTime{} = ent_aud.audited_at

    # Revocation freshness: once subscription is canceled via webhook, immediate reload revokes access
    canceled_event = %{
      "id" => "evt_tier_cancel_1",
      "type" => "customer.subscription.deleted",
      "livemode" => false,
      "created" => System.system_time(:second),
      "data" => %{
        "object" =>
          stripe_subscription_payload(
            starter_sub.provider_subscription_id,
            "cus_t_s",
            Catalog.price_id!(:starter),
            2,
            status: "canceled"
          )
      }
    }

    assert post_signed_webhook(build_conn(), canceled_event).status == 200

    # HTTP request reloads fresh actor and immediately denies report creation
    denied_conn =
      post(log_in_user(build_conn(), starter_user), "/workspace/reports", %{
        "title" => "After Cancel"
      })

    assert redirected_to(denied_conn) == "/dashboard"
    assert Phoenix.Flash.get(denied_conn.assigns.flash, :error) =~ "Active subscription required"
  end

  test "enforces contracted quantity seat limits, seat-downsize protection, nil/zero quantity fail-closed, and concurrent FOR UPDATE locking" do
    user = create_user!(%{email: "seats_owner@example.com", stripe_customer_id: "cus_seats_1"})

    sub =
      create_subscription!(user, %{
        provider_subscription_id: "sub_seats_1",
        price_id: Catalog.price_id!(:pro),
        quantity: 2,
        provider_subscription_item_id: "si_seats_1"
      })

    {:ok, user} = Accounts.load_fresh_actor(user.id)

    # Assign 2 seats up to contracted quantity: 2
    assert {:ok, seat1} = Workspace.assign_seat(user, "member1@team.example")
    assert {:ok, _seat2} = Workspace.assign_seat(user, "member2@team.example")

    # 3rd seat fails closed with :seat_limit_reached
    assert {:error, {:seat_limit_reached, 2, 2}} =
             Workspace.assign_seat(user, "member3@team.example")

    # Cannot reduce Stripe quantity below 2 active seats (never hits Stripe!)
    configure_stripe_stub(:stripe_should_not_be_called, fn _conn ->
      flunk("Stripe should not be called when active seats exceed requested new quantity")
    end)

    assert {:error, {:seats_exceed_new_quantity, 2}} =
             Billing.update_quantity(user, sub.id, 1)

    # Revoking 1 seat frees capacity for a new member
    assert {:ok, _revoked} = Workspace.revoke_seat(user, seat1.id)
    assert Workspace.active_seat_count(user) == 1

    # Concurrency test: 5 parallel seat assignments racing for the 1 remaining slot
    # PostgreSQL FOR UPDATE row lock ensures EXACTLY 1 succeeds and 4 fail with :seat_limit_reached
    results =
      1..5
      |> Task.async_stream(
        fn i -> Workspace.assign_seat(user, "race_#{i}@team.example") end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    limit_errors = Enum.count(results, &match?({:error, {:seat_limit_reached, 2, 2}}, &1))

    assert successes == 1
    assert limit_errors == 4
    assert Workspace.active_seat_count(user) == 2

    # Zero or nil contracted seats fails closed with :no_contracted_seats
    zero_user = create_user!(%{email: "zero_seats@example.com", stripe_customer_id: "cus_zero"})

    create_subscription!(zero_user, %{
      provider_subscription_id: "sub_zero_seats",
      price_id: Catalog.price_id!(:starter),
      quantity: 0
    })

    {:ok, zero_user} = Accounts.load_fresh_actor(zero_user.id)
    assert {:error, :no_contracted_seats} = Workspace.assign_seat(zero_user, "x@zero.example")

    nil_user = create_user!(%{email: "nil_seats@example.com", stripe_customer_id: "cus_nil"})

    create_subscription!(nil_user, %{
      provider_subscription_id: "sub_nil_seats",
      price_id: Catalog.price_id!(:starter),
      quantity: nil
    })

    {:ok, nil_user} = Accounts.load_fresh_actor(nil_user.id)
    assert {:error, :no_contracted_seats} = Workspace.assign_seat(nil_user, "x@nil.example")
  end

  test "deterministically serializes concurrent quantity downsize (2 -> 1) against seat assignment in BOTH lock orders" do
    # -------------------------------------------------------------------------
    # Interleaving A: update_quantity(2 -> 1) acquires lock first; assign_seat waits
    # -------------------------------------------------------------------------
    user_a = create_user!(%{email: "race_a@example.com", stripe_customer_id: "cus_race_a"})

    sub_a =
      create_subscription!(user_a, %{
        provider_subscription_id: "sub_race_a",
        price_id: Catalog.price_id!(:pro),
        quantity: 2,
        provider_subscription_item_id: "si_race_a"
      })

    {:ok, user_a} = Accounts.load_fresh_actor(user_a.id)
    assert {:ok, _seat1} = Workspace.assign_seat(user_a, "existing_a@team.example")
    assert Workspace.active_seat_count(user_a) == 1

    {:ok, stripe_state_a} = Agent.start_link(fn -> %{quantity: 2, updates: 0} end)
    test_pid = self()

    configure_stripe_stub(:stripe_race_a, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/v1/subscriptions/sub_race_a"} ->
          qty = Agent.get(stripe_state_a, & &1.quantity)

          Req.Test.json(
            conn,
            stripe_subscription_payload(
              "sub_race_a",
              "cus_race_a",
              Catalog.price_id!(:pro),
              qty,
              item_id: "si_race_a"
            )
          )

        {"POST", "/v1/subscriptions/sub_race_a"} ->
          # Pause deterministically while update_quantity holds users + subscriptions FOR UPDATE locks
          send(test_pid, {:stripe_update_entered, self()})

          receive do
            :release_stripe_update -> :ok
          after
            5_000 -> flunk("Timed out waiting to release Stripe stub")
          end

          [_, qty_str] = Regex.run(~r/quantity%5D=(\d+)/, body)
          new_qty = String.to_integer(qty_str)

          Agent.update(stripe_state_a, fn st ->
            %{st | quantity: new_qty, updates: st.updates + 1}
          end)

          Req.Test.json(
            conn,
            stripe_subscription_payload(
              "sub_race_a",
              "cus_race_a",
              Catalog.price_id!(:pro),
              new_qty,
              item_id: "si_race_a"
            )
          )
      end
    end)

    qty_task_a =
      Task.async(fn ->
        Billing.update_quantity(user_a, sub_a.id, 1)
      end)

    assert_receive {:stripe_update_entered, stripe_stub_pid}, 5_000

    # Launch racing seat assignment while update_quantity holds the PostgreSQL FOR UPDATE lock
    seat_task_a =
      Task.async(fn ->
        Workspace.assign_seat(user_a, "racing_seat2_a@team.example")
      end)

    # Deterministically verify via PostgreSQL pg_stat_activity that seat_task_a is blocked on the row lock
    wait_for_pg_lock_wait!()

    # Release Stripe HTTP call so update_quantity finishes and commits quantity = 1
    send(stripe_stub_pid, :release_stripe_update)

    assert {:ok, _remote_sub} = Task.await(qty_task_a, 5_000)
    assert {:error, {:seat_limit_reached, 1, 1}} = Task.await(seat_task_a, 5_000)

    # Verify final invariant in BOTH simulated Stripe and PostgreSQL: active_seats (1) <= quantity (1)
    assert Agent.get(stripe_state_a, & &1) == %{quantity: 1, updates: 1}

    reloaded_sub_a =
      Ash.get!(SaasExample.Billing.Subscription, sub_a.id, domain: Billing, authorize?: false)

    assert reloaded_sub_a.quantity == 1
    assert Workspace.active_seat_count(user_a) == 1

    # -------------------------------------------------------------------------
    # Interleaving B: assign_seat acquires lock first; update_quantity(2 -> 1) waits
    # -------------------------------------------------------------------------
    user_b = create_user!(%{email: "race_b@example.com", stripe_customer_id: "cus_race_b"})

    sub_b =
      create_subscription!(user_b, %{
        provider_subscription_id: "sub_race_b",
        price_id: Catalog.price_id!(:pro),
        quantity: 2,
        provider_subscription_item_id: "si_race_b"
      })

    {:ok, user_b} = Accounts.load_fresh_actor(user_b.id)
    assert {:ok, _seat1} = Workspace.assign_seat(user_b, "existing_b@team.example")
    assert Workspace.active_seat_count(user_b) == 1

    {:ok, stripe_state_b} = Agent.start_link(fn -> %{quantity: 2, updates: 0} end)

    configure_stripe_stub(:stripe_race_b, fn conn ->
      Agent.update(stripe_state_b, fn st -> %{st | updates: st.updates + 1} end)

      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"error" => %{"message" => "Stripe should not be called"}})
    end)

    seat_task_b =
      Task.async(fn ->
        Workspace.assign_seat(user_b, "racing_seat2_b@team.example",
          on_locked: fn ->
            send(test_pid, {:seat_lock_acquired, self()})

            receive do
              :release_seat_lock -> :ok
            after
              5_000 -> flunk("Timed out waiting to release seat lock")
            end
          end
        )
      end)

    assert_receive {:seat_lock_acquired, seat_worker_pid}, 5_000

    # Launch racing quantity downsize while assign_seat holds the PostgreSQL FOR UPDATE lock
    qty_task_b =
      Task.async(fn ->
        Billing.update_quantity(user_b, sub_b.id, 1)
      end)

    # Deterministically verify via PostgreSQL pg_stat_activity that qty_task_b is blocked on the row lock
    wait_for_pg_lock_wait!()

    # Release assign_seat so seat #2 commits first (active_seats becomes 2)
    send(seat_worker_pid, :release_seat_lock)

    assert {:ok, _seat2} = Task.await(seat_task_b, 5_000)
    assert {:error, {:seats_exceed_new_quantity, 2}} = Task.await(qty_task_b, 5_000)

    # Verify final invariant in BOTH simulated Stripe (0 calls!) and PostgreSQL: active_seats (2) <= quantity (2)
    assert Agent.get(stripe_state_b, & &1) == %{quantity: 2, updates: 0}

    reloaded_sub_b =
      Ash.get!(SaasExample.Billing.Subscription, sub_b.id, domain: Billing, authorize?: false)

    assert reloaded_sub_b.quantity == 2
    assert Workspace.active_seat_count(user_b) == 2
  end

  defp wait_for_pg_lock_wait!(deadline_ms \\ System.monotonic_time(:millisecond) + 5_000) do
    %{rows: [[waiting_count]]} =
      Ecto.Adapters.SQL.query!(
        SaasExample.Repo,
        """
        SELECT count(*)
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND pid <> pg_backend_pid()
          AND wait_event_type = 'Lock'
        """,
        []
      )

    cond do
      waiting_count >= 1 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("Timed out waiting for PostgreSQL FOR UPDATE lock contention in pg_stat_activity")

      true ->
        :erlang.yield()
        wait_for_pg_lock_wait!(deadline_ms)
    end
  end
end
