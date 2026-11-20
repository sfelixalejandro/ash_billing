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

  defmodule LegacyNoQuantityDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshBilling.ReconcilerCliTest.LegacyNoQuantitySubscription
    end
  end

  defmodule LegacyNoQuantitySubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.ReconcilerCliTest.LegacyNoQuantityDomain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :provider_subscription_id, :string, allow_nil?: false, public?: true

      attribute :status, :atom,
        constraints: [one_of: [:active, :past_due, :canceled]],
        allow_nil?: false,
        public?: true
    end

    actions do
      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule ConnectDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshBilling.ReconcilerCliTest.ConnectCustomer
      resource AshBilling.ReconcilerCliTest.ConnectSubscription
    end
  end

  defmodule ConnectCustomer do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.ReconcilerCliTest.ConnectDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.Resource]

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
  end

  defmodule ConnectSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.ReconcilerCliTest.ConnectDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.Subscription]

    postgres do
      table "billing_connect_subscriptions"
      repo(AshBilling.Test.Repo)
    end

    attributes do
      uuid_primary_key :id
      attribute :user_id, :uuid, public?: true
      attribute :stripe_account_id, :string, allow_nil?: true, public?: true
    end

    relationships do
      belongs_to :user, AshBilling.ReconcilerCliTest.ConnectCustomer
    end

    billing_subscription do
      customer_relationship :user
    end

    actions do
      default_accept [
        :*,
        :provider_subscription_id,
        :status,
        :price_id,
        :quantity,
        :provider_subscription_item_id,
        :current_period_end,
        :cancel_at_period_end,
        :cancel_at,
        :trial_ends_at,
        :last_event_created_at,
        :last_reconciled_at,
        :user_id,
        :stripe_account_id
      ]

      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule MapProvider do
    @moduledoc false
    def get_subscription(sub_id, opts) do
      if pid = Keyword.get(opts, :notify_pid) do
        send(pid, {:provider_get, sub_id, Keyword.get(opts, :stripe_account)})
      end

      if pid = Keyword.get(opts, :timed_notify_pid) do
        send(
          pid,
          {:provider_get_timed, sub_id, System.monotonic_time(:millisecond),
           Keyword.get(opts, :stripe_account)}
        )
      end

      if on_call = Keyword.get(opts, :on_call) do
        on_call.(sub_id, opts)
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

  setup_all do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TABLE IF NOT EXISTS billing_connect_subscriptions (
      LIKE billing_test_subscriptions INCLUDING DEFAULTS,
      stripe_account_id TEXT,
      PRIMARY KEY (id)
    )
    """)

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE billing_connect_subscriptions ADD COLUMN IF NOT EXISTS stripe_account_id TEXT"
    )

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE UNIQUE INDEX IF NOT EXISTS billing_connect_subscriptions_unique_provider_subscription_index
    ON billing_connect_subscriptions (provider_subscription_id)
    """)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE billing_connect_subscriptions, billing_test_subscriptions, billing_test_customers, billing_scoped_subscriptions, billing_scoped_customers"
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

  # ---------------------------------------------------------------------------
  # Phase B Hardening Regression Tests (Filter Safety, Isolation, Pacing, Keyset)
  # ---------------------------------------------------------------------------

  test "rejects zero, negative, and non-numeric older_than_hours with zero HTTP calls and zero DB writes",
       %{customer: customer} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_invalid_hours",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        @opts
      )

    responses = %{
      "sub_invalid_hours" => remote_sub("sub_invalid_hours", "cus_rec_1", "price_pro", 99)
    }

    for bad_hours <- [0, 0.0, -1, -24.5, "24", :never] do
      assert {:error, :invalid_older_than_hours} =
               Reconciler.run(
                 domain: PostgresDomain,
                 subscription_resource: PostgresSubscription,
                 older_than_hours: bad_hours,
                 mode: :execute,
                 confirm?: true,
                 authorize?: false,
                 provider: MapProvider,
                 notify_pid: self(),
                 responses: responses
               )
    end

    # Also fails closed via CLI flag (--older-than-hours 0 / -5)
    assert {:error, :invalid_older_than_hours} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 older_than_hours: 0.0,
                 system: true,
                 execute: true,
                 confirm: true
               ],
               provider: MapProvider,
               notify_pid: self(),
               responses: responses,
               interactive?: false
             )

    # Zero outbound HTTP calls and zero PostgreSQL writes
    refute_received {:provider_get, _, _}
    untouched = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert untouched.price_id == "price_basic"
    assert untouched.quantity == 1
    assert is_nil(untouched.last_reconciled_at)
  end

  test "rejects empty, unknown, and mixed statuses with zero HTTP calls and zero DB writes", %{
    customer: customer
  } do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_invalid_status",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        @opts
      )

    responses = %{
      "sub_invalid_status" => remote_sub("sub_invalid_status", "cus_rec_1", "price_pro", 50)
    }

    base = [
      domain: PostgresDomain,
      subscription_resource: PostgresSubscription,
      mode: :execute,
      confirm?: true,
      authorize?: false,
      provider: MapProvider,
      notify_pid: self(),
      responses: responses
    ]

    assert {:error, :invalid_statuses} = Reconciler.run(base ++ [statuses: []])
    assert {:error, :invalid_statuses} = Reconciler.run(base ++ [statuses: :active])

    assert {:error, {:invalid_statuses, [:bogus]}} =
             Reconciler.run(base ++ [statuses: [:bogus]])

    assert {:error, {:invalid_statuses, ["not_a_status"]}} =
             Reconciler.run(base ++ [statuses: ["not_a_status"]])

    assert {:error, {:invalid_statuses, [:bogus]}} =
             Reconciler.run(base ++ [statuses: [:active, :bogus]])

    assert {:error, {:invalid_statuses, ["nope", ""]}} =
             Reconciler.run(base ++ [statuses: ["active", "nope", ""]])

    # CLI --status "" and --status "active,,bogus" also fail closed
    assert {:error, :invalid_statuses} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 status: "   ",
                 system: true
               ],
               provider: MapProvider,
               notify_pid: self(),
               responses: responses,
               interactive?: false
             )

    assert {:error, {:invalid_statuses, ["", "bogus"]}} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: inspect(PostgresDomain),
                 subscription_resource: inspect(PostgresSubscription),
                 status: "active,,bogus",
                 system: true
               ],
               provider: MapProvider,
               notify_pid: self(),
               responses: responses,
               interactive?: false
             )

    refute_received {:provider_get, _, _}
    untouched = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert untouched.price_id == "price_basic"
    assert is_nil(untouched.last_reconciled_at)
  end

  test "rejects missing_quantity?: true and older_than_hours when resource lacks required attributes" do
    assert {:error, :missing_quantity_attribute} =
             Reconciler.run(
               domain: LegacyNoQuantityDomain,
               subscription_resource: LegacyNoQuantitySubscription,
               missing_quantity?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: %{}
             )

    assert {:error, :missing_last_reconciled_at_attribute} =
             Reconciler.run(
               domain: LegacyNoQuantityDomain,
               subscription_resource: LegacyNoQuantitySubscription,
               older_than_hours: 24,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: %{}
             )

    assert {:error, :missing_last_reconciled_at_attribute} =
             Reconciler.run(
               domain: LegacyNoQuantityDomain,
               subscription_resource: LegacyNoQuantitySubscription,
               stale_before: DateTime.utc_now(),
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: %{}
             )

    refute_received {:provider_get, _, _}
  end

  test "all?: true never masks invalid filters, while explicit all?: true alone scans deliberately",
       %{customer: customer} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_all_guard",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        @opts
      )

    responses = %{
      "sub_all_guard" => remote_sub("sub_all_guard", "cus_rec_1", "price_pro", 7)
    }

    # Invalid filters combined with all?: true MUST fail closed with zero HTTP/DB impact
    assert {:error, :invalid_older_than_hours} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               older_than_hours: 0,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: responses
             )

    assert {:error, {:invalid_statuses, [:unknown]}} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               statuses: [:unknown],
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: responses
             )

    assert {:error, :missing_quantity_attribute} =
             Reconciler.run(
               domain: LegacyNoQuantityDomain,
               subscription_resource: LegacyNoQuantitySubscription,
               all?: true,
               missing_quantity?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: %{}
             )

    assert {:error, :conflicting_time_filters} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               older_than_hours: 12,
               stale_before: DateTime.utc_now(),
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: responses
             )

    refute_received {:provider_get, _, _}
    assert Ash.get!(PostgresSubscription, sub.id, @opts).price_id == "price_basic"

    # Explicit all?: true alone selects the subscription deliberately
    assert {:ok, report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               mode: :dry_run,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: responses
             )

    assert report.total == 1
    assert report.drifted == 1
    assert_received {:provider_get, "sub_all_guard", nil}
  end

  test "enforces strict multitenant and Stripe Connect database isolation and fails closed when unscoped",
       %{customer: platform_customer} do
    # 1) Multitenant resource requires :tenant (zero HTTP/DB writes)
    cust_a =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: "cus_iso_a"},
        domain: PostgresDomain,
        tenant: "tenant_a",
        authorize?: false
      )

    cust_b =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: "cus_iso_b"},
        domain: PostgresDomain,
        tenant: "tenant_b",
        authorize?: false
      )

    sub_ta =
      Ash.create!(
        PostgresOwnedScopedSubscription,
        %{
          user_id: cust_a.id,
          provider_subscription_id: "sub_iso_ta",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        domain: PostgresDomain,
        tenant: "tenant_a",
        authorize?: false
      )

    sub_tb =
      Ash.create!(
        PostgresOwnedScopedSubscription,
        %{
          user_id: cust_b.id,
          provider_subscription_id: "sub_iso_tb",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        domain: PostgresDomain,
        tenant: "tenant_b",
        authorize?: false
      )

    mt_responses = %{
      "sub_iso_ta" => remote_sub("sub_iso_ta", "cus_iso_a", "price_pro", 11),
      "sub_iso_tb" => remote_sub("sub_iso_tb", "cus_iso_b", "price_pro", 22)
    }

    assert {:error, :tenant_required} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresOwnedScopedSubscription,
               all?: true,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: mt_responses
             )

    # Non-multitenant resource rejects :tenant instead of silently ignoring it
    assert {:error, :multitenancy_not_configured} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               tenant: "tenant_a",
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: mt_responses
             )

    # Mismatched customer_resource multitenancy fails closed
    assert {:error, :multitenancy_mismatch} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresOwnedScopedSubscription,
               customer_resource: PostgresCustomer,
               all?: true,
               tenant: "tenant_a",
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: mt_responses
             )

    # Bulk Connect on non-multitenant resource WITHOUT a stripe_account column fails closed
    assert {:error, :stripe_account_isolation_required} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               stripe_account: "acct_a",
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: mt_responses
             )

    # Bulk Connect on multitenant resource WITHOUT a stripe_account column fails closed
    # unless stripe_account_scope: :tenant is explicitly acknowledged
    assert {:error, :stripe_account_isolation_required} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresOwnedScopedSubscription,
               customer_resource: PostgresScopedCustomer,
               all?: true,
               tenant: "tenant_a",
               stripe_account: "acct_tenant_a",
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: mt_responses
             )

    refute_received {:provider_get, _, _}

    # Explicit stripe_account_scope: :tenant allows bulk reconciliation strictly scoped to tenant_a
    assert {:ok, tenant_a_report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresOwnedScopedSubscription,
               customer_resource: PostgresScopedCustomer,
               all?: true,
               tenant: "tenant_a",
               stripe_account: "acct_tenant_a",
               stripe_account_scope: :tenant,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: mt_responses
             )

    assert tenant_a_report.total == 1
    assert tenant_a_report.reconciled == 1
    assert_received {:provider_get, "sub_iso_ta", "acct_tenant_a"}
    refute_received {:provider_get, "sub_iso_tb", _}

    assert Ash.get!(PostgresOwnedScopedSubscription, sub_ta.id,
             domain: PostgresDomain,
             tenant: "tenant_a",
             authorize?: false
           ).quantity == 11

    assert Ash.get!(PostgresOwnedScopedSubscription, sub_tb.id,
             domain: PostgresDomain,
             tenant: "tenant_b",
             authorize?: false
           ).quantity == 1

    # 2) Resource WITH per-row stripe_account_id column enforces exact PostgreSQL Connect isolation
    connect_opts = [domain: ConnectDomain, authorize?: false]

    sub_acct_a =
      Ash.create!(
        ConnectSubscription,
        %{
          user_id: platform_customer.id,
          provider_subscription_id: "sub_conn_a",
          status: :active,
          price_id: "price_basic",
          quantity: 1,
          stripe_account_id: "acct_connect_a"
        },
        connect_opts
      )

    sub_acct_b =
      Ash.create!(
        ConnectSubscription,
        %{
          user_id: platform_customer.id,
          provider_subscription_id: "sub_conn_b",
          status: :active,
          price_id: "price_basic",
          quantity: 1,
          stripe_account_id: "acct_connect_b"
        },
        connect_opts
      )

    sub_platform =
      Ash.create!(
        ConnectSubscription,
        %{
          user_id: platform_customer.id,
          provider_subscription_id: "sub_conn_platform",
          status: :active,
          price_id: "price_basic",
          quantity: 1,
          stripe_account_id: nil
        },
        connect_opts
      )

    connect_responses = %{
      "sub_conn_a" => remote_sub("sub_conn_a", "cus_rec_1", "price_pro", 30),
      "sub_conn_b" => remote_sub("sub_conn_b", "cus_rec_1", "price_pro", 40),
      "sub_conn_platform" => remote_sub("sub_conn_platform", "cus_rec_1", "price_pro", 50)
    }

    # Bulk sweep for acct_connect_a ONLY queries and modifies acct_connect_a rows
    assert {:ok, acct_a_report} =
             Reconciler.run(
               domain: ConnectDomain,
               subscription_resource: ConnectSubscription,
               customer_resource: ConnectCustomer,
               all?: true,
               stripe_account: "acct_connect_a",
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: connect_responses
             )

    assert acct_a_report.total == 1
    assert acct_a_report.reconciled == 1
    assert_received {:provider_get, "sub_conn_a", "acct_connect_a"}
    refute_received {:provider_get, "sub_conn_b", _}
    refute_received {:provider_get, "sub_conn_platform", _}

    assert Ash.get!(ConnectSubscription, sub_acct_a.id, connect_opts).quantity == 30
    assert Ash.get!(ConnectSubscription, sub_acct_b.id, connect_opts).quantity == 1
    assert Ash.get!(ConnectSubscription, sub_platform.id, connect_opts).quantity == 1

    # Cross-account single-target lookup for sub_conn_b under acct_connect_a finds 0 rows (0 HTTP calls)
    assert {:ok, cross_acct_report} =
             Reconciler.run(
               domain: ConnectDomain,
               subscription_resource: ConnectSubscription,
               customer_resource: ConnectCustomer,
               subscription_id: "sub_conn_b",
               stripe_account: "acct_connect_a",
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: connect_responses
             )

    assert cross_acct_report.total == 0
    refute_received {:provider_get, "sub_conn_b", _}

    # Platform bulk sweep (stripe_account: nil) ONLY queries/modifies platform (stripe_account_id IS NULL) rows
    assert {:ok, platform_report} =
             Reconciler.run(
               domain: ConnectDomain,
               subscription_resource: ConnectSubscription,
               customer_resource: ConnectCustomer,
               all?: true,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: connect_responses
             )

    assert platform_report.total == 1
    assert platform_report.reconciled == 1
    assert_received {:provider_get, "sub_conn_platform", nil}
    refute_received {:provider_get, "sub_conn_a", _}
    refute_received {:provider_get, "sub_conn_b", _}

    assert Ash.get!(ConnectSubscription, sub_platform.id, connect_opts).quantity == 50
    assert Ash.get!(ConnectSubscription, sub_acct_b.id, connect_opts).quantity == 1

    # Invalid explicit stripe_account_attribute fails closed
    assert {:error, :missing_stripe_account_attribute} =
             Reconciler.run(
               domain: ConnectDomain,
               subscription_resource: ConnectSubscription,
               all?: true,
               stripe_account: "acct_connect_a",
               stripe_account_attribute: "nonexistent_col",
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               responses: connect_responses
             )

    refute_received {:provider_get, _, _}
  end

  test "enforces global rate limiting across concurrent workers (concurrency > 1)", %{
    customer: customer
  } do
    for i <- 1..5 do
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_rate_#{i}",
          status: :active,
          price_id: "price_basic",
          quantity: 1
        },
        @opts
      )
    end

    responses =
      Map.new(1..5, fn i ->
        id = "sub_rate_#{i}"
        {id, remote_sub(id, "cus_rec_1", "price_pro", i)}
      end)

    interval_ms = 40

    assert {:ok, report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               all?: true,
               page_size: 5,
               concurrency: 4,
               rate_limit_ms: interval_ms,
               mode: :dry_run,
               authorize?: false,
               provider: MapProvider,
               timed_notify_pid: self(),
               responses: responses
             )

    assert report.total == 5
    assert report.drifted == 5

    timestamps =
      for _ <- 1..5 do
        assert_received {:provider_get_timed, _id, ts, nil}
        ts
      end
      |> Enum.sort()

    # With 5 calls and global 40ms pacing across 4 concurrent workers:
    # total span must be >= 4 * interval_ms (with small timer jitter margin), NOT ~40ms parallel sleep
    total_span = List.last(timestamps) - hd(timestamps)
    assert total_span >= 4 * (interval_ms - 5)

    # Consecutive calls across all concurrent workers must be globally paced
    gaps =
      timestamps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    assert Enum.all?(gaps, &(&1 >= interval_ms - 10))
  end

  test "streams stable keyset-paginated batches under live mutations with limits, zero omissions, and zero duplicates",
       %{customer: customer} do
    created =
      for i <- 1..7 do
        Ash.create!(
          PostgresSubscription,
          %{
            user_id: customer.id,
            provider_subscription_id: "sub_page_#{i}",
            status: :active,
            price_id: "price_basic",
            quantity: nil,
            last_reconciled_at: nil
          },
          @opts
        )
      end

    sorted_by_pk = Enum.sort_by(created, & &1.id)
    first_page_ids = sorted_by_pk |> Enum.take(2) |> Enum.map(& &1.id)
    page2_sub_ids = sorted_by_pk |> Enum.slice(2, 2) |> Enum.map(& &1.provider_subscription_id)

    responses =
      Map.new(1..7, fn i ->
        id = "sub_page_#{i}"
        {id, remote_sub(id, "cus_rec_1", "price_pro", i * 3)}
      end)

    test_pid = self()

    # Prove streaming batch-by-batch execution: when page 2 starts calling the provider,
    # page 1 rows must ALREADY be committed in PostgreSQL (not loaded-all-upfront).
    on_call = fn sub_id, _opts ->
      if sub_id in page2_sub_ids do
        page1_reconciled? =
          Enum.all?(first_page_ids, fn pk ->
            rec = Ash.get!(PostgresSubscription, pk, @opts)
            not is_nil(rec.last_reconciled_at) and not is_nil(rec.quantity)
          end)

        send(test_pid, {:page1_already_persisted_before_page2, page1_reconciled?})
      end
    end

    # Pass 1: older_than_hours: 24 + missing_quantity?: true with page_size: 2, limit: 5 in :execute mode.
    # Because :execute sets both last_reconciled_at and quantity, naive OFFSET pagination would SKIP pages!
    # Keyset pagination must process exact 5 unique rows across 3 pages (2 + 2 + 1) with ZERO omissions/duplicates.
    assert {:ok, pass1} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               customer_resource: PostgresCustomer,
               older_than_hours: 24,
               missing_quantity?: true,
               page_size: 2,
               limit: 5,
               concurrency: 2,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               notify_pid: self(),
               on_call: on_call,
               responses: responses
             )

    assert pass1.total == 5
    assert pass1.reconciled == 5
    assert pass1.failed == 0
    assert pass1.pages_processed == 3

    assert_received {:page1_already_persisted_before_page2, true}

    pass1_ids = Enum.map(pass1.results, & &1.id)
    assert length(Enum.uniq(pass1_ids)) == 5
    assert pass1_ids == Enum.map(Enum.take(sorted_by_pk, 5), & &1.id)

    # Confirm records 6 and 7 were NEVER queried or mutated during pass 1
    remaining_two = Enum.drop(sorted_by_pk, 5)

    for rec <- remaining_two do
      sub_id = rec.provider_subscription_id
      refute_received {:provider_get, ^sub_id, _}
      reloaded = Ash.get!(PostgresSubscription, rec.id, @opts)
      assert is_nil(reloaded.last_reconciled_at)
      assert is_nil(reloaded.quantity)
    end

    # Pass 2: sweep remaining stale records (no limit) -> reconciles exact remaining 2 with zero duplicates
    assert {:ok, pass2} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               customer_resource: PostgresCustomer,
               older_than_hours: 24,
               missing_quantity?: true,
               page_size: 2,
               concurrency: 2,
               mode: :execute,
               confirm?: true,
               authorize?: false,
               provider: MapProvider,
               responses: responses
             )

    assert pass2.total == 2
    assert pass2.reconciled == 2
    assert pass2.failed == 0
    assert Enum.map(pass2.results, & &1.id) == Enum.map(remaining_two, & &1.id)
  end
end
