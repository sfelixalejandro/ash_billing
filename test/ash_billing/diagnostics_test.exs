defmodule AshBilling.DiagnosticsTest do
  @moduledoc """
  Phase B (B1 / B2 / B5) tests for AshBilling.Diagnostics, extended
  AshBilling.check_configuration/1, and mix ash_billing.doctor.
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias AshBilling.Diagnostics

  alias AshBilling.Test.{
    PostgresCustomer,
    PostgresScopedCustomer,
    PostgresScopedSubscription,
    PostgresSubscription,
    PostgresWebhookEvent,
    Repo
  }

  defmodule UnreachableRepo do
    @moduledoc false
    def query(_sql, _params),
      do: {:error, %DBConnection.ConnectionError{message: "connection refused"}}
  end

  defmodule MissingColumnSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.Test.PostgresDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.Subscription]

    postgres do
      table "diag_missing_cols_subscriptions"
      repo(AshBilling.Test.Repo)
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule ExposedWebhookEvent do
    @moduledoc false
    # Simulates a WebhookEvent resource accidentally exposing AshJsonApi.Resource
    defmodule FakeJsonApi do
      use Spark.Dsl.Extension
    end

    use Ash.Resource,
      domain: AshBilling.Test.PostgresDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.WebhookEvent]

    postgres do
      table "webhook_events"
      repo(AshBilling.Test.Repo)
    end

    actions do
      default_accept :*
      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule CleanProductionSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.Test.PostgresDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.Subscription]

    postgres do
      table "billing_test_subscriptions"
      repo(AshBilling.Test.Repo)
    end

    attributes do
      uuid_primary_key :id
      attribute :user_id, :uuid, public?: true
    end

    relationships do
      belongs_to :user, PostgresCustomer
    end

    billing_subscription do
      customer_relationship :user
    end

    actions do
      default_accept :*
      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule BadMultitenantWebhookEvent do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.Test.PostgresDomain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshBilling.WebhookEvent]

    postgres do
      table "webhook_events"
      repo(AshBilling.Test.Repo)
    end

    multitenancy do
      strategy :attribute
      attribute :tenant_id
    end

    attributes do
      # Deliberately NOT primary_key?: true to test detection
      attribute :tenant_id, :string, allow_nil?: false
    end

    actions do
      default_accept :*
      defaults [:read, :create, :update, :destroy]
    end
  end

  test "passes structural + PostgreSQL diagnostics and distinguishes configuration_valid vs production_ready" do
    # 1) Valid with warnings (missing req_opts and expected_livemode, plus PostgresSubscription has explicit financial accepts)
    #    => configuration_valid: true, production_ready: false!
    report_with_warns =
      Diagnostics.run(
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresSubscription,
        deduplication_resource: PostgresWebhookEvent,
        api_key: "sk_test_never_leak_secret_12345",
        webhook_secret: "whsec_never_leak_secret_67890",
        check_database?: true
      )

    assert report_with_warns.configuration_valid == true
    assert report_with_warns.production_ready == false
    assert report_with_warns.status == :warn
    assert report_with_warns.summary.fail == 0
    assert report_with_warns.summary.warn > 0

    # Ensure secrets NEVER appear in text or JSON output
    text = Diagnostics.format_text(report_with_warns)
    json = Jason.encode!(report_with_warns)
    refute text =~ "sk_test_never_leak_secret_12345"
    refute text =~ "whsec_never_leak_secret_67890"
    refute json =~ "sk_test_never_leak_secret_12345"
    refute json =~ "whsec_never_leak_secret_67890"

    # 2) Fully hardened production-ready setup (wildcard-protected CleanProductionSubscription + bounded req_opts + expected_livemode + PG verified)
    prod_report =
      Diagnostics.run(
        customer_resource: PostgresCustomer,
        subscription_resource: CleanProductionSubscription,
        deduplication_resource: PostgresWebhookEvent,
        api_key: "sk_test_clean_12345",
        webhook_secret: "whsec_clean_67890",
        expected_livemode: false,
        req_opts: [connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false],
        check_database?: true
      )

    assert prod_report.status == :pass
    assert prod_report.configuration_valid == true
    assert prod_report.production_ready == true
    assert prod_report.summary.fail == 0
    assert prod_report.summary.warn == 0

    # Extended AshBilling.check_configuration/1 keeps backwards-compatible API
    assert {:ok, %{status: :valid, production_ready: true, warnings: []}} =
             AshBilling.check_configuration(
               customer_resource: PostgresCustomer,
               subscription_resource: CleanProductionSubscription,
               deduplication_resource: PostgresWebhookEvent,
               api_key: "sk_test_clean_12345",
               webhook_secret: "whsec_clean_67890",
               expected_livemode: false,
               req_opts: [connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false],
               check_database?: true
             )
  end

  test "detects missing 0.6.0 / 0.7.0 PostgreSQL columns and missing unique index" do
    Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS diag_missing_cols_subscriptions")

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TABLE diag_missing_cols_subscriptions (
      id UUID PRIMARY KEY,
      provider_subscription_id TEXT NOT NULL,
      status TEXT NOT NULL,
      price_id TEXT,
      current_period_end TIMESTAMP(6),
      cancel_at_period_end BOOLEAN DEFAULT FALSE,
      cancel_at TIMESTAMP(6),
      trial_ends_at TIMESTAMP(6),
      last_event_created_at TIMESTAMP(6)
    )
    """)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DROP TABLE IF EXISTS diag_missing_cols_subscriptions")
    end)

    report =
      Diagnostics.run(
        subscription_resource: MissingColumnSubscription,
        check_database?: true
      )

    assert report.status == :fail
    assert report.configuration_valid == false
    assert report.production_ready == false

    failed_ids =
      report.layers.database
      |> Enum.filter(&(&1.status == :fail))
      |> Enum.map(& &1.id)

    assert :migration_0_6_last_reconciled_at in failed_ids
    assert :migration_0_7_quantity_sync in failed_ids
    assert :subscription_unique_index in failed_ids

    assert {:error, errors} =
             AshBilling.check_configuration(
               subscription_resource: MissingColumnSubscription,
               check_database?: true
             )

    assert Enum.any?(errors, &(&1 =~ "last_reconciled_at"))
    assert Enum.any?(errors, &(&1 =~ "quantity"))
    assert Enum.any?(errors, &(&1 =~ "unique index"))
  end

  test "detects accidentally exposed WebhookEvent resource via AshJsonApi/AshGraphql" do
    # Dynamically compile a resource whose extensions list includes AshJsonApi.Resource mock
    defmodule :"Elixir.AshJsonApi.Resource" do
      use Spark.Dsl.Extension
    end

    defmodule PubliclyExposedWebhookEvent do
      use Ash.Resource,
        domain: AshBilling.Test.PostgresDomain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshBilling.WebhookEvent, :"Elixir.AshJsonApi.Resource"]

      postgres do
        table "webhook_events"
        repo(AshBilling.Test.Repo)
      end

      actions do
        default_accept :*
        defaults [:read, :create, :update, :destroy]
      end
    end

    report =
      Diagnostics.run(
        deduplication_resource: PubliclyExposedWebhookEvent,
        check_database?: false
      )

    assert report.status == :fail
    privacy_check = Enum.find(report.checks, &(&1.id == :webhook_event_private))
    assert privacy_check.status == :fail
    assert privacy_check.message =~ "exposes internal deduplication state"
  end

  test "detects unreachable PostgreSQL repo cleanly without crashing" do
    report =
      Diagnostics.run(
        subscription_resource: CleanProductionSubscription,
        repo: UnreachableRepo,
        check_database?: true
      )

    assert report.status == :fail
    assert report.configuration_valid == false
    pg_check = Enum.find(report.layers.database, &(&1.id == :postgres_connectivity))
    assert pg_check.status == :fail
    assert pg_check.message =~ "connection refused"
  end

  test "checks optional read-only provider connectivity and rejects livemode mismatch or outage" do
    pass_report =
      Diagnostics.run(
        check_provider?: true,
        expected_livemode: false,
        provider_check_fun: fn _opts -> {:ok, %{livemode: false}} end
      )

    prov_pass = Enum.find(pass_report.layers.provider, &(&1.id == :provider_connectivity))
    assert prov_pass.status == :pass

    mismatch_report =
      Diagnostics.run(
        check_provider?: true,
        expected_livemode: true,
        provider_check_fun: fn _opts -> {:ok, %{livemode: false}} end
      )

    prov_mismatch = Enum.find(mismatch_report.layers.provider, &(&1.id == :provider_connectivity))
    assert prov_mismatch.status == :fail
    assert prov_mismatch.message =~ "does not match"

    outage_report =
      Diagnostics.run(
        check_provider?: true,
        provider_check_fun: fn _opts -> {:error, {:http_status, 503}} end
      )

    prov_outage = Enum.find(outage_report.layers.provider, &(&1.id == :provider_connectivity))
    assert prov_outage.status == :fail
    assert prov_outage.message =~ "503"
  end

  test "detects inconsistent multitenancy and missing tenant primary key on WebhookEvent" do
    report =
      Diagnostics.run(
        customer_resource: PostgresScopedCustomer,
        subscription_resource: PostgresScopedSubscription,
        deduplication_resource: BadMultitenantWebhookEvent,
        check_database?: false
      )

    assert report.status == :fail
    pk_check = Enum.find(report.checks, &(&1.id == :webhook_event_tenant_pk))
    assert pk_check.status == :fail
    assert pk_check.message =~ "must include both :tenant_id and :event_id"

    # Mixed multitenant subscription + non-multitenant customer fails alignment
    mixed_report =
      Diagnostics.run(
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresScopedSubscription,
        deduplication_resource: PostgresWebhookEvent,
        check_database?: false
      )

    align_check = Enum.find(mixed_report.checks, &(&1.id == :multitenancy_alignment))
    assert align_check.status == :fail
  end

  test "mix ash_billing.doctor CLI supports read-only text and JSON output and --strict" do
    # Execute task helper directly with captured Mix.Shell.Process
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(prev_shell) end)

    # JSON output mode (no-start so Mix doesn't restart test app)
    Mix.Tasks.AshBilling.Doctor.run([
      "--customer-resource",
      inspect(PostgresCustomer),
      "--subscription-resource",
      inspect(CleanProductionSubscription),
      "--deduplication-resource",
      inspect(PostgresWebhookEvent),
      "--expected-livemode",
      "false",
      "--json",
      "--no-start"
    ])

    assert_receive {:mix_shell, :info, [json_output]}
    decoded = Jason.decode!(json_output)
    assert decoded["configuration_valid"] == true
    assert is_list(decoded["checks"])

    assert Enum.any?(
             decoded["checks"],
             &(&1["id"] == "migration_0_7_quantity_sync" and &1["status"] == "pass")
           )

    # --strict fails when warnings exist (e.g., default req_opts not configured)
    assert_raise Mix.Error, ~r/status=warn/, fn ->
      Mix.Tasks.AshBilling.Doctor.run([
        "--customer-resource",
        inspect(PostgresCustomer),
        "--subscription-resource",
        inspect(CleanProductionSubscription),
        "--deduplication-resource",
        inspect(PostgresWebhookEvent),
        "--strict",
        "--no-start"
      ])
    end

    assert_receive {:mix_shell, :info, [text_output]}
    assert text_output =~ "[PASS]"
    assert text_output =~ "[WARN]"
    assert text_output =~ "configuration_valid=true, production_ready=false"
  end

  test "validates default Stripe HTTP probe, timeout/retry warnings, mixed data layers, and CLI error flags" do
    # 1) Default Stripe /v1/balance probe via Req.Test plug (200 OK, 500 error, missing api_key)
    ok_plug = fn conn ->
      assert conn.request_path == "/v1/balance"
      Req.Test.json(conn, %{"livemode" => false})
    end

    ok_probe =
      Diagnostics.run(
        check_provider?: true,
        api_key: "sk_test_probe_123",
        expected_livemode: false,
        req_opts: [plug: ok_plug, retry: false, receive_timeout: 5_000]
      )

    assert Enum.find(ok_probe.layers.provider, &(&1.id == :provider_connectivity)).status == :pass

    err_plug = fn conn ->
      Plug.Conn.send_resp(conn, 500, "internal error")
    end

    err_probe =
      Diagnostics.run(
        check_provider?: true,
        api_key: "sk_test_probe_123",
        req_opts: [plug: err_plug, retry: false, receive_timeout: 5_000]
      )

    assert Enum.find(err_probe.layers.provider, &(&1.id == :provider_connectivity)).status ==
             :fail

    no_key_probe =
      Diagnostics.run(
        check_provider?: true,
        api_key: nil
      )

    assert Enum.find(no_key_probe.layers.provider, &(&1.id == :provider_connectivity)).status ==
             :fail

    # 2) Timeout / retry / scope / strategy / mixed data layers edge cases
    warn_retry =
      Diagnostics.run(
        deduplication_strategy: :memory,
        req_opts: [retry: :transient, receive_timeout: 5_000]
      )

    assert Enum.find(warn_retry.checks, &(&1.id == :http_timeout_configuration)).status == :warn
    assert Enum.find(warn_retry.checks, &(&1.id == :deduplication_strategy)).status == :warn

    warn_timeout =
      Diagnostics.run(
        req_opts: [retry: false, receive_timeout: 25_000],
        stripe_account: "acct_connect_1"
      )

    assert Enum.find(warn_timeout.checks, &(&1.id == :http_timeout_configuration)).status == :warn
    assert Enum.find(warn_timeout.checks, &(&1.id == :webhook_livemode_binding)).status == :fail

    bad_opts =
      Diagnostics.run(
        customer_resource: :not_a_resource,
        subscription_resource: :not_a_resource,
        deduplication_resource: :not_a_resource,
        deduplication_strategy: :invalid_strat,
        expected_livemode: "yes",
        req_opts: :not_a_list
      )

    assert bad_opts.status == :fail
    assert Enum.find(bad_opts.checks, &(&1.id == :deduplication_strategy)).status == :fail
    assert Enum.find(bad_opts.checks, &(&1.id == :http_timeout_configuration)).status == :fail
    assert Enum.find(bad_opts.checks, &(&1.id == :webhook_livemode_binding)).status == :fail

    # Mixed AshPostgres + ETS resources fails data layer consistency
    mixed_dl =
      Diagnostics.run(
        customer_resource: AshBilling.Test.User,
        subscription_resource: CleanProductionSubscription,
        deduplication_strategy: :resource,
        deduplication_resource: nil
      )

    assert Enum.find(mixed_dl.checks, &(&1.id == :data_layer_consistency)).status == :fail
    assert Enum.find(mixed_dl.checks, &(&1.id == :deduplication_strategy)).status == :fail

    # Non-postgres check_database?: true emits :postgres_repo_missing warning
    no_pg =
      Diagnostics.run(
        customer_resource: AshBilling.Test.User,
        subscription_resource: AshBilling.Test.Subscription,
        check_database?: true
      )

    assert Enum.find(no_pg.layers.database, &(&1.id == :postgres_repo_missing)).status == :warn

    # 3) CLI option error handling
    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      Mix.Tasks.AshBilling.Doctor.run(["--unknown-flag", "--no-start"])
    end

    assert_raise Mix.Error, ~r/Invalid --expected-livemode/, fn ->
      Mix.Tasks.AshBilling.Doctor.run(["--expected-livemode", "maybe", "--no-start"])
    end

    assert_raise Mix.Error, ~r/Unsupported --format/, fn ->
      Mix.Tasks.AshBilling.Doctor.run(["--format", "yaml", "--no-start"])
    end

    assert_raise Mix.Error, ~r/could not be loaded/, fn ->
      Mix.Tasks.AshBilling.Doctor.run([
        "--customer-resource",
        "NonExistent.Module.XYZ",
        "--no-start"
      ])
    end
  end
end
