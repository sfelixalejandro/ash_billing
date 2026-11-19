defmodule AshBilling.ReconcilerCliTest do
  @moduledoc """
  Phase B (B3 / B5) tests for AshBilling.Reconciler and mix ash_billing.reconcile:
  dry-run read-only safety, explicit confirmation, Ash policy authorization,
  multitenancy isolation, provider outage handling, pagination, concurrency,
  and CLI text/JSON output.
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias AshBilling.Reconciler

  alias AshBilling.Test.{
    PostgresCustomer,
    PostgresDomain,
    PostgresOwnedScopedSubscription,
    PostgresScopedCustomer,
    PostgresSubscription,
    Repo
  }

  # Authorized resource to test Ash policy enforcement in Reconciler
  defmodule PolicyDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshBilling.ReconcilerCliTest.PolicyCustomer
      resource AshBilling.ReconcilerCliTest.PolicySubscription
    end
  end

  defmodule PolicyCustomer do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.ReconcilerCliTest.PolicyDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.Resource],
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table "billing_test_customers"
      repo(AshBilling.Test.Repo)
    end

    attributes do
      uuid_primary_key :id
      attribute :email, :string, public?: true
    end

    actions do
      default_accept [:*, :stripe_customer_id]
      defaults [:read, :create, :update, :destroy]
    end

    policies do
      policy always() do
        authorize_if expr(id == ^actor(:id))
        authorize_if actor_attribute_equals(:role, :admin)
      end
    end
  end

  defmodule PolicySubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.ReconcilerCliTest.PolicyDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.Subscription],
      authorizers: [Ash.Policy.Authorizer]

    postgres do
      table "billing_test_subscriptions"
      repo(AshBilling.Test.Repo)
    end

    attributes do
      uuid_primary_key :id
      attribute :user_id, :uuid, public?: true
    end

    relationships do
      belongs_to :user, AshBilling.ReconcilerCliTest.PolicyCustomer
    end

    billing_subscription do
      customer_relationship :user
    end

    actions do
      default_accept :*
      defaults [:read, :create, :update, :destroy]
    end

    policies do
      policy action_type(:read) do
        authorize_if expr(user_id == ^actor(:id))
        authorize_if actor_attribute_equals(:role, :admin)
      end

      policy action_type(:update) do
        authorize_if actor_attribute_equals(:role, :admin)
      end
    end
  end

  defmodule MapProvider do
    @moduledoc false
    def get_subscription(sub_id, opts) do
      if pid = Keyword.get(opts, :notify_pid) do
        send(pid, {:provider_get, sub_id, Keyword.get(opts, :stripe_account)})
      end

      case Keyword.get(opts, :responses) do
        %{} = map ->
          case Map.fetch(map, sub_id) do
            {:ok, {:error, _} = err} -> err
            {:ok, payload} -> {:ok, payload}
            :error -> {:error, {:not_found, sub_id}}
          end

        {:error, _} = err ->
          err

        _ ->
          {:error, :unconfigured_provider}
      end
    end
  end

  @opts [domain: PostgresDomain, authorize?: false]

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE billing_test_subscriptions, billing_test_customers, billing_scoped_subscriptions, billing_scoped_customers"
    )

    customer = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_rec_1"}, @opts)
    %{customer: customer}
  end

  defp remote_sub(sub_id, customer_id, price_id, quantity, status \\ "active") do
    %{
      "id" => sub_id,
      "customer" => customer_id,
      "status" => status,
      "cancel_at_period_end" => false,
      "items" => %{
        "data" => [
          %{
            "id" => "si_#{sub_id}",
            "price" => %{"id" => price_id},
            "quantity" => quantity
          }
        ]
      }
    }
  end

  test "requires an explicit selection filter and explicit confirmation before writes", %{
    customer: customer
  } do
    _sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_guard_1",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        @opts
      )

    # Missing selection filter is rejected
    assert {:error, :selection_filter_required} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               authorize?: false
             )

    # Execute without confirm?: true is rejected (no accidental writes)
    assert {:error, :confirmation_required} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               subscription_id: "sub_guard_1",
               mode: :execute,
               authorize?: false
             )
  end

  test "dry-run reports exact drift diff with ZERO PostgreSQL writes, and confirmed execute converges state",
       %{customer: customer} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_drift_1",
          status: :active,
          price_id: "price_basic",
          quantity: 2,
          provider_subscription_item_id: "si_old"
        },
        @opts
      )

    responses = %{
      "sub_drift_1" => remote_sub("sub_drift_1", "cus_rec_1", "price_enterprise", 15)
    }

    # 1) Dry-run detects drift without modifying PostgreSQL
    assert {:ok, dry_report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               customer_resource: PostgresCustomer,
               subscription_id: "sub_drift_1",
               mode: :dry_run,
               authorize?: false,
               provider: MapProvider,
               responses: responses
             )

    assert dry_report.mode == :dry_run
    assert dry_report.total == 1
    assert dry_report.drifted == 1
    assert dry_report.reconciled == 0
    assert dry_report.failed == 0

    [item] = dry_report.results
    assert item.status == :drifted
    assert :price_id in item.changed_fields
    assert :quantity in item.changed_fields
    assert :provider_subscription_item_id in item.changed_fields
    assert item.diff.quantity == %{local: 2, remote: 15}

    # Verify PostgreSQL was NOT mutated during dry-run
    untouched = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert untouched.price_id == "price_basic"
    assert untouched.quantity == 2
    assert is_nil(untouched.last_reconciled_at)

    # 2) Execute with confirm?: true reconciles atomically under FOR UPDATE
    assert {:ok, exec_report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               customer_resource: PostgresCustomer,
               subscription_id: "sub_drift_1",
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               responses: responses
             )

    assert exec_report.mode == :execute
    assert exec_report.reconciled == 1
    assert exec_report.failed == 0

    reloaded = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert reloaded.price_id == "price_enterprise"
    assert reloaded.quantity == 15
    assert reloaded.provider_subscription_item_id == "si_sub_drift_1"
    assert %DateTime{} = reloaded.last_reconciled_at
  end

  test "enforces Ash authorization policies so unauthorized actors cannot read or repair other subscriptions" do
    owner = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_owner"}, @opts)
    other = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_other"}, @opts)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: owner.id,
          provider_subscription_id: "sub_auth_1",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        @opts
      )

    responses = %{"sub_auth_1" => remote_sub("sub_auth_1", "cus_owner", "price_pro", 10)}

    # Unauthorized non-owner actor sees 0 subscriptions (Ash policy filter) and cannot touch owner's sub
    assert {:ok, other_report} =
             Reconciler.run(
               domain: PolicyDomain,
               subscription_resource: PolicySubscription,
               customer_resource: PolicyCustomer,
               subscription_id: "sub_auth_1",
               mode: :execute,
               confirm?: true,
               authorize?: true,
               actor: %{id: other.id, role: :member},
               provider: MapProvider,
               responses: responses
             )

    assert other_report.total == 0
    assert Ash.get!(PostgresSubscription, sub.id, @opts).price_id == "price_basic"

    # Owner (non-admin) can inspect dry-run (read policy allows owner), but CANNOT execute write (update policy requires :admin)
    assert {:ok, owner_dry} =
             Reconciler.run(
               domain: PolicyDomain,
               subscription_resource: PolicySubscription,
               customer_resource: PolicyCustomer,
               subscription_id: "sub_auth_1",
               mode: :dry_run,
               authorize?: true,
               actor: %{id: owner.id, role: :member},
               provider: MapProvider,
               responses: responses
             )

    assert owner_dry.total == 1
    assert owner_dry.drifted == 1

    assert {:ok, owner_exec} =
             Reconciler.run(
               domain: PolicyDomain,
               subscription_resource: PolicySubscription,
               customer_resource: PolicyCustomer,
               subscription_id: "sub_auth_1",
               mode: :execute,
               confirm?: true,
               authorize?: true,
               actor: %{id: owner.id, role: :member},
               provider: MapProvider,
               responses: responses
             )

    assert owner_exec.failed == 1
    assert Ash.get!(PostgresSubscription, sub.id, @opts).price_id == "price_basic"

    # Authorized admin actor repairs successfully
    assert {:ok, admin_exec} =
             Reconciler.run(
               domain: PolicyDomain,
               subscription_resource: PolicySubscription,
               customer_resource: PolicyCustomer,
               subscription_id: "sub_auth_1",
               mode: :execute,
               confirm?: true,
               authorize?: true,
               actor: %{id: other.id, role: :admin},
               provider: MapProvider,
               responses: responses
             )

    assert admin_exec.reconciled == 1
    assert admin_exec.failed == 0
    assert Ash.get!(PostgresSubscription, sub.id, @opts).price_id == "price_pro"
    assert Ash.get!(PostgresSubscription, sub.id, @opts).quantity == 10
  end

  test "enforces tenant isolation and forwards stripe_account for Connect" do
    cust_a =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: "cus_mt_shared"},
        domain: PostgresDomain,
        tenant: "tenant_a",
        authorize?: false
      )

    cust_b =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: "cus_mt_shared"},
        domain: PostgresDomain,
        tenant: "tenant_b",
        authorize?: false
      )

    sub_a =
      Ash.create!(
        PostgresOwnedScopedSubscription,
        %{
          user_id: cust_a.id,
          provider_subscription_id: "sub_mt_1",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        domain: PostgresDomain,
        tenant: "tenant_a",
        authorize?: false
      )

    sub_b =
      Ash.create!(
        PostgresOwnedScopedSubscription,
        %{
          user_id: cust_b.id,
          provider_subscription_id: "sub_mt_1",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        domain: PostgresDomain,
        tenant: "tenant_b",
        authorize?: false
      )

    responses = %{"sub_mt_1" => remote_sub("sub_mt_1", "cus_mt_shared", "price_pro", 20)}

    assert {:ok, report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresOwnedScopedSubscription,
               customer_resource: PostgresScopedCustomer,
               subscription_id: "sub_mt_1",
               tenant: "tenant_a",
               stripe_account: "acct_tenant_a",
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: responses
             )

    assert report.reconciled == 1
    assert_received {:provider_get, "sub_mt_1", "acct_tenant_a"}

    # Tenant A updated; Tenant B completely untouched
    assert Ash.get!(PostgresOwnedScopedSubscription, sub_a.id,
             domain: PostgresDomain,
             tenant: "tenant_a",
             authorize?: false
           ).quantity == 20

    assert Ash.get!(PostgresOwnedScopedSubscription, sub_b.id,
             domain: PostgresDomain,
             tenant: "tenant_b",
             authorize?: false
           ).quantity == 1

    # Wrong tenant returns 0 records
    assert {:ok, wrong_tenant} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresOwnedScopedSubscription,
               subscription_id: "sub_mt_1",
               tenant: "tenant_nonexistent",
               mode: :dry_run,
               authorize?: false,
               provider: MapProvider,
               responses: responses
             )

    assert wrong_tenant.total == 0
  end

  test "paginates bulk filters with bounded concurrency, rate limit, and reports provider outages honestly",
       %{customer: customer} do
    old_ts = DateTime.add(DateTime.utc_now(), -48 * 3600, :second) |> DateTime.truncate(:second)
    recent_ts = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

    # 4 stale subscriptions (3 with nil/old last_reconciled_at + 1 failing provider) + 1 fresh (must be excluded)
    for i <- 1..4 do
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_bulk_#{i}",
          status: :active,
          price_id: "price_basic",
          quantity: nil,
          last_reconciled_at: if(rem(i, 2) == 0, do: old_ts, else: nil)
        },
        @opts
      )
    end

    Ash.create!(
      PostgresSubscription,
      %{
        user_id: customer.id,
        provider_subscription_id: "sub_bulk_fresh",
        status: :active,
        price_id: "price_basic",
        quantity: 5,
        last_reconciled_at: recent_ts
      },
      @opts
    )

    responses = %{
      "sub_bulk_1" => remote_sub("sub_bulk_1", "cus_rec_1", "price_pro", 5),
      "sub_bulk_2" => remote_sub("sub_bulk_2", "cus_rec_1", "price_pro", 10),
      "sub_bulk_3" => {:error, %{status: 503, error: "stripe_unavailable"}},
      "sub_bulk_4" => remote_sub("sub_bulk_4", "cus_rec_1", "price_pro", 20)
    }

    assert {:ok, report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               customer_resource: PostgresCustomer,
               older_than_hours: 24,
               page_size: 2,
               limit: 4,
               concurrency: 2,
               rate_limit_ms: 1,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               responses: responses
             )

    assert report.total == 4
    assert report.reconciled == 3
    assert report.failed == 1
    refute Enum.any?(report.results, &(&1.provider_subscription_id == "sub_bulk_fresh"))

    failed_item = Enum.find(report.results, &(&1.provider_subscription_id == "sub_bulk_3"))
    assert failed_item.status == :failed
    assert failed_item.error =~ "503"
  end

  test "mix ash_billing.reconcile CLI executes dry-run and confirmed writes with text and JSON formatting",
       %{customer: customer} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_cli_1",
          status: :active,
          price_id: "price_basic",
          quantity: nil
        },
        @opts
      )

    responses = %{"sub_cli_1" => remote_sub("sub_cli_1", "cus_rec_1", "price_pro", 8)}

    # Dry-run via CLI execute/2 helper
    assert {:ok, dry} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 customer_resource: inspect(PostgresCustomer),
                 missing_quantity: true,
                 system: true
               ],
               provider: MapProvider,
               responses: responses,
               interactive?: false
             )

    assert dry.mode == :dry_run
    assert dry.drifted == 1
    assert is_nil(Ash.get!(PostgresSubscription, sub.id, @opts).quantity)

    # Execute without --confirm in non-interactive mode fails closed
    assert {:error, :confirmation_required} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 subscription_id: "sub_cli_1",
                 system: true,
                 execute: true
               ],
               provider: MapProvider,
               responses: responses,
               interactive?: false
             )

    # Execute with --confirm persists reconciled quantity
    assert {:ok, exec} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 customer_resource: inspect(PostgresCustomer),
                 subscription_id: "sub_cli_1",
                 system: true,
                 execute: true,
                 confirm: true
               ],
               provider: MapProvider,
               responses: responses,
               interactive?: false
             )

    assert exec.reconciled == 1
    assert Ash.get!(PostgresSubscription, sub.id, @opts).quantity == 8
    assert Reconciler.format_text(exec) =~ "[RECONCILED] sub_cli_1"
    assert Jason.decode!(Jason.encode!(exec))["reconciled"] == 1
  end

  test "validates Reconciler option errors, --id/--status/--all filters, malformed live data, and CLI run/1",
       %{customer: customer} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_cli_run_1",
          status: :active,
          price_id: "price_pro",
          quantity: 5,
          provider_subscription_item_id: "si_sub_cli_run_1"
        },
        @opts
      )

    # 1) Reconciler validation guards
    assert {:error, :invalid_subscription_resource} =
             Reconciler.run(domain: PostgresDomain, subscription_resource: :bad, all?: true)

    assert {:error, :missing_domain} =
             Reconciler.run(subscription_resource: PostgresSubscription, all?: true)

    assert {:error, {:invalid_mode, :bogus}} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               mode: :bogus
             )

    assert {:error, :invalid_page_size} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               page_size: 0
             )

    assert {:error, :invalid_limit} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               limit: 0
             )

    assert {:error, :invalid_concurrency} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               concurrency: 99
             )

    assert {:error, :invalid_rate_limit} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               rate_limit_ms: -1
             )

    # 2) Unchanged subscription in dry-run & execute via --id and --status filters
    identical_responses = %{
      "sub_cli_run_1" => remote_sub("sub_cli_run_1", "cus_rec_1", "price_pro", 5)
    }

    assert {:ok, unchanged_dry} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               id: sub.id,
               mode: :dry_run,
               authorize?: false,
               provider: MapProvider,
               responses: identical_responses
             )

    assert unchanged_dry.unchanged == 1
    assert unchanged_dry.drifted == 0

    assert {:ok, status_exec} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               statuses: ["active"],
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               responses: identical_responses
             )

    assert status_exec.unchanged == 1
    assert status_exec.failed == 0

    # 3) Malformed live provider payload fails closed during dry-run
    malformed_responses = %{
      "sub_cli_run_1" => remote_sub("sub_cli_run_1", "cus_rec_1", "price_pro", -5)
    }

    assert {:ok, malformed_dry} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               mode: :dry_run,
               authorize?: false,
               provider: MapProvider,
               responses: malformed_responses
             )

    assert malformed_dry.failed == 1
    assert hd(malformed_dry.results).error =~ "invalid_quantity"

    # 4) Mix.Tasks.AshBilling.Reconcile.run/1 CLI flag errors & interactive shell output
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(prev_shell) end)

    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      Mix.Tasks.AshBilling.Reconcile.run(["--bogus", "--no-start"])
    end

    assert {:error, :conflicting_mode_flags} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 subscription_id: "sub_cli_run_1",
                 dry_run: true,
                 execute: true
               ],
               interactive?: false
             )

    # Interactive prompt decline prevents accidental write
    send(self(), {:mix_shell_input, :yes?, false})

    assert {:error, :confirmation_required} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 subscription_id: "sub_cli_run_1",
                 system: true,
                 execute: true
               ],
               provider: MapProvider,
               responses: identical_responses
             )

    assert_receive {:mix_shell, :yes?, _}

    # run/1 with no matching subscription outputs clean JSON summary and exits 0
    Mix.Tasks.AshBilling.Reconcile.run([
      "--domain",
      inspect(PostgresDomain),
      "--subscription-resource",
      inspect(PostgresSubscription),
      "--subscription-id",
      "sub_does_not_exist",
      "--system",
      "--json",
      "--no-start"
    ])

    assert_receive {:mix_shell, :info, [json_out]}
    assert Jason.decode!(json_out)["total"] == 0

    # run/1 with text output and status filter
    Mix.Tasks.AshBilling.Reconcile.run([
      "--domain",
      inspect(PostgresDomain),
      "--subscription-resource",
      inspect(PostgresSubscription),
      "--status",
      "canceled",
      "--system",
      "--no-start"
    ])

    assert_receive {:mix_shell, :info, [text_out]}
    assert text_out =~ "AshBilling Reconcile — mode=dry_run (total=0"

    assert_raise Mix.Error, ~r/AshBilling reconcile failed/, fn ->
      Mix.Tasks.AshBilling.Reconcile.run([
        "--domain",
        inspect(PostgresDomain),
        "--subscription-resource",
        inspect(PostgresSubscription),
        "--system",
        "--no-start"
      ])
    end
  end
end
