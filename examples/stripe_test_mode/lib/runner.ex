defmodule AshBillingConsumer.Runner do
  alias AshBillingConsumer.{User, Subscription, WebhookEvent, Repo, Remote, Convergence}
  @ash [domain: AshBillingConsumer.Domain, authorize?: false]
  defp memory, do: Agent.get(AshBillingConsumer.State, & &1)

  defp remember(values) do
    Agent.update(AshBillingConsumer.State, &Map.merge(&1, values))

    if path = System.get_env("ASH_BILLING_TEST_STATE"),
      do: File.write!(path, Jason.encode!(memory(), pretty: true))
  end

  def restore_policies do
    if price = memory()[:first_price], do: compile_policies(price)
    :ok
  end

  defp user, do: Ash.get!(User, memory().user_id, @ash)

  defp current_sub do
    case Ash.read!(Subscription, @ash) |> Enum.find(&(&1.user_id == memory().user_id)) do
      nil -> raise "Subscription webhook has not persisted yet"
      sub -> sub
    end
  end

  defp ensure(condition, message), do: if(condition, do: :ok, else: raise(message))

  def command("setup") do
    ensure(not Map.has_key?(memory(), :customer), "Setup already ran")
    run_id = memory().run_id

    product =
      Remote.request(:post, "/v1/products", %{
        name: "AshBilling validation " <> run_id,
        metadata: %{validation_run: run_id}
      })

    prices =
      for amount <- [100, 150] do
        Remote.request(:post, "/v1/prices", %{
          product: product["id"],
          unit_amount: amount,
          currency: "usd",
          recurring: %{interval: "month"}
        })
      end

    record = Ash.create!(User, %{email: run_id <> "@example.invalid"}, @ash)

    opts =
      [persist: true, actor: record, authorize?: true, domain: AshBillingConsumer.Domain] ++
        Remote.opts()

    {:ok, customer} = AshBilling.create_customer(record, opts)
    record = Ash.get!(User, record.id, actor: record)
    {:ok, ^customer} = AshBilling.create_customer(record, opts)
    remote = Remote.request(:get, "/v1/customers/" <> customer)

    ensure(
      remote["livemode"] === false and record.stripe_customer_id == customer,
      "Customer association mismatch"
    )

    [first, second] = Enum.map(prices, & &1["id"])

    remember(%{
      user_id: record.id,
      customer: customer,
      product: product["id"],
      first_price: first,
      second_price: second
    })

    compile_policies(first)

    {:ok, session} =
      AshBilling.create_checkout_session(
        record,
        [
          price: first,
          quantity: 20,
          success_url: "http://127.0.0.1:4089/success",
          cancel_url: "http://127.0.0.1:4089/cancel"
        ] ++ Remote.opts()
      )

    saved = Remote.request(:get, "/v1/checkout/sessions/" <> session.id)

    ensure(
      saved["customer"] == customer and saved["livemode"] === false,
      "Checkout identity/mode mismatch"
    )

    remember(%{subscription_checkout: session.id})

    %{
      status: "PASS",
      customer: customer,
      user_id: record.id,
      price: first,
      session: session.id,
      checkout_url: session.url,
      livemode: false
    }
  end

  def command("verify_subscription") do
    session = Remote.request(:get, "/v1/checkout/sessions/" <> memory().subscription_checkout)

    ensure(
      session["payment_status"] == "paid" and is_binary(session["subscription"]),
      "Checkout payment not confirmed"
    )

    remote = Remote.request(:get, "/v1/subscriptions/" <> session["subscription"])
    ensure(remote["status"] == "active", "Remote subscription not active")
    item = hd(remote["items"]["data"])

    ensure(
      item["quantity"] == 20 and item["price"]["id"] == memory().first_price and
        remote["customer"] == memory().customer,
      "Remote subscription identity, price or quantity mismatch"
    )

    snapshot = await_subscription(remote)
    remember(%{subscription_id: remote["id"]})

    Map.merge(snapshot, %{
      payment_status: session["payment_status"],
      remote_quantity: hd(remote["items"]["data"])["quantity"],
      status: "PASS"
    })
  end

  def command("swap_twenty"),
    do:
      mutate(
        fn sub -> AshBilling.swap_plan(sub, memory().second_price, Remote.opts()) end,
        20,
        memory().second_price
      )

  def command("quantity_ten"),
    do:
      mutate(
        fn sub -> AshBilling.update_quantity(sub, 10, Remote.opts()) end,
        10,
        memory().second_price
      )

  def command("swap_ten"),
    do:
      mutate(
        fn sub -> AshBilling.swap_plan(sub, memory().first_price, Remote.opts()) end,
        10,
        memory().first_price
      )

  def command("schedule_cancel"), do: lifecycle(&AshBilling.cancel_subscription/2, true, "active")
  def command("resume"), do: lifecycle(&AshBilling.resume_subscription/2, false, "active")

  def command("cancel_now"),
    do:
      lifecycle(
        fn sub, opts -> AshBilling.cancel_subscription(sub, [at_period_end: false] ++ opts) end,
        false,
        "canceled"
      )

  def command("api_subscribe") do
    ensure(Map.has_key?(memory(), :customer), "Run setup first")
    ensure(not Map.has_key?(memory(), :subscription_id), "Subscription already active")

    customer = memory().customer
    first_price = memory().first_price

    pm =
      Remote.request(:post, "/v1/payment_methods/pm_card_visa/attach", %{
        customer: customer
      })

    ensure(pm["livemode"] === false, "PaymentMethod not in test mode")

    Remote.request(:post, "/v1/customers/" <> customer, %{
      invoice_settings: %{default_payment_method: pm["id"]}
    })

    remote =
      Remote.request(:post, "/v1/subscriptions", %{
        customer: customer,
        default_payment_method: pm["id"],
        items: [%{price: first_price, quantity: 20}]
      })

    ensure(remote["livemode"] === false and remote["status"] == "active", "Remote sub not active")
    snapshot = await_subscription(remote)
    remember(%{subscription_id: remote["id"]})

    %{
      status: "PASS",
      livemode: false,
      subscription: remote["id"],
      price: first_price,
      remote_quantity: hd(remote["items"]["data"])["quantity"],
      local_state: snapshot
    }
  end

  def command("missed_webhook_reconcile") do
    sub_before = current_sub()
    ensure(sub_before.status == :active, "Subscription must be active before missed-webhook test")

    target_price =
      if sub_before.price_id == memory().first_price,
        do: memory().second_price,
        else: memory().first_price

    stale_price = sub_before.price_id
    stale_quantity = sub_before.quantity
    target_quantity = if stale_quantity == 15, do: 12, else: 15
    prev_event_ts = sub_before.last_event_created_at

    Application.put_env(:ash_billing_consumer, :drop_webhooks, true)

    try do
      {:ok, _} = AshBilling.swap_plan(sub_before, target_price, Remote.opts())
      {:ok, _} = AshBilling.update_quantity(sub_before, target_quantity, Remote.opts())
      Process.sleep(2_000)

      remote = Remote.request(:get, "/v1/subscriptions/" <> memory().subscription_id)
      remote_item = hd(remote["items"]["data"])
      remote_price = remote_item["price"]["id"]
      remote_qty = remote_item["quantity"]
      ensure(remote_price == target_price, "Stripe did not apply target plan")
      ensure(remote_qty == target_quantity, "Stripe did not apply target quantity")

      local_while_dropped = current_sub()

      ensure(
        local_while_dropped.price_id == stale_price and
          local_while_dropped.quantity == stale_quantity,
        "Expected local PostgreSQL state to remain stale while webhooks were dropped"
      )

      {:ok, reconciled} =
        AshBilling.reconcile_subscription(
          local_while_dropped,
          sync_opts()
        )

      ensure(reconciled.price_id == target_price, "Reconciliation did not converge local price")

      ensure(
        reconciled.quantity == target_quantity,
        "Reconciliation did not converge local quantity"
      )

      ensure(
        reconciled.provider_subscription_item_id == remote_item["id"],
        "Reconciliation did not persist provider_subscription_item_id"
      )

      ensure(
        match?(%DateTime{}, reconciled.last_reconciled_at),
        "last_reconciled_at was not persisted"
      )

      if prev_event_ts do
        ensure(
          DateTime.compare(reconciled.last_event_created_at, prev_event_ts) == :eq,
          "reconcile_subscription unexpectedly mutated last_event_created_at"
        )
      end

      %{
        status: "PASS",
        livemode: remote["livemode"],
        subscription: remote["id"],
        stale_price_before_reconcile: stale_price,
        stale_quantity_before_reconcile: stale_quantity,
        reconciled_price: reconciled.price_id,
        reconciled_quantity: reconciled.quantity,
        provider_subscription_item_id: reconciled.provider_subscription_item_id,
        last_event_created_at: reconciled.last_event_created_at,
        last_reconciled_at: reconciled.last_reconciled_at,
        local_state: state()
      }
    after
      Application.put_env(:ash_billing_consumer, :drop_webhooks, false)
    end
  end

  def command("delayed_old_event_after_reconcile") do
    sub_before = current_sub()

    ensure(
      match?(%DateTime{}, sub_before.last_reconciled_at),
      "Run missed_webhook_reconcile first"
    )

    stale_price =
      if sub_before.price_id == memory().first_price,
        do: memory().second_price,
        else: memory().first_price

    %{rows: [[captured_event]]} =
      Repo.query!(
        """
        SELECT payload FROM handler_effects
        WHERE event_type IN ('customer.subscription.created', 'customer.subscription.updated')
          AND payload->'data'->'object'->>'id' = $1
          AND payload->'data'->'object'->'items'->'data'->0->'price'->>'id' = $2
        ORDER BY event_id DESC LIMIT 1
        """,
        [memory().subscription_id, stale_price]
      )

    # Craft a fresh event_id so deduplication does not short-circuit, with a real current
    # timestamp (>= last_event_created_at and >= last_reconciled_at, without advancing into
    # the future) using the real captured Stripe subscription object carrying the stale price.
    Process.sleep(1_100)

    replay_unix =
      max(System.system_time(:second), DateTime.to_unix(sub_before.last_reconciled_at) + 1)

    delayed_event =
      captured_event
      |> Map.put("id", "evt_local_delayed_" <> Ash.UUID.generate())
      |> Map.put("created", replay_unix)

    response = signed_delivery(delayed_event)
    ensure(response.status == 200, "Delayed event delivery failed with HTTP #{response.status}")

    sub_after = current_sub()

    ensure(
      sub_after.price_id == sub_before.price_id and sub_after.quantity == sub_before.quantity,
      "Delayed old event overwrote reconciled live Stripe price or quantity!"
    )

    ensure(
      DateTime.compare(sub_after.last_reconciled_at, sub_before.last_reconciled_at) in [:gt, :eq],
      "last_reconciled_at moved backwards"
    )

    %{
      status: "PASS",
      execution:
        "local HMAC-signed re-delivery of captured real Stripe payload verified against live Stripe Test API",
      original_captured_event: captured_event["id"],
      injected_stale_price: stale_price,
      injected_stale_quantity: hd(captured_event["data"]["object"]["items"]["data"])["quantity"],
      preserved_live_price: sub_after.price_id,
      preserved_live_quantity: sub_after.quantity,
      http_status: response.status,
      last_reconciled_at_before: sub_before.last_reconciled_at,
      last_reconciled_at_after: sub_after.last_reconciled_at
    }
  end

  def command("payment_checkout") do
    {:ok, session} =
      AshBilling.create_checkout_session(
        user(),
        [
          mode: "payment",
          line_items: [
            %{
              price_data: %{
                currency: "usd",
                unit_amount: 100,
                product_data: %{name: "AshBilling one-time validation"}
              },
              quantity: 1
            }
          ],
          success_url: "http://127.0.0.1:4089/success",
          cancel_url: "http://127.0.0.1:4089/cancel"
        ] ++ Remote.opts()
      )

    remember(%{payment_checkout: session.id})
    %{status: "PASS", session: session.id, checkout_url: session.url}
  end

  def command("verify_payment") do
    remote = Remote.request(:get, "/v1/checkout/sessions/" <> memory().payment_checkout)
    ensure(remote["payment_status"] == "paid", "One-time payment not paid")

    %{rows: rows} =
      Repo.query!(
        "SELECT event_id,payment_status FROM handler_effects WHERE event_type='checkout.session.completed' AND payload->'data'->'object'->>'id'=$1",
        [remote["id"]]
      )

    ensure(
      Enum.any?(rows, fn [_, status] -> status == "paid" end),
      "Paid webhook handler receipt missing"
    )

    %{
      status: "PASS",
      livemode: remote["livemode"],
      payment_status: remote["payment_status"],
      session: remote["id"],
      event_ids: Enum.map(rows, &hd/1)
    }
  end

  def command("replay") do
    event =
      case Repo.query!(
             "SELECT payload FROM handler_effects WHERE event_type='checkout.session.completed' AND payload->'data'->'object'->>'id'=$1 LIMIT 1",
             [memory().subscription_checkout]
           ).rows do
        [[ev]] ->
          ev

        [] ->
          %{rows: [[ev]]} =
            Repo.query!(
              "SELECT payload FROM handler_effects WHERE event_type='customer.subscription.created' AND payload->'data'->'object'->>'id'=$1 ORDER BY event_id LIMIT 1",
              [memory().subscription_id]
            )

          ev
      end

    before_count = effect_count(event["id"])
    response = signed_delivery(event)

    ensure(
      response.status == 200 and response.body["status"] == "already_processed",
      "Replay was not deduplicated"
    )

    ensure(
      effect_count(event["id"]) == before_count and before_count == 1,
      "Duplicate SQL receipt"
    )

    %{
      status: "PASS",
      execution: "local replay of a real Stripe event",
      event: event["id"],
      http_status: response.status,
      sql_receipts: before_count
    }
  end

  def command("out_of_order") do
    %{rows: [[event]]} =
      Repo.query!(
        "SELECT payload FROM handler_effects WHERE event_type='customer.subscription.created' AND payload->'data'->'object'->>'id'=$1 ORDER BY event_id LIMIT 1",
        [memory().subscription_id]
      )

    before = current_sub()
    ensure(before.status == :canceled, "Run immediate cancellation first")
    {:ok, _} = AshBilling.WebhookSync.sync_event(event, sync_opts())
    after_record = current_sub()

    ensure(
      after_record.status == :canceled and before.price_id == after_record.price_id,
      "Old snapshot overwrote terminal state"
    )

    %{
      status: "PASS",
      execution: "local reordering of a real Stripe snapshot through sync_event",
      event: event["id"],
      local_status: after_record.status
    }
  end

  def command("persistence_recovery") do
    record = Ash.create!(User, %{email: memory().run_id <> "_recovery@example.invalid"}, @ash)
    opts = [persist: true, authorize?: true, domain: AshBillingConsumer.Domain] ++ Remote.opts()
    {:error, {:persistence_failed, remote_id, _}} = AshBilling.create_customer(record, opts)

    ensure(
      Ash.get!(User, record.id, @ash).stripe_customer_id == nil,
      "Denied write unexpectedly persisted"
    )

    {:ok, recovered} = AshBilling.create_customer(record, [actor: record] ++ opts)
    ensure(recovered == remote_id, "Retry created a different remote identity")

    ensure(
      Ash.get!(User, record.id, @ash).stripe_customer_id == remote_id,
      "Recovery did not persist"
    )

    remote = Remote.request(:get, "/v1/customers/" <> remote_id)

    %{
      status: "PASS",
      execution: "real Stripe creation with injected local authorization denial",
      customer: remote_id,
      livemode: remote["livemode"],
      recovered: true
    }
  end

  def command("failures"), do: local_failures()
  def command(_), do: %{status: "NOT RUN", reason: "Unknown operation"}

  defp mutate(fun, quantity, price) do
    {:ok, _} = fun.(current_sub())
    remote = Remote.request(:get, "/v1/subscriptions/" <> memory().subscription_id)
    item = hd(remote["items"]["data"])

    ensure(
      item["quantity"] == quantity and item["price"]["id"] == price,
      "Remote item mutation mismatch"
    )

    ensure(remote["status"] == "active", "Remote subscription not active")
    snapshot = await_subscription(remote)

    %{
      status: "PASS",
      livemode: remote["livemode"],
      subscription: remote["id"],
      quantity: item["quantity"],
      price: item["price"]["id"],
      latest_invoice: remote["latest_invoice"],
      local_state: snapshot
    }
  end

  defp lifecycle(fun, expected_flag, expected_status) do
    {:ok, _} = fun.(current_sub(), Remote.opts())
    remote = Remote.request(:get, "/v1/subscriptions/" <> memory().subscription_id)
    ensure(remote["status"] == expected_status, "Remote lifecycle status mismatch")

    if expected_status == "active",
      do: ensure(remote["cancel_at_period_end"] === expected_flag, "Cancellation flag mismatch")

    snapshot = await_subscription(remote)

    %{
      status: "PASS",
      remote_status: remote["status"],
      cancel_at_period_end: remote["cancel_at_period_end"],
      subscription: remote["id"],
      local_state: snapshot
    }
  end

  defp await_subscription(remote) do
    active? = remote["status"] == "active"
    item = hd(remote["items"]["data"])

    authorization = %{
      subscribed: active?,
      has_price: active? and item["price"]["id"] == memory().first_price,
      wrong_price: false
    }

    read_snapshot = fn ->
      snapshot = state()

      %{rows: rows} =
        Repo.query!(
          "SELECT h.payload->'data'->'object' FROM handler_effects h JOIN webhook_events w ON w.event_id=h.event_id WHERE w.status='processed' AND h.event_type IN ('customer.subscription.created','customer.subscription.updated','customer.subscription.deleted') AND h.payload->'data'->'object'->>'id'=$1",
          [remote["id"]]
        )

      Map.put(
        snapshot,
        :processed_subscription_snapshots,
        Enum.map(rows, fn [object] -> Convergence.subscription_fields(object) end)
      )
    end

    case Convergence.await(remote, authorization, read_snapshot) do
      {:ok, snapshot} ->
        Map.delete(snapshot, :processed_subscription_snapshots)

      {:error, :subscription_not_converged} ->
        raise "Subscription webhook, PostgreSQL state and policies did not converge within 15 seconds"
    end
  end

  def state do
    data = memory()

    subs =
      if data[:user_id],
        do: Enum.filter(Ash.read!(Subscription, @ash), &(&1.user_id == data.user_id)),
        else: []

    actor = if data[:user_id], do: user() |> Ash.load!(:subscriptions, @ash)

    authorized =
      if actor && Code.ensure_loaded?(AshBillingConsumer.Feature),
        do: %{
          subscribed: Ash.can?({AshBillingConsumer.Feature, :subscribed}, actor),
          has_price: Ash.can?({AshBillingConsumer.Feature, :priced}, actor),
          wrong_price: Ash.can?({AshBillingConsumer.Feature, :wrong_price}, actor)
        },
        else: %{}

    %{
      run_id: data.run_id,
      authorization: authorized,
      subscriptions:
        Enum.map(
          subs,
          &Map.take(&1, [
            :provider_subscription_id,
            :status,
            :price_id,
            :quantity,
            :provider_subscription_item_id,
            :cancel_at_period_end,
            :current_period_end,
            :last_event_created_at,
            :last_reconciled_at
          ])
        ),
      canceling: Enum.any?(subs, &AshBilling.canceling?/1),
      processed_events: Enum.count(Ash.read!(WebhookEvent, @ash), &(&1.status == :processed))
    }
  end

  defp compile_policies(price) do
    Code.compile_string("""
    defmodule AshBillingConsumer.Feature do
      use Ash.Resource, domain: AshBillingConsumer.Domain, data_layer: Ash.DataLayer.Simple,
        authorizers: [Ash.Policy.Authorizer]
      actions do
        action :subscribed, :boolean do
          run fn _, _ -> {:ok, true} end
        end
        action :priced, :boolean do
          run fn _, _ -> {:ok, true} end
        end
        action :wrong_price, :boolean do
          run fn _, _ -> {:ok, true} end
        end
      end
      policies do
        policy action(:subscribed) do
          authorize_if AshBilling.Checks.Subscribed
        end
        policy action(:priced) do
          authorize_if {AshBilling.Checks.HasPrice, price: #{inspect(price)}}
        end
        policy action(:wrong_price) do
          authorize_if {AshBilling.Checks.HasPrice, price: "price_unrelated_validation"}
        end
      end
    end
    """)
  end

  defp sync_opts,
    do:
      [
        customer_resource: User,
        subscription_resource: Subscription,
        deduplication_resource: WebhookEvent
      ] ++ @ash ++ Remote.opts()

  defp effect_count(id),
    do:
      Repo.query!("SELECT count(*) FROM handler_effects WHERE event_id=$1", [id]).rows
      |> hd()
      |> hd()

  defp signed_delivery(event) do
    body = Jason.encode!(event)
    timestamp = System.system_time(:second)
    secret = System.fetch_env!("STRIPE_WEBHOOK_SECRET")

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)

    Req.post!("http://127.0.0.1:4089/webhooks/stripe",
      body: body,
      headers: [{"stripe-signature", "t=#{timestamp},v1=#{signature}"}],
      retry: false
    )
  end

  defp local_failures do
    results =
      for type <- ["validation.error", "validation.exception"] do
        event = %{
          "id" => "evt_local_" <> Ash.UUID.generate(),
          "type" => type,
          "livemode" => false,
          "data" => %{"object" => %{}}
        }

        Application.put_env(:ash_billing_consumer, :inject_failures, true)
        response = signed_delivery(event)

        ensure(
          response.status >= 500 and effect_count(event["id"]) == 0,
          "Handler failure left SQL effects"
        )

        lease = Ash.get!(WebhookEvent, event["id"], @ash)
        ensure(lease.status == :failed, "Lease not retryable")
        Application.put_env(:ash_billing_consumer, :inject_failures, false)

        ensure(
          signed_delivery(event).status == 200 and effect_count(event["id"]) == 1,
          "Retry did not recover"
        )

        %{
          scenario: type,
          status: "PASS",
          initial_http: response.status,
          final_lease: "processed",
          execution: "local fault injection"
        }
      end

    Application.delete_env(:ash_billing_consumer, :inject_failures)

    %{
      status: "PASS",
      scenarios: results ++ [commit_failure(), concurrent_duplicate(), synchronization_failure()]
    }
  end

  defp local_event(type) do
    %{
      "id" => "evt_local_" <> Ash.UUID.generate(),
      "type" => type,
      "livemode" => false,
      "data" => %{"object" => %{}}
    }
  end

  defp commit_failure do
    event = local_event("validation.commit_failure")
    name = "validation_fault_" <> String.replace(Ash.UUID.generate(), "-", "")
    Repo.query!("CREATE SEQUENCE #{name}")

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_id = '#{event["id"]}' AND nextval('#{name}') = 1 THEN
        RAISE EXCEPTION 'injected validation commit failure' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END $$;
    """)

    Repo.query!(
      "CREATE CONSTRAINT TRIGGER #{name} AFTER INSERT ON handler_effects DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{name}()"
    )

    try do
      response = signed_delivery(event)

      ensure(
        response.status >= 500 and effect_count(event["id"]) == 0,
        "Commit failure retained SQL effects"
      )

      ensure(
        Ash.get!(WebhookEvent, event["id"], @ash).status == :failed,
        "Commit lease did not recover"
      )

      ensure(
        signed_delivery(event).status == 200 and effect_count(event["id"]) == 1,
        "Commit retry failed"
      )

      %{
        scenario: "commit_failure",
        status: "PASS",
        execution: "local PostgreSQL deferred trigger fault",
        initial_http: response.status,
        final_lease: "processed"
      }
    after
      Repo.query!("DROP TRIGGER #{name} ON handler_effects")
      Repo.query!("DROP FUNCTION #{name}()")
      Repo.query!("DROP SEQUENCE #{name}")
    end
  end

  defp concurrent_duplicate do
    event = local_event("validation.concurrent")

    statuses =
      for _ <- 1..2 do
        Task.async(fn -> signed_delivery(event).status end)
      end
      |> Enum.map(&Task.await(&1, 15_000))

    ensure(
      Enum.all?(statuses, &(&1 in [200, 503])) and 200 in statuses,
      "Unexpected duplicate status"
    )

    ensure(effect_count(event["id"]) == 1, "Concurrent duplicate repeated SQL receipt")

    ensure(
      signed_delivery(event).body["status"] == "already_processed",
      "Duplicate not durably recorded"
    )

    %{
      scenario: "concurrent_duplicate",
      status: "PASS",
      execution: "local signed parallel deliveries",
      http_statuses: statuses,
      sql_receipts: 1
    }
  end

  defp synchronization_failure do
    record = Ash.create!(User, %{email: memory().run_id <> "_conflict@example.invalid"}, @ash)

    {:ok, remote_id} =
      AshBilling.create_customer(
        %{email: memory().run_id <> "_unassociated@example.invalid"},
        Remote.opts()
      )

    event =
      local_event("customer.subscription.updated")
      |> put_in(
        ["data", "object"],
        %{
          "id" => memory().subscription_id,
          "customer" => remote_id,
          "status" => "active",
          "metadata" => %{"resource_id" => record.id}
        }
      )

    before = current_sub()
    response = signed_delivery(event)
    ensure(response.status >= 500, "Contradiction unexpectedly accepted")

    ensure(
      Ash.get!(User, record.id, @ash).stripe_customer_id == nil,
      "Partial association was committed"
    )

    ensure(
      current_sub().user_id == before.user_id and current_sub().status == before.status,
      "Original subscription changed"
    )

    ensure(
      Ash.get!(WebhookEvent, event["id"], @ash).status == :failed,
      "Sync error lease not retryable"
    )

    %{
      scenario: "partial_association_conflict",
      status: "PASS",
      execution: "local contradictory snapshot with real test Customer",
      initial_http: response.status,
      local_customer: nil,
      lease: "failed"
    }
  end
end
