defmodule AshBilling.SecurityRegression.PendingProvider do
  def get_subscription(id, opts) do
    send(opts[:owner], {:snapshot_requested, self(), id})

    receive do
      {:snapshot, object} -> {:ok, object}
    after
      3000 -> {:error, :timeout}
    end
  end

  def create_customer(_, opts),
    do: {:ok, Keyword.get(opts, :new_customer_id, "cus_replacement_audit")}
end

defmodule AshBilling.SecurityRegression.BlockingHandler do
  def handle_event(event) do
    owner = Process.whereis(AshBilling.SecurityRegression.Owner)
    send(owner, {:handled, self(), event["id"]})

    receive do
      :finish -> :ok
    after
      3000 -> {:error, :timeout}
    end
  end
end

defmodule AshBilling.SecurityRegression.FenceProvider do
  def verify_webhook(payload, signature, secret, opts) do
    result = AshBilling.Providers.Stripe.verify_webhook(payload, signature, secret, opts)
    send(opts[:owner], {:verified, self()})
    result
  end
end

defmodule AshBilling.SecurityRegression.LockPrepare do
  use Ash.Resource.Preparation

  def prepare(query, _, _) do
    if owner = Process.get(:audit_owner) do
      send(owner, {:locked_read, self()})

      receive do
        :finish -> :ok
      end
    end

    query
  end
end

defmodule AshBilling.SecurityRegression.LockDomain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBilling.SecurityRegression.LockEvent
  end
end

defmodule AshBilling.SecurityRegression.LockEvent do
  use Ash.Resource,
    domain: AshBilling.SecurityRegression.LockDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshBilling.WebhookEvent],
    validate_domain_inclusion?: false

  actions do
    default_accept :*
    defaults [:create, :update, :destroy]

    read :read do
      primary? true
      prepare AshBilling.SecurityRegression.LockPrepare
    end
  end
end

defmodule AshBilling.SecurityRegression.SecurityTest do
  use ExUnit.Case, async: false
  alias AshBilling.Test.{PostgresCustomer, PostgresSubscription, PostgresDomain, Repo}
  @ash [domain: PostgresDomain, authorize?: false]
  @sync @ash ++ [customer_resource: PostgresCustomer, subscription_resource: PostgresSubscription]
  defp id(prefix), do: prefix <> Ash.UUID.generate()

  defp event(type, object, timestamp \\ 1_700_000_000) do
    %{
      "id" => id("evt_audit_"),
      "created" => timestamp,
      "type" => type,
      "data" => %{"object" => object}
    }
  end

  defp object(sub, customer, status, price) do
    %{
      "id" => sub,
      "customer" => customer,
      "status" => status,
      "items" => %{"data" => [%{"price" => %{"id" => price}}]}
    }
  end

  defp fixture do
    cus = id("cus_audit_")
    user = Ash.create!(PostgresCustomer, %{stripe_customer_id: cus}, @ash)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: user.id,
          provider_subscription_id: id("sub_audit_"),
          status: :active,
          price_id: "price_basic",
          last_event_created_at: DateTime.from_unix!(1_700_000_000)
        },
        @ash
      )

    on_exit(fn ->
      Ash.destroy(sub, @ash)
      Ash.destroy(user, @ash)
    end)

    {user, sub, cus}
  end

  defp request(event, opts) do
    payload = Jason.encode!(event)
    ts = System.system_time(:second)
    secret = "whsec_audit"
    sig = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)

    conn =
      Plug.Test.conn(:post, "/webhooks/stripe", payload)
      |> Plug.Conn.put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")

    AshBilling.Plug.call(conn, [webhook_secret: secret] ++ opts)
  end

  test "F1 deleted customer revokes subscriptions and retains a deletion tombstone" do
    {user, sub, cus} = fixture()

    assert {:ok, _} =
             AshBilling.WebhookSync.sync_event(event("customer.deleted", %{"id" => cus}), @sync)

    assert {:ok, _} =
             AshBilling.WebhookSync.sync_event(
               event(
                 "customer.subscription.deleted",
                 object(sub.provider_subscription_id, cus, "canceled", "price_basic"),
                 1_700_000_001
               ),
               @sync
             )

    persisted = Ash.get!(PostgresSubscription, sub.id, @ash)
    assert persisted.status == :canceled
    refute AshBilling.subscribed?(%{subscriptions: [persisted]})
    deleted = Ash.get!(PostgresCustomer, user.id, @ash)
    assert deleted.stripe_customer_id == cus
    assert deleted.billing_deleted_at
    refute AshBilling.subscribed?(%{deleted | subscriptions: [sub]})

    assert {:ok, :customer_deleted} =
             AshBilling.WebhookSync.sync_event(
               event(
                 "customer.subscription.created",
                 object(id("sub_late_"), cus, "active", "price_premium")
               ),
               @sync
             )
  end

  test "F2 serializes same-second snapshots before querying the provider" do
    {_user, sub, cus} = fixture()
    owner = self()
    opts = [provider: AshBilling.SecurityRegression.PendingProvider, owner: owner] ++ @sync
    premium = object(sub.provider_subscription_id, cus, "active", "price_premium")
    basic = object(sub.provider_subscription_id, cus, "active", "price_cheaper")

    first =
      Task.async(fn ->
        AshBilling.WebhookSync.sync_event(event("customer.subscription.updated", premium), opts)
      end)

    assert_receive {:snapshot_requested, first_worker, _}, 2000

    second =
      Task.async(fn ->
        send(owner, :second_started)
        AshBilling.WebhookSync.sync_event(event("customer.subscription.updated", basic), opts)
      end)

    assert_receive :second_started
    refute_receive {:snapshot_requested, _, _}
    send(first_worker, {:snapshot, premium})
    assert {:ok, _} = Task.await(first)
    assert_receive {:snapshot_requested, second_worker, _}, 2000
    send(second_worker, {:snapshot, basic})
    assert {:ok, _} = Task.await(second)
    persisted = Ash.get!(PostgresSubscription, sub.id, @ash)
    assert persisted.price_id == "price_cheaper"
    refute AshBilling.subscribed?(%{subscriptions: [persisted]}, "price_premium")
  end

  test "F2 reconciles same-second trial expiry instead of trusting a stale extension" do
    {_user, sub, cus} = fixture()
    expired = DateTime.add(DateTime.utc_now(), -60)
    Ash.update!(sub, %{status: :trialing, trial_ends_at: expired}, @ash)

    stale =
      object(sub.provider_subscription_id, cus, "trialing", "price_basic")
      |> Map.put("trial_end", System.system_time(:second) + 86400)

    owner = self()

    task =
      Task.async(fn ->
        AshBilling.WebhookSync.sync_event(
          event("customer.subscription.updated", stale),
          [provider: AshBilling.SecurityRegression.PendingProvider, owner: owner] ++ @sync
        )
      end)

    assert_receive {:snapshot_requested, worker, _}, 2000
    send(worker, {:snapshot, Map.put(stale, "trial_end", DateTime.to_unix(expired))})
    assert {:ok, persisted} = Task.await(task)
    refute AshBilling.subscribed?(%{subscriptions: [persisted]})
  end

  test "F3 stale create_customer cannot overwrite a newly established customer association" do
    user = Ash.create!(PostgresCustomer, %{}, @ash)
    on_exit(fn -> Ash.destroy(user, @ash) end)
    Ash.update!(user, %{stripe_customer_id: "cus_existing_audit"}, @ash)

    assert {:error, {:persistence_failed, "cus_replacement_audit", :customer_identity_conflict}} =
             AshBilling.create_customer(user,
               provider: AshBilling.SecurityRegression.PendingProvider,
               persist: true
             )

    assert Ash.get!(PostgresCustomer, user.id, @ash).stripe_customer_id == "cus_existing_audit"
  end

  test "F4 configured but unloaded handler is loaded and its failure is not acknowledged" do
    dir = Path.join(System.tmp_dir!(), id("audit_beam_"))
    File.mkdir_p!(dir)

    source =
      "defmodule AshBilling.SecurityRegression.ColdHandler do\n def handle_event(_), do: raise(\"must execute\")\nend"

    [{mod, beam}] = Code.compile_string(source)
    File.write!(Path.join(dir, "Elixir.AshBilling.SecurityRegression.ColdHandler.beam"), beam)
    Code.prepend_path(dir)
    :code.purge(mod)
    :code.delete(mod)
    assert :code.is_loaded(mod) == false
    ev = event("audit.test", %{})
    conn = request(ev, handler: mod)
    assert conn.status == 500
    refute AshBilling.Deduplication.processed?(ev["id"])
    assert {:module, ^mod} = Code.ensure_loaded(mod)
    assert_raise RuntimeError, "must execute", fn -> mod.handle_event(ev) end
    Code.delete_path(dir)
    :code.purge(mod)
    :code.delete(mod)
    File.rm_rf!(dir)
  end

  test "F4 invalid required handlers return 500 even when sync errors are configured to acknowledge" do
    ev = event("audit.test", %{})

    assert request(ev, handler: MissingSecurityAuditHandler, return_500_on_sync_error: false).status ==
             500

    refute AshBilling.Deduplication.processed?(ev["id"])
  end

  test "F5 killing resource reclaim worker does not leave a local lock" do
    ev = id("evt_crash_")

    opts = [
      deduplication_resource: AshBilling.SecurityRegression.LockEvent,
      domain: AshBilling.SecurityRegression.LockDomain
    ]

    Ash.create!(AshBilling.SecurityRegression.LockEvent, %{event_id: ev, status: :failed},
      authorize?: false
    )

    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:audit_owner, owner)
        AshBilling.Deduplication.acquire(ev, opts)
      end)

    assert_receive {:locked_read, ^pid}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert :ets.lookup(:ash_billing_processed_events, {:reclaim_lock, ev}) == []
    assert {:ok, _} = AshBilling.Deduplication.acquire(ev, opts)
  end

  test "F6 an expired lease cannot overlap effects while its owner holds the execution fence" do
    Process.register(self(), AshBilling.SecurityRegression.Owner)

    for strategy <- [:memory, :resource] do
      ev = event("audit.test", %{})

      opts =
        if strategy == :resource,
          do: [
            deduplication_resource: AshBilling.Test.PostgresWebhookEvent,
            domain: PostgresDomain
          ],
          else: [deduplication_strategy: :memory]

      assert {:ok, token} = AshBilling.Deduplication.acquire(ev["id"], opts)

      if strategy == :resource do
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE webhook_events SET last_attempt_at = $1 WHERE event_id = $2",
          [DateTime.add(DateTime.utc_now(), -120), ev["id"]]
        )
      else
        :ets.insert(
          :ash_billing_processed_events,
          {ev["id"], :processing, System.system_time(:second) - 120, token}
        )
      end

      first =
        Task.async(fn ->
          AshBilling.Deduplication.with_lease(ev["id"], token, opts, fn ->
            :ok = AshBilling.SecurityRegression.BlockingHandler.handle_event(ev)
            AshBilling.Deduplication.complete(ev["id"], [lease_token: token] ++ opts)
          end)
        end)

      assert_receive {:handled, first_worker, _}, 2000
      owner = self()

      second =
        Task.async(fn ->
          request(
            ev,
            [
              handler: AshBilling.SecurityRegression.BlockingHandler,
              provider: AshBilling.SecurityRegression.FenceProvider,
              owner: owner
            ] ++ opts
          )
        end)

      assert_receive {:verified, _}, 2000
      assert Task.await(second).status == 503
      refute_receive {:handled, _, _}
      send(first_worker, :finish)
      assert {:ok, :ok} = Task.await(first)
      assert request(ev, opts).status == 200
      refute_receive {:handled, _, _}
      assert AshBilling.Deduplication.processed?(ev["id"], opts)

      if strategy == :resource do
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [
          ev["id"]
        ])
      end
    end
  end

  test "F6 a killed execution owner releases its database fence for recovery" do
    Process.register(self(), AshBilling.SecurityRegression.Owner)
    ev = event("audit.test", %{})
    opts = [deduplication_resource: AshBilling.Test.PostgresWebhookEvent, domain: PostgresDomain]
    assert {:ok, token} = AshBilling.Deduplication.acquire(ev["id"], opts)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE webhook_events SET last_attempt_at = $1 WHERE event_id = $2",
      [DateTime.add(DateTime.utc_now(), -120), ev["id"]]
    )

    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        AshBilling.Deduplication.with_lease(ev["id"], token, opts, fn ->
          [[backend]] = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows
          send(owner, {:fence_backend, backend})
          AshBilling.SecurityRegression.BlockingHandler.handle_event(ev)
        end)
      end)

    assert_receive {:fence_backend, backend}, 2000
    assert_receive {:handled, ^worker, _}, 2000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_database_fence_released(backend)

    recovery =
      Task.async(fn ->
        request(ev, [handler: AshBilling.SecurityRegression.BlockingHandler] ++ opts)
      end)

    assert_receive {:handled, next_worker, _}, 2000
    send(next_worker, :finish)
    assert Task.await(recovery).status == 200
    assert AshBilling.Deduplication.processed?(ev["id"], opts)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
  end

  test "PostgreSQL fences are shared by independent BEAM nodes" do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

      :ok =
        :peer.call(peer, Application, :put_env, [
          :ash_billing,
          Repo,
          Application.fetch_env!(:ash_billing, Repo)
        ])

      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ash_billing])
      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ash_postgres])
      assert {:ok, _} = :peer.call(peer, AshBilling.Test.SecurityProvider, :start_repo, [])
      # Distinct ETS owners: the following guarantees must come from PostgreSQL.
      assert :peer.call(peer, :erlang, :whereis, [AshBilling.Deduplication]) !=
               Process.whereis(AshBilling.Deduplication)

      {_user, sub, cus} = fixture()
      premium = object(sub.provider_subscription_id, cus, "active", "price_premium")
      basic = object(sub.provider_subscription_id, cus, "active", "price_cheaper")
      owner = self()

      first =
        Task.async(fn ->
          AshBilling.WebhookSync.sync_event(
            event("customer.subscription.updated", premium),
            [provider: AshBilling.SecurityRegression.PendingProvider, owner: owner] ++ @sync
          )
        end)

      assert_receive {:snapshot_requested, worker, _}, 2000

      {remote_worker, backend} =
        :peer.call(peer, AshBilling.Test.SecurityProvider, :start_call, [
          AshBilling.WebhookSync,
          :sync_event,
          [
            event("customer.subscription.updated", basic),
            [provider: AshBilling.Test.SecurityProvider, snapshot: basic] ++ @sync
          ]
        ])

      :peer.call(peer, :erlang, :send, [remote_worker, :go])
      assert_database_lock_wait(backend)
      send(worker, {:snapshot, premium})
      assert {:ok, _} = Task.await(first)

      assert {:ok, _} =
               :peer.call(peer, AshBilling.Test.SecurityProvider, :finish_call, [remote_worker])

      assert Ash.get!(PostgresSubscription, sub.id, @ash).price_id == "price_cheaper"

      ev = event("audit.test", %{})

      opts = [
        deduplication_resource: AshBilling.Test.PostgresWebhookEvent,
        domain: PostgresDomain
      ]

      assert {:ok, token} = AshBilling.Deduplication.acquire(ev["id"], opts)

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE webhook_events SET last_attempt_at = $1 WHERE event_id = $2",
        [DateTime.add(DateTime.utc_now(), -120), ev["id"]]
      )

      fence =
        Task.async(fn ->
          AshBilling.Deduplication.with_lease(ev["id"], token, opts, fn ->
            send(owner, {:fenced, self()})

            receive do
              :finish -> :ok
            end

            AshBilling.Deduplication.complete(ev["id"], [lease_token: token] ++ opts)
          end)
        end)

      assert_receive {:fenced, fence_owner}, 2000

      {remote_worker, _backend} =
        :peer.call(peer, AshBilling.Test.SecurityProvider, :start_call, [
          AshBilling.Deduplication,
          :acquire,
          [ev["id"], opts]
        ])

      :peer.call(peer, :erlang, :send, [remote_worker, :go])

      assert {:error, :already_processing} =
               :peer.call(peer, AshBilling.Test.SecurityProvider, :finish_call, [remote_worker])

      send(fence_owner, :finish)
      assert {:ok, :ok} = Task.await(fence)

      assert {:error, :already_processed} =
               :peer.call(peer, AshBilling.Deduplication, :acquire, [ev["id"], opts])

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
    after
      :peer.stop(peer)
    end
  end

  test "F1 deletion is isolated by tenant even when provider customer IDs match" do
    customer = AshBilling.Test.PostgresScopedCustomer
    subscription = AshBilling.Test.PostgresOwnedScopedSubscription
    cus = id("cus_scoped_")

    rows =
      for tenant <- [id("tenant_a_"), id("tenant_b_")] do
        opts = [tenant: tenant] ++ @ash
        user = Ash.create!(customer, %{stripe_customer_id: cus}, opts)

        sub =
          Ash.create!(
            subscription,
            %{provider_subscription_id: id("sub_scoped_"), user_id: user.id, status: :active},
            opts
          )

        {opts, user, sub}
      end

    on_exit(fn ->
      for {opts, user, sub} <- rows do
        Ash.destroy(sub, opts)
        Ash.destroy(user, opts)
      end
    end)

    [{first_opts, first_user, first_sub}, {second_opts, second_user, second_sub}] = rows

    assert {:ok, _} =
             AshBilling.WebhookSync.sync_event(
               event("customer.deleted", %{"id" => cus}),
               [customer_resource: customer, subscription_resource: subscription] ++ first_opts
             )

    assert Ash.get!(customer, first_user.id, first_opts).billing_deleted_at
    assert Ash.get!(subscription, first_sub.id, first_opts).status == :canceled
    assert Ash.get!(customer, second_user.id, second_opts).billing_deleted_at == nil
    assert Ash.get!(subscription, second_sub.id, second_opts).status == :active
  end

  test "F1 deletion waits for an in-flight reconciliation and then revokes its result" do
    {user, sub, cus} = fixture()
    owner = self()
    premium = object(sub.provider_subscription_id, cus, "active", "price_premium")

    worker =
      Task.async(fn ->
        AshBilling.WebhookSync.sync_event(
          event("customer.subscription.updated", premium),
          [provider: AshBilling.SecurityRegression.PendingProvider, owner: owner] ++ @sync
        )
      end)

    assert_receive {:snapshot_requested, provider_worker, _}, 2000

    deletion =
      Task.async(fn ->
        AshBilling.WebhookSync.sync_event(event("customer.deleted", %{"id" => cus}), @sync)
      end)

    assert Task.yield(deletion, 100) == nil
    send(provider_worker, {:snapshot, premium})
    assert {:ok, _} = Task.await(worker)
    assert {:ok, _} = Task.await(deletion)
    persisted = Ash.get!(PostgresSubscription, sub.id, @ash)
    assert persisted.status == :canceled
    deleted = Ash.get!(PostgresCustomer, user.id, @ash)
    refute AshBilling.subscribed?(%{deleted | subscriptions: [persisted]})
  end

  test "F6 callback database failure rolls back and leaves the event retryable" do
    {_user, sub, _cus} = fixture()
    ev = event("audit.test", %{})
    opts = [deduplication_resource: AshBilling.Test.PostgresWebhookEvent, domain: PostgresDomain]
    assert {:ok, token} = AshBilling.Deduplication.acquire(ev["id"], opts)

    assert_raise RuntimeError, "callback failure", fn ->
      AshBilling.Deduplication.with_lease(ev["id"], token, opts, fn ->
        Ash.update!(sub, %{price_id: "price_uncommitted"}, @ash)
        raise "callback failure"
      end)
    end

    assert Ash.get!(PostgresSubscription, sub.id, @ash).price_id == "price_basic"
    refute AshBilling.Deduplication.processed?(ev["id"], opts)
    assert :ok = AshBilling.Deduplication.release(ev["id"], [lease_token: token] ++ opts)
    assert {:ok, next_token} = AshBilling.Deduplication.acquire(ev["id"], opts)

    assert {:ok, :ok} =
             AshBilling.Deduplication.with_lease(ev["id"], next_token, opts, fn ->
               AshBilling.Deduplication.complete(ev["id"], [lease_token: next_token] ++ opts)
             end)

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
  end

  test "F3 concurrent public customer creation has one identity winner on ETS" do
    user = Ash.create!(AshBilling.Test.User, %{}, domain: AshBilling.Test.Domain)
    on_exit(fn -> Ash.destroy(user, domain: AshBilling.Test.Domain) end)
    owner = self()

    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :go -> :ok
          end

          customer_id = id("cus_api_")

          {customer_id,
           AshBilling.create_customer(user,
             provider: AshBilling.SecurityRegression.PendingProvider,
             new_customer_id: customer_id,
             persist: true
           )}
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _}, 2000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks)
    assert Enum.count(results, fn {_, result} -> match?({:ok, _}, result) end) == 1

    assert Enum.count(results, fn {_, result} ->
             match?({:error, {:persistence_failed, _, :customer_identity_conflict}}, result)
           end) == 9

    persisted = Ash.get!(AshBilling.Test.User, user.id, domain: AshBilling.Test.Domain)

    assert Enum.any?(results, fn {customer_id, result} ->
             result == {:ok, customer_id} and persisted.stripe_customer_id == customer_id
           end)
  end

  test "nested local fences cannot release their outer owner prematurely" do
    key = {:regression, id("fence_")}
    owner = self()

    first =
      Task.async(fn ->
        AshBilling.ResourceLock.local(key, fn ->
          assert :inner = AshBilling.ResourceLock.local(key, fn -> :inner end)
          send(owner, {:inner_finished, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:inner_finished, worker}

    second =
      Task.async(fn ->
        AshBilling.ResourceLock.local(key, fn -> send(owner, :second_entered) end)
      end)

    refute_receive :second_entered
    send(worker, :finish)
    assert :ok = Task.await(first)
    Task.await(second)
    assert_receive :second_entered
  end

  defp assert_database_fence_released(backend, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3000

    [[held]] =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid = $1 AND locktype = 'advisory')",
        [backend],
        log: false
      ).rows

    if held do
      assert System.monotonic_time(:millisecond) < deadline,
             "database did not release the dead owner's fence"

      assert_database_fence_released(backend, deadline)
    else
      :ok
    end
  end

  defp assert_database_lock_wait(backend, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3000

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [backend],
        log: false
      )

    case rows do
      [["Lock"]] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "remote backend never waited for the PostgreSQL row lock"

        assert_database_lock_wait(backend, deadline)
    end
  end

  test "F2 direct conditional writes reject a changed same-status snapshot" do
    {_user, sub, _cus} = fixture()
    Ash.update!(sub, %{price_id: "price_cheaper"}, @ash)

    assert {:error, :subscription_changed_concurrently} =
             AshBilling.WebhookSync.update_subscription_safely(
               PostgresSubscription,
               sub,
               %{status: :active, price_id: "price_premium"},
               sub.last_event_created_at,
               @ash
             )

    assert Ash.get!(PostgresSubscription, sub.id, @ash).price_id == "price_cheaper"
  end

  test "F6 a replaced lease token cannot enter the execution fence" do
    for strategy <- [:memory, :resource] do
      ev = event("audit.test", %{})

      opts =
        if strategy == :resource,
          do: [
            deduplication_resource: AshBilling.Test.PostgresWebhookEvent,
            domain: PostgresDomain
          ],
          else: [deduplication_strategy: :memory]

      assert {:ok, old_token} = AshBilling.Deduplication.acquire(ev["id"], opts)
      assert :ok = AshBilling.Deduplication.release(ev["id"], [lease_token: old_token] ++ opts)
      assert {:ok, new_token} = AshBilling.Deduplication.acquire(ev["id"], opts)

      assert {:error, :lease_token_mismatch} =
               AshBilling.Deduplication.with_lease(ev["id"], old_token, opts, fn ->
                 flunk("stale lease executed effects")
               end)

      assert {:ok, :ok} =
               AshBilling.Deduplication.with_lease(ev["id"], new_token, opts, fn ->
                 AshBilling.Deduplication.complete(ev["id"], [lease_token: new_token] ++ opts)
               end)

      assert {:error, :already_processed} =
               AshBilling.Deduplication.with_lease(ev["id"], old_token, opts, fn ->
                 flunk("completed event executed effects again")
               end)

      if strategy == :resource do
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [
          ev["id"]
        ])
      end
    end
  end

  test "negative control invalid signature cannot invoke a handler or acquire an event" do
    ev = event("audit.test", %{})

    conn =
      Plug.Test.conn(:post, "/webhooks/stripe", Jason.encode!(ev))
      |> Plug.Conn.put_req_header("stripe-signature", "t=#{System.system_time(:second)},v1=bad")

    result =
      AshBilling.Plug.call(conn,
        webhook_secret: "whsec_audit",
        handler: AshBilling.SecurityRegression.BlockingHandler
      )

    assert result.status == 400
    refute AshBilling.Deduplication.processed?(ev["id"])
    refute_receive {:handled, _, _}
  end

  test "negative control Stripe terminal subscription cannot be resurrected by a later event" do
    {_user, sub, cus} = fixture()
    Ash.update!(sub, %{status: :canceled}, @ash)

    assert {:ok, result} =
             AshBilling.WebhookSync.sync_event(
               event(
                 "customer.subscription.updated",
                 object(sub.provider_subscription_id, cus, "active", "price_premium"),
                 1_700_000_001
               ),
               @sync
             )

    assert result.status == :canceled
    refute AshBilling.subscribed?(%{subscriptions: [result]})
  end

  test "negative control email alone does not associate a customer" do
    user = Ash.create!(PostgresCustomer, %{email: id("owner") <> "@example.com"}, @ash)
    on_exit(fn -> Ash.destroy(user, @ash) end)

    assert {:error, :customer_identity_unverified} =
             AshBilling.WebhookSync.sync_event(
               event("checkout.session.completed", %{
                 "customer" => id("cus_unverified"),
                 "customer_email" => user.email
               }),
               @sync
             )

    assert Ash.get!(PostgresCustomer, user.id, @ash).stripe_customer_id == nil
  end
end
