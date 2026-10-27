defmodule AshBilling.DeduplicationTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshBilling.Deduplication
  alias AshBilling.Test.{Domain, WebhookEvent}

  setup do
    Application.delete_env(:ash_billing, :deduplication_strategy)
    Application.delete_env(:ash_billing, :deduplication_resource)
    Deduplication.clear()

    on_exit(fn ->
      Application.delete_env(:ash_billing, :deduplication_strategy)
      Application.delete_env(:ash_billing, :deduplication_resource)
    end)

    :ok
  end

  describe "AshBilling.Deduplication with :memory strategy" do
    test "returns false for unprocessed events" do
      refute Deduplication.processed?("evt_unseen_1")
      refute Deduplication.processed?(nil)
    end

    test "marks event as processed and detects duplicate" do
      event_id = "evt_stripe_duplicate_check_1"
      refute Deduplication.processed?(event_id)

      assert :ok = Deduplication.mark_processed(event_id)
      assert Deduplication.processed?(event_id)
      assert :ok = Deduplication.mark_processed(nil)
    end

    test "rejects :resource strategy when deduplication_resource is not provided (no silent ETS fallback)" do
      event_id = "evt_res_not_configured_1"
      opts = [deduplication_strategy: :resource]

      refute Deduplication.processed?(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.acquire(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.mark_processed(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.complete(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.release(event_id, opts)
    end

    test "handles explicit :memory strategy and application environment config" do
      event_id = "evt_mem_explicit_1"
      opts = [deduplication_strategy: :memory]

      refute Deduplication.processed?(event_id, opts)
      assert :ok = Deduplication.mark_processed(event_id, opts)
      assert Deduplication.processed?(event_id, opts)

      # Test application env config
      Application.put_env(:ash_billing, :deduplication_strategy, :memory)
      assert Deduplication.processed?(event_id)
      Application.delete_env(:ash_billing, :deduplication_strategy)
    end

    test "sweep removes entries older than 24h" do
      old_time = System.system_time(:second) - 90_000
      :ets.insert(:ash_billing_processed_events, {"evt_ancient_123", old_time})
      assert Deduplication.processed?("evt_ancient_123")

      send(Process.whereis(AshBilling.Deduplication), :sweep)
      :timer.sleep(20)

      refute Deduplication.processed?("evt_ancient_123")
    end

    test "clear/0 empties the table" do
      event_id = "evt_to_clear"
      Deduplication.mark_processed(event_id)
      assert Deduplication.processed?(event_id)

      Deduplication.clear()
      refute Deduplication.processed?(event_id)
    end
  end

  describe "AshBilling.Deduplication with :resource strategy (database/multi-node)" do
    test "tracks events using Ash resource" do
      opts = [deduplication_resource: WebhookEvent, domain: Domain]
      event_id = "evt_db_cluster_test_100"

      refute Deduplication.processed?(event_id, opts)

      assert :ok = Deduplication.mark_processed(event_id, opts)
      assert Deduplication.processed?(event_id, opts)

      # Verify it was actually saved in the Ash resource
      require Ash.Query

      assert WebhookEvent
             |> Ash.Query.filter(event_id == ^event_id)
             |> Ash.exists?(domain: Domain, authorize?: false)
    end

    test "deduplicates in Plug using resource strategy" do
      secret = "whsec_db_test_secret"
      event_id = "evt_plug_db_dedup_1"
      payload = Jason.encode!(%{"id" => event_id, "type" => "invoice.payment_succeeded"})
      timestamp = System.system_time(:second)
      signed_payload = "#{timestamp}.#{payload}"

      sig =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      signature_header = "t=#{timestamp},v1=#{sig}"

      plug_opts = [
        webhook_secret: secret,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      # First delivery: processed
      conn1 =
        conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", signature_header)
        |> AshBilling.Plug.call(plug_opts)

      assert conn1.status == 200
      assert conn1.resp_body =~ "received"

      # Second delivery (retry from another node): recognized as duplicate
      conn2 =
        conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", signature_header)
        |> AshBilling.Plug.call(plug_opts)

      assert conn2.status == 200
      assert conn2.resp_body =~ "already_processed"
    end

    test "AshBilling.WebhookEvent defines sections and transformers" do
      assert is_list(AshBilling.WebhookEvent.sections())
      assert is_list(AshBilling.WebhookEvent.transformers())
    end

    test "rejects when resource strategy is set but resource is nil (no silent ETS fallback)" do
      opts = [deduplication_strategy: :resource, deduplication_resource: nil]
      event_id = "evt_fallback_mem_1"

      refute Deduplication.processed?(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.acquire(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.mark_processed(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.complete(event_id, opts)

      assert {:error, :deduplication_resource_not_configured} =
               Deduplication.release(event_id, opts)
    end

    test "strictly rejects resources lacking :update action or :status attribute upon acquire and complete" do
      alias AshBilling.Test.SimpleEvent

      opts = [
        deduplication_strategy: :resource,
        deduplication_resource: SimpleEvent,
        domain: Domain
      ]

      event_id = "evt_simple_res_99"

      refute Deduplication.processed?(event_id, opts)

      # Acquisition strictly requires :status attribute and :update action
      assert {:error, :resource_lacks_update_action} = Deduplication.acquire(event_id, opts)

      # Completion strictly requires :status attribute and :update action
      assert {:error, :resource_lacks_update_action} = Deduplication.complete(event_id, opts)
    end

    test "handles memory lifecycle: processing, failed, and expired lease reclamation" do
      event_id = "evt_mem_lifecycle_#{System.unique_integer([:positive])}"
      opts = [deduplication_strategy: :memory]

      # 1. Acquire puts event in :processing and returns token
      assert {:ok, token1} = Deduplication.acquire(event_id, opts)
      assert is_binary(token1)
      refute Deduplication.processed?(event_id, opts)
      assert {:error, :already_processing} = Deduplication.acquire(event_id, opts)

      # 2. Release marks event as :failed
      assert :ok = Deduplication.release(event_id, [lease_token: token1] ++ opts)
      refute Deduplication.processed?(event_id, opts)

      # 3. Re-acquire succeeds from :failed
      assert {:ok, token2} = Deduplication.acquire(event_id, opts)
      assert is_binary(token2)

      # 4. Expired lease (> 60s) is reclaimed
      table = :ash_billing_processed_events
      now = System.system_time(:second)
      :ets.insert(table, {event_id, :processing, now - 100, token2})
      assert {:ok, token3} = Deduplication.acquire(event_id, opts)
      assert is_binary(token3)

      # Zombie worker attempting complete with old token is rejected
      assert {:error, :lease_token_mismatch} =
               Deduplication.complete(event_id, [lease_token: token1] ++ opts)

      # 5. Active worker completes successfully
      assert :ok = Deduplication.complete(event_id, [lease_token: token3] ++ opts)
      assert Deduplication.processed?(event_id, opts) == true
      assert {:error, :already_processed} = Deduplication.acquire(event_id, opts)
    end

    test "resource deduplication edge cases: missing record, simple event complete, and read-only resource" do
      alias AshBilling.Test.{ReadOnlyEvent, SimpleEvent, WebhookEvent}

      opts_webhook = [
        deduplication_strategy: :resource,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      # Complete for non-existent record returns error; release returns :ok safely
      assert {:error, _} = Deduplication.complete("evt_not_in_db_123", opts_webhook)
      assert :ok = Deduplication.release("evt_not_in_db_123", opts_webhook)

      # Complete on SimpleEvent (resource without status or update action) strictly rejected
      opts_simple = [
        deduplication_strategy: :resource,
        deduplication_resource: SimpleEvent,
        domain: Domain
      ]

      assert {:error, :resource_lacks_update_action} =
               Deduplication.acquire("evt_simple_comp_1", opts_simple)

      assert {:error, :resource_lacks_update_action} =
               Deduplication.complete("evt_simple_comp_1", opts_simple)

      # Release on ReadOnlyEvent (lacks update action)
      opts_ro = [
        deduplication_strategy: :resource,
        deduplication_resource: ReadOnlyEvent,
        domain: Domain
      ]

      assert {:error, :resource_lacks_update_action} =
               Deduplication.acquire("evt_readonly_1", opts_ro)

      assert {:error, :resource_lacks_update_action} =
               Deduplication.complete("evt_readonly_1", opts_ro)

      # Complete and release on FailingUpdateEvent (triggers update failure and fallback)
      opts_failing = [
        deduplication_strategy: :resource,
        deduplication_resource: AshBilling.Test.FailingUpdateEvent,
        domain: Domain
      ]

      assert {:ok, tok_fail} = Deduplication.acquire("evt_failing_upd_1", opts_failing)

      assert {:error, _} =
               Deduplication.complete(
                 "evt_failing_upd_1",
                 [lease_token: tok_fail] ++ opts_failing
               )

      assert :ok =
               Deduplication.release("evt_failing_upd_1", [lease_token: tok_fail] ++ opts_failing)

      # FailingUpdateEvent with mismatching token during fallback destroy
      assert {:ok, _tok_fail3} = Deduplication.acquire("evt_failing_upd_3", opts_failing)

      assert {:error, :lease_token_mismatch} =
               Deduplication.release(
                 "evt_failing_upd_3",
                 [lease_token: "wrong_tok"] ++ opts_failing
               )

      # SimpleEvent without status or update action rejected
      assert {:error, :resource_lacks_update_action} =
               Deduplication.acquire("evt_simple_reclaim_2", opts_simple)

      # FailingUpdateEvent bulk_update error branch during reclaim
      assert {:ok, _} = Deduplication.acquire("evt_failing_upd_2", opts_failing)
      assert {:error, _} = Deduplication.acquire("evt_failing_upd_2", opts_failing)

      # Resource release and complete branches on WebhookEvent
      evt_fail_res = "evt_res_failed_#{System.unique_integer([:positive])}"
      assert {:ok, tok_f} = Deduplication.acquire(evt_fail_res, opts_webhook)
      assert :ok = Deduplication.release(evt_fail_res, [lease_token: tok_f] ++ opts_webhook)
      # Release on already failed record returns :ok
      assert :ok = Deduplication.release(evt_fail_res, opts_webhook)

      # Mismatching token on an actively processing event
      evt_processing_res = "evt_res_proc_#{System.unique_integer([:positive])}"
      assert {:ok, _tok_p} = Deduplication.acquire(evt_processing_res, opts_webhook)

      assert {:error, :lease_token_mismatch} =
               Deduplication.release(
                 evt_processing_res,
                 [lease_token: "wrong_tok"] ++ opts_webhook
               )

      assert {:error, :lease_token_mismatch} =
               Deduplication.complete(
                 evt_processing_res,
                 [lease_token: "wrong_tok"] ++ opts_webhook
               )

      # Exception rescues on non-keyword list options
      assert {:error, _} = Deduplication.acquire("evt_raise", :not_a_keyword_list)
      assert {:error, _} = Deduplication.complete("evt_raise", :not_a_keyword_list)
      assert {:error, _} = Deduplication.release("evt_raise", :not_a_keyword_list)
      assert false == Deduplication.processed?("evt_raise", :not_a_keyword_list)

      # Release with matching token on an already processed record returns {:error, :already_processed}
      evt_proc_res = "evt_res_proc_already_#{System.unique_integer([:positive])}"
      assert {:ok, tok_p} = Deduplication.acquire(evt_proc_res, opts_webhook)
      assert :ok = Deduplication.complete(evt_proc_res, [lease_token: tok_p] ++ opts_webhook)

      assert {:error, :already_processed} =
               Deduplication.release(evt_proc_res, [lease_token: tok_p] ++ opts_webhook)

      # Complete on an already failed record with matching token returns {:error, :lease_not_acquired}
      evt_fail_res2 = "evt_res_fail_already_#{System.unique_integer([:positive])}"
      assert {:ok, tok_f2} = Deduplication.acquire(evt_fail_res2, opts_webhook)
      assert :ok = Deduplication.release(evt_fail_res2, [lease_token: tok_f2] ++ opts_webhook)

      assert {:error, :lease_not_acquired} =
               Deduplication.complete(evt_fail_res2, [lease_token: tok_f2] ++ opts_webhook)

      # Five workers race to reclaim an expired WebhookEvent record
      evt_expire_race = "evt_exp_race_#{System.unique_integer([:positive])}"
      assert {:ok, _tok1} = Deduplication.acquire(evt_expire_race, opts_webhook)
      two_min_ago = DateTime.add(DateTime.utc_now(), -120, :second)

      Ash.update!(
        Ash.get!(WebhookEvent, evt_expire_race, domain: Domain),
        %{
          last_attempt_at: two_min_ago
        },
        domain: Domain
      )

      reclaim_results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> Deduplication.acquire(evt_expire_race, opts_webhook) end)
        end)
        |> Enum.map(&Task.await(&1, 5000))

      assert Enum.count(reclaim_results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(reclaim_results, &match?({:error, :already_processing}, &1)) == 4

      # Sweep callback
      send(Process.whereis(AshBilling.Deduplication), :sweep)
    end

    test "memory strategy legacy tuple formats and fallback branches" do
      # Legacy 3-tuple :processed in memory
      :ets.insert(:ash_billing_processed_events, {"evt_mem_legacy_proc", :processed, 12345})

      assert {:error, :already_processed} =
               Deduplication.acquire("evt_mem_legacy_proc", deduplication_strategy: :memory)

      # Legacy 3-tuple :processing in memory
      :ets.insert(:ash_billing_processed_events, {"evt_mem_legacy_proc2", :processing, 12345})
      assert :ok = Deduplication.complete("evt_mem_legacy_proc2", deduplication_strategy: :memory)

      # Legacy 3-tuple :failed in memory
      :ets.insert(:ash_billing_processed_events, {"evt_mem_legacy_fail", :failed, 12345})

      assert {:error, :lease_failed} =
               Deduplication.complete("evt_mem_legacy_fail", deduplication_strategy: :memory)

      # Complete on already processed event in memory
      assert {:ok, _} =
               Deduplication.acquire("evt_mem_already_proc", deduplication_strategy: :memory)

      assert :ok = Deduplication.complete("evt_mem_already_proc", deduplication_strategy: :memory)
      assert :ok = Deduplication.complete("evt_mem_already_proc", deduplication_strategy: :memory)

      # Complete on a failed 4-tuple event in memory
      assert {:ok, _} =
               Deduplication.acquire("evt_mem_failed_comp", deduplication_strategy: :memory)

      assert :ok = Deduplication.release("evt_mem_failed_comp", deduplication_strategy: :memory)

      assert {:error, :lease_failed} =
               Deduplication.complete("evt_mem_failed_comp", deduplication_strategy: :memory)

      # Complete on an unseen event in memory
      assert :ok = Deduplication.complete("evt_mem_unseen_1", deduplication_strategy: :memory)

      # Legacy 3-tuples in processed?
      :ets.insert(:ash_billing_processed_events, {"evt_legacy_p_true", :processed, 12345})

      assert Deduplication.processed?("evt_legacy_p_true", deduplication_strategy: :memory) ==
               true

      :ets.insert(:ash_billing_processed_events, {"evt_legacy_p_false", :processing, 12345})

      assert Deduplication.processed?("evt_legacy_p_false", deduplication_strategy: :memory) ==
               false

      :ets.insert(:ash_billing_processed_events, {"evt_legacy_p_fail", :failed, 12345})

      assert Deduplication.processed?("evt_legacy_p_fail", deduplication_strategy: :memory) ==
               false

      :ets.insert(:ash_billing_processed_events, {"evt_legacy_other", :unknown, 12345})

      assert Deduplication.processed?("evt_legacy_other", deduplication_strategy: :memory) ==
               false

      # Legacy 3-tuple release
      :ets.insert(:ash_billing_processed_events, {"evt_legacy_rel_proc", :processing, 12345})
      assert :ok = Deduplication.release("evt_legacy_rel_proc", deduplication_strategy: :memory)

      # delete_memory with mismatching lease token
      :ets.insert(
        :ash_billing_processed_events,
        {"evt_mem_mismatch", :processing, 12345, "token_1"}
      )

      assert {:error, :lease_token_mismatch} =
               Deduplication.release("evt_mem_mismatch",
                 lease_token: "token_2",
                 deduplication_strategy: :memory
               )

      # delete_memory on already failed records
      :ets.insert(
        :ash_billing_processed_events,
        {"evt_mem_already_failed_4", :failed, 12345, "token_1"}
      )

      assert :ok =
               Deduplication.release("evt_mem_already_failed_4",
                 lease_token: "token_1",
                 deduplication_strategy: :memory
               )

      :ets.insert(:ash_billing_processed_events, {"evt_mem_already_failed_3", :failed, 12345})

      assert :ok =
               Deduplication.release("evt_mem_already_failed_3", deduplication_strategy: :memory)

      # complete_memory on 3-tuple :processed
      :ets.insert(:ash_billing_processed_events, {"evt_mem_3tuple_proc", :processed, 12345})
      assert :ok = Deduplication.complete("evt_mem_3tuple_proc", deduplication_strategy: :memory)

      # Reclaim an ETS 3-tuple failed event
      :ets.insert(:ash_billing_processed_events, {"evt_reclaim_failed_3", :failed, 12345})

      assert {:ok, _} =
               Deduplication.acquire("evt_reclaim_failed_3", deduplication_strategy: :memory)

      # Attempting to release a :processed event in ETS memory returns {:error, :already_processed}
      :ets.insert(
        :ash_billing_processed_events,
        {"evt_mem_4tuple_proc", :processed, 12345, "tok_proc"}
      )

      assert {:error, :already_processed} =
               Deduplication.release("evt_mem_4tuple_proc", deduplication_strategy: :memory)

      assert {:error, :already_processed} =
               Deduplication.release("evt_mem_3tuple_proc", deduplication_strategy: :memory)

      assert Deduplication.processed?("evt_mem_4tuple_proc", deduplication_strategy: :memory) ==
               true

      assert Deduplication.processed?("evt_mem_3tuple_proc", deduplication_strategy: :memory) ==
               true

      # Nil arguments to API functions
      assert :ok = Deduplication.release(nil)
      assert :ok = Deduplication.complete(nil)
      assert false == Deduplication.processed?(nil)
    end

    test "real concurrency: exactly one process wins the acquisition race across multiple parallel tasks" do
      event_id = "evt_parallel_race_#{System.unique_integer([:positive])}"

      opts = [
        deduplication_strategy: :resource,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      # 10 concurrent processes race to acquire the same event simultaneously
      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Deduplication.acquire(event_id, opts)
          end)
        end)
        |> Enum.map(&Task.await(&1, 5000))

      acquired_results = Enum.filter(results, fn res -> match?({:ok, _token}, res) end)

      busy_results =
        Enum.filter(results, fn res -> match?({:error, :already_processing}, res) end)

      # Exactly one process MUST succeed
      assert length(acquired_results) == 1
      assert length(busy_results) == 9

      [{:ok, winning_token}] = acquired_results
      assert is_binary(winning_token)

      # Complete the winning lease
      assert :ok = Deduplication.complete(event_id, [lease_token: winning_token] ++ opts)
      assert Deduplication.processed?(event_id, opts) == true
    end

    test "real concurrency: exactly one process reclaims an expired or failed lease among concurrent tasks" do
      event_id = "evt_parallel_reclaim_#{System.unique_integer([:positive])}"

      opts = [
        deduplication_strategy: :resource,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      # Initial acquisition and failure
      assert {:ok, token1} = Deduplication.acquire(event_id, opts)

      assert :ok =
               Deduplication.release(
                 event_id,
                 [lease_token: token1, error: :test_failure] ++ opts
               )

      # 10 concurrent processes race to reclaim the failed event simultaneously
      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Deduplication.acquire(event_id, opts)
          end)
        end)
        |> Enum.map(&Task.await(&1, 5000))

      acquired_results = Enum.filter(results, fn res -> match?({:ok, _token}, res) end)

      busy_results =
        Enum.filter(results, fn res -> match?({:error, :already_processing}, res) end)

      # Exactly one process MUST succeed in reclaiming the lease
      assert length(acquired_results) == 1
      assert length(busy_results) == 9

      [{:ok, reclaim_token}] = acquired_results
      assert is_binary(reclaim_token)
      assert reclaim_token != token1
    end

    test "zombie worker protection: expired worker cannot complete or release lease after reclamation" do
      event_id = "evt_zombie_#{System.unique_integer([:positive])}"

      opts = [
        deduplication_strategy: :resource,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      # Worker 1 acquires lease
      assert {:ok, token_worker1} = Deduplication.acquire(event_id, opts)

      # Worker 1 takes too long (> 60s lease_ttl). Manually set last_attempt_at in the past
      past_dt = DateTime.utc_now() |> DateTime.add(-75, :second)

      {:ok, record} = Ash.get(WebhookEvent, event_id, domain: Domain, authorize?: false)

      {:ok, _} =
        Ash.update(record, %{last_attempt_at: past_dt}, domain: Domain, authorize?: false)

      # Worker 2 detects expired lease and reclaims it
      assert {:ok, token_worker2} = Deduplication.acquire(event_id, opts)
      assert token_worker2 != token_worker1

      # Zombie Worker 1 wakes up and attempts to complete its old lease -> MUST BE REJECTED
      assert {:error, :lease_token_mismatch} =
               Deduplication.complete(event_id, [lease_token: token_worker1] ++ opts)

      # Zombie Worker 1 attempts to release its old lease -> MUST BE REJECTED
      assert {:error, :lease_token_mismatch} =
               Deduplication.release(event_id, [lease_token: token_worker1] ++ opts)

      # Worker 2 successfully completes its active lease
      assert :ok = Deduplication.complete(event_id, [lease_token: token_worker2] ++ opts)
      assert Deduplication.processed?(event_id, opts) == true
    end

    test "handles nil event_id gracefully across all operations" do
      assert :ok = Deduplication.release(nil)
      assert :ok = Deduplication.complete(nil)
      assert :ok = Deduplication.mark_processed(nil)
      refute Deduplication.processed?(nil)
    end

    test "handles ETS periodic sweep message" do
      pid = Process.whereis(AshBilling.Deduplication)
      assert is_pid(pid)
      send(pid, :sweep)
      # Process remains alive and responsive
      assert Process.alive?(pid)
    end

    test "reclaiming lease fails on resource without :update action (no blind destroy race)" do
      alias AshBilling.Test.NoUpdateEvent
      event_id = "evt_no_update_reclaim_1"
      opts = [deduplication_resource: NoUpdateEvent, domain: Domain, lease_ttl: 1]

      past_dt = DateTime.utc_now() |> DateTime.add(-120, :second)

      # Create an expired processing record
      assert {:ok, _} =
               Ash.create(
                 NoUpdateEvent,
                 %{
                   event_id: event_id,
                   status: :processing,
                   lease_token: "old_token",
                   last_attempt_at: past_dt
                 },
                 domain: Domain,
                 authorize?: false
               )

      # Reclaim strictly requires an atomic :update action; blind delete-and-recreate is rejected
      assert {:error, :resource_lacks_update_action} = Deduplication.acquire(event_id, opts)

      # Record in DB was NOT deleted by a blind destroy race
      assert {:ok, record} = Ash.get(NoUpdateEvent, event_id, domain: Domain, authorize?: false)
      assert record.lease_token == "old_token"
      assert record.status == :processing
    end

    test "reclaiming lease fails on resource without :update and without :destroy" do
      alias AshBilling.Test.NoUpdateNoDestroyEvent
      event_id = "evt_no_update_no_destroy_1"
      opts = [deduplication_resource: NoUpdateNoDestroyEvent, domain: Domain, lease_ttl: 1]

      past_dt = DateTime.utc_now() |> DateTime.add(-120, :second)

      assert {:ok, _} =
               Ash.create(
                 NoUpdateNoDestroyEvent,
                 %{
                   event_id: event_id,
                   status: :processing,
                   lease_token: "old_token",
                   last_attempt_at: past_dt
                 },
                 domain: Domain,
                 authorize?: false
               )

      assert {:error, :resource_lacks_update_action} = Deduplication.acquire(event_id, opts)

      # Release on resource without update or destroy returns error
      assert {:error, :cannot_release_lease} = Deduplication.release(event_id, opts)
    end

    test "release returns :ok if event is already :failed" do
      event_id = "evt_already_failed_release"
      opts = [deduplication_resource: WebhookEvent, domain: Domain]

      assert {:ok, token} = Deduplication.acquire(event_id, opts)
      assert :ok = Deduplication.release(event_id, opts ++ [lease_token: token])

      # Second release on already :failed event returns :ok idempotently
      assert :ok = Deduplication.release(event_id, opts ++ [lease_token: token])
    end

    test "release returns :lease_token_mismatch if event is still processing under another token" do
      event_id = "evt_token_mismatch_release"
      opts = [deduplication_resource: WebhookEvent, domain: Domain]

      assert {:ok, _token} = Deduplication.acquire(event_id, opts)

      # Releasing with wrong token returns :lease_token_mismatch
      assert {:error, :lease_token_mismatch} =
               Deduplication.release(event_id, opts ++ [lease_token: "wrong_token"])
    end

    test "release without token strictly refuses to invalidate or mutate a :processed event" do
      event_id = "evt_processed_cannot_be_invalidated"
      opts = [deduplication_resource: WebhookEvent, domain: Domain]

      assert {:ok, token} = Deduplication.acquire(event_id, opts)
      assert :ok = Deduplication.complete(event_id, [lease_token: token] ++ opts)

      # Attempting to release a completed/processed event without token returns {:error, :already_processed}
      assert {:error, :already_processed} = Deduplication.release(event_id, opts)

      # Status in database remains intact as :processed
      assert {:ok, record} = Ash.get(WebhookEvent, event_id, domain: Domain, authorize?: false)
      assert record.status == :processed
    end
  end
end
