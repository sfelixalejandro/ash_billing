defmodule AshBilling.Diagnostics do
  @moduledoc """
  Layered diagnostics for verifying `AshBilling` structural contracts, PostgreSQL
  schema readiness, and optional read-only provider connectivity.

  Diagnostics are divided into three independent layers:

  1. `:structural` — Pure static checks on Ash resources, attributes, relationships,
     calculations, identities, write-protection, private exposure of `WebhookEvent`,
     single-Repo compatibility, multitenancy alignment, deduplication strategy,
     credential prefixes (without printing secrets), and HTTP timeout configuration.
  2. `:database` (opt-in via `check_database?: true`) — Read-only PostgreSQL
     connectivity, required tables and columns (including `0.6.0` `last_reconciled_at`
     and `0.7.0` `quantity` / `provider_subscription_item_id`), critical unique indexes,
     and optional non-negative quantity check constraint.
  3. `:provider` (opt-in via `check_provider?: true`) — Optional read-only provider
     probe (Stripe `GET /v1/balance` by default) confirming reachability and livemode
     alignment without exposing credentials.

  `configuration_valid` and `production_ready` are deliberately separate booleans:
  a configuration with no failures (`configuration_valid: true`) is **not** marked
  `production_ready: true` if warnings remain (such as in-memory deduplication,
  unbounded HTTP retry/timeout defaults, unverified database schema, or missing
  `expected_livemode`).
  """

  alias AshBilling.Resource.Info, as: ResourceInfo

  @type status :: :pass | :warn | :fail
  @type layer :: :structural | :database | :provider

  @type check :: %{
          id: atom(),
          layer: layer(),
          status: status(),
          message: String.t(),
          remediation: String.t() | nil
        }

  @type report :: %{
          status: status(),
          configuration_valid: boolean(),
          production_ready: boolean(),
          summary: %{pass: non_neg_integer(), warn: non_neg_integer(), fail: non_neg_integer()},
          layers: %{structural: [check()], database: [check()], provider: [check()]},
          checks: [check()]
        }

  @financial_attrs [
    :status,
    :price_id,
    :quantity,
    :provider_subscription_item_id,
    :current_period_end,
    :trial_ends_at,
    :cancel_at_period_end,
    :cancel_at,
    :last_event_created_at,
    :last_reconciled_at
  ]

  @doc """
  Runs diagnostics and returns a structured, JSON-serializable report.

  ## Options

    * `:customer_resource` - Ash customer resource module.
    * `:subscription_resource` - Ash subscription resource module.
    * `:deduplication_resource` / `:webhook_event_resource` - Ash webhook event resource module.
    * `:deduplication_strategy` - `:resource` or `:memory` (defaults to application config or `:resource` when `:deduplication_resource` is provided).
    * `:api_key` - Provider API key (format checked only; never echoed).
    * `:webhook_secret` - Webhook signing secret (format checked only; never echoed).
    * `:expected_livemode` - Optional boolean (`true` / `false`) for Stripe webhook mode binding.
    * `:stripe_account` - Optional Connect account ID.
    * `:req_opts` / `:req_options` - Outbound HTTP `Req` options to validate bounded timeouts and retry settings.
    * `:check_database?` - When `true`, executes read-only PostgreSQL connectivity, column, and index checks. Defaults to `false`.
    * `:check_provider?` - When `true`, executes a read-only provider connectivity/livemode probe. Defaults to `false`.
    * `:provider_check_fun` - Optional 1-arity function `(opts) -> {:ok, %{livemode: boolean()}} | {:error, term()}` for custom providers or testing.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) when is_list(opts) do
    customer_res = Keyword.get(opts, :customer_resource)
    sub_res = Keyword.get(opts, :subscription_resource)

    dedup_res =
      Keyword.get(opts, :deduplication_resource) || Keyword.get(opts, :webhook_event_resource)

    structural =
      []
      |> check_customer_resource(customer_res)
      |> check_subscription_resource(sub_res)
      |> check_webhook_event_resource(dedup_res)
      |> check_data_layers_and_repos([customer_res, sub_res, dedup_res])
      |> check_deduplication_strategy(dedup_res, opts)
      |> check_multitenancy(customer_res, sub_res, dedup_res)
      |> check_api_key(opts)
      |> check_webhook_secret(opts)
      |> check_webhook_scope(opts)
      |> check_http_timeouts(opts)
      |> Enum.reverse()

    database =
      if Keyword.get(opts, :check_database?, false) do
        run_database_checks(customer_res, sub_res, dedup_res, opts)
      else
        []
      end

    provider =
      if Keyword.get(opts, :check_provider?, false) do
        run_provider_checks(opts)
      else
        []
      end

    checks = structural ++ database ++ provider
    summary = summarize(checks)

    overall_status =
      cond do
        summary.fail > 0 -> :fail
        summary.warn > 0 -> :warn
        true -> :pass
      end

    configuration_valid = summary.fail == 0

    database_verified? =
      database != [] and Enum.all?(database, &(&1.status in [:pass, :warn]))

    production_ready =
      configuration_valid and
        summary.warn == 0 and
        database_verified? and
        not is_nil(dedup_res) and
        not is_nil(sub_res)

    %{
      status: overall_status,
      configuration_valid: configuration_valid,
      production_ready: production_ready,
      summary: summary,
      layers: %{
        structural: structural,
        database: database,
        provider: provider
      },
      checks: checks
    }
  end

  @doc """
  Formats a diagnostics report as human-readable text with `PASS`, `WARN`, and `FAIL` statuses.
  """
  @spec format_text(report()) :: String.t()
  def format_text(report) do
    sections =
      [
        {"Structural", report.layers.structural},
        {"Database", report.layers.database},
        {"Provider", report.layers.provider}
      ]
      |> Enum.reject(fn {_title, list} -> list == [] end)
      |> Enum.map_join("\n\n", fn {title, list} ->
        lines =
          Enum.map_join(list, "\n", fn check ->
            tag = check.status |> Atom.to_string() |> String.upcase()
            base = "  [#{tag}] #{check.id}: #{check.message}"

            if check.remediation do
              base <> "\n         -> #{check.remediation}"
            else
              base
            end
          end)

        "#{title}:\n#{lines}"
      end)

    header =
      "AshBilling Doctor — status=#{String.upcase(to_string(report.status))} " <>
        "(pass=#{report.summary.pass}, warn=#{report.summary.warn}, fail=#{report.summary.fail})"

    footer =
      "Summary: configuration_valid=#{report.configuration_valid}, production_ready=#{report.production_ready}"

    [header, sections, footer]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # ---------------------------------------------------------------------------
  # Structural Checks
  # ---------------------------------------------------------------------------

  defp check_customer_resource(acc, nil), do: acc

  defp check_customer_resource(acc, res) do
    if valid_ash_resource?(res) do
      attr = ResourceInfo.customer_id_attribute(res)

      acc =
        if Ash.Resource.Info.attribute(res, attr) do
          add_check(
            acc,
            :customer_id_attribute,
            :structural,
            :pass,
            "Customer resource #{inspect(res)} defines #{inspect(attr)}"
          )
        else
          add_check(
            acc,
            :customer_id_attribute,
            :structural,
            :fail,
            "Customer resource #{inspect(res)} is missing attribute #{inspect(attr)}",
            "Add `extensions: [AshBilling.Resource]` or declare attribute #{inspect(attr)}."
          )
        end

      acc =
        if Ash.Resource.Info.attribute(res, :billing_deleted_at) do
          add_check(
            acc,
            :customer_tombstone_attribute,
            :structural,
            :pass,
            "Customer resource #{inspect(res)} defines :billing_deleted_at tombstone"
          )
        else
          add_check(
            acc,
            :customer_tombstone_attribute,
            :structural,
            :warn,
            "Customer resource #{inspect(res)} is missing :billing_deleted_at attribute",
            "Use `extensions: [AshBilling.Resource]` and apply the 0.4+ customer deletion migration."
          )
        end

      acc =
        if Ash.Resource.Info.relationship(res, :subscriptions) do
          add_check(
            acc,
            :customer_subscriptions_relationship,
            :structural,
            :pass,
            "Customer resource #{inspect(res)} defines :subscriptions relationship"
          )
        else
          add_check(
            acc,
            :customer_subscriptions_relationship,
            :structural,
            :fail,
            "Customer resource #{inspect(res)} is missing :subscriptions relationship",
            "Declare `has_many :subscriptions, YourSubscriptionResource` on #{inspect(res)}."
          )
        end

      check_primary_update_action(acc, :customer_update_action, "Customer", res)
    else
      add_check(
        acc,
        :customer_resource_valid,
        :structural,
        :fail,
        "Customer resource #{inspect(res)} is not a valid Ash.Resource",
        "Pass an existing Ash.Resource module using AshBilling.Resource."
      )
    end
  end

  defp check_subscription_resource(acc, nil), do: acc

  defp check_subscription_resource(acc, res) do
    if valid_ash_resource?(res) do
      required_attrs = [:provider_subscription_id, :status, :price_id]

      missing_attrs =
        Enum.reject(required_attrs, fn a -> Ash.Resource.Info.attribute(res, a) != nil end)

      acc =
        if missing_attrs == [] do
          add_check(
            acc,
            :subscription_required_attributes,
            :structural,
            :pass,
            "Subscription resource #{inspect(res)} defines core billing attributes"
          )
        else
          add_check(
            acc,
            :subscription_required_attributes,
            :structural,
            :fail,
            "Subscription resource #{inspect(res)} is missing required attributes: #{inspect(missing_attrs)}",
            "Add `extensions: [AshBilling.Subscription]` to #{inspect(res)}."
          )
        end

      acc =
        if Ash.Resource.Info.calculation(res, :active?) do
          add_check(
            acc,
            :subscription_active_calculation,
            :structural,
            :pass,
            "Subscription resource #{inspect(res)} defines :active? calculation"
          )
        else
          add_check(
            acc,
            :subscription_active_calculation,
            :structural,
            :fail,
            "Subscription resource #{inspect(res)} is missing :active? calculation",
            "Add `extensions: [AshBilling.Subscription]` to #{inspect(res)}."
          )
        end

      acc = check_optional_sync_attributes(acc, res)
      acc = check_subscription_identity(acc, res)
      acc = check_primary_update_action(acc, :subscription_update_action, "Subscription", res)
      check_explicit_financial_accepts(acc, res)
    else
      add_check(
        acc,
        :subscription_resource_valid,
        :structural,
        :fail,
        "Subscription resource #{inspect(res)} is not a valid Ash.Resource",
        "Pass an existing Ash.Resource module using AshBilling.Subscription."
      )
    end
  end

  defp check_optional_sync_attributes(acc, res) do
    sync_attrs = [
      {:last_event_created_at, "0.4+"},
      {:last_reconciled_at, "0.6.0"},
      {:quantity, "0.7.0"},
      {:provider_subscription_item_id, "0.7.0"}
    ]

    missing =
      Enum.filter(sync_attrs, fn {attr, _ver} -> Ash.Resource.Info.attribute(res, attr) == nil end)

    if missing == [] do
      add_check(
        acc,
        :subscription_sync_attributes,
        :structural,
        :pass,
        "Subscription resource #{inspect(res)} includes 0.6.0 reconciliation and 0.7.0 quantity attributes"
      )
    else
      names = Enum.map(missing, &elem(&1, 0))

      add_check(
        acc,
        :subscription_sync_attributes,
        :structural,
        :warn,
        "Subscription resource #{inspect(res)} is missing synchronized financial attributes: #{inspect(names)}",
        "Use `extensions: [AshBilling.Subscription]` and run migrations for 0.6.0/0.7.0."
      )
    end
  end

  defp check_subscription_identity(acc, res) do
    has_identity? =
      res
      |> Ash.Resource.Info.identities()
      |> Enum.any?(&(&1.keys == [:provider_subscription_id] and is_nil(&1.where)))

    if has_identity? do
      add_check(
        acc,
        :subscription_unique_identity,
        :structural,
        :pass,
        "Subscription resource #{inspect(res)} declares unconditional identity on :provider_subscription_id"
      )
    else
      add_check(
        acc,
        :subscription_unique_identity,
        :structural,
        :fail,
        "Subscription resource #{inspect(res)} is missing unconditional identity on :provider_subscription_id",
        "Use `extensions: [AshBilling.Subscription]` or define `identity :unique_provider_subscription, [:provider_subscription_id]`."
      )
    end
  end

  defp check_explicit_financial_accepts(acc, res) do
    exposed =
      res
      |> Ash.Resource.Info.actions()
      |> Enum.filter(&(&1.type in [:create, :update]))
      |> Enum.flat_map(fn action ->
        accepted = Map.get(action, :accept, []) || []
        overlap = Enum.filter(@financial_attrs, &(&1 in accepted))
        if overlap == [], do: [], else: [{action.name, overlap}]
      end)

    if exposed == [] do
      add_check(
        acc,
        :subscription_financial_write_boundary,
        :structural,
        :pass,
        "No create/update actions on #{inspect(res)} explicitly accept protected financial attributes"
      )
    else
      action_names = Enum.map(exposed, &elem(&1, 0))

      add_check(
        acc,
        :subscription_financial_write_boundary,
        :structural,
        :warn,
        "Subscription actions #{inspect(action_names)} on #{inspect(res)} explicitly accept financial attributes; verify strict Ash policies",
        "Wildcard protection does not override explicit `accept` lists; restrict these actions to trusted system actors."
      )
    end
  end

  defp check_webhook_event_resource(acc, nil), do: acc

  defp check_webhook_event_resource(acc, res) do
    if valid_ash_resource?(res) do
      required = [:event_id, :status, :lease_token, :attempts, :last_attempt_at, :processed_at]

      missing =
        Enum.reject(required, fn attr -> Ash.Resource.Info.attribute(res, attr) != nil end)

      acc =
        if missing == [] do
          add_check(
            acc,
            :webhook_event_attributes,
            :structural,
            :pass,
            "WebhookEvent resource #{inspect(res)} defines required lease/deduplication attributes"
          )
        else
          add_check(
            acc,
            :webhook_event_attributes,
            :structural,
            :fail,
            "WebhookEvent resource #{inspect(res)} is missing required attributes: #{inspect(missing)}",
            "Add `extensions: [AshBilling.WebhookEvent]` to #{inspect(res)}."
          )
        end

      check_webhook_event_privacy(acc, res)
    else
      add_check(
        acc,
        :webhook_event_resource_valid,
        :structural,
        :fail,
        "WebhookEvent resource #{inspect(res)} is not a valid Ash.Resource",
        "Pass an existing Ash.Resource module using AshBilling.WebhookEvent."
      )
    end
  end

  defp check_webhook_event_privacy(acc, res) do
    extensions = Spark.extensions(res)

    public_api_extensions =
      Enum.filter(extensions, fn ext ->
        ext in [AshJsonApi.Resource, AshGraphql.Resource] or
          Atom.to_string(ext) in ["Elixir.AshJsonApi.Resource", "Elixir.AshGraphql.Resource"]
      end)

    if public_api_extensions == [] do
      add_check(
        acc,
        :webhook_event_private,
        :structural,
        :pass,
        "WebhookEvent resource #{inspect(res)} is not exposed via AshJsonApi or AshGraphql"
      )
    else
      add_check(
        acc,
        :webhook_event_private,
        :structural,
        :fail,
        "WebhookEvent resource #{inspect(res)} exposes internal deduplication state via #{inspect(public_api_extensions)}",
        "Remove AshJsonApi.Resource / AshGraphql.Resource from #{inspect(res)}; WebhookEvent must remain private."
      )
    end
  end

  defp check_primary_update_action(acc, id, label, res) do
    action =
      Ash.Resource.Info.primary_action(res, :update) ||
        Ash.Resource.Info.action(res, :update)

    if action do
      add_check(
        acc,
        id,
        :structural,
        :pass,
        "#{label} resource #{inspect(res)} defines update action #{inspect(action.name)}"
      )
    else
      add_check(
        acc,
        id,
        :structural,
        :fail,
        "#{label} resource #{inspect(res)} is missing an :update action required for atomic webhook synchronization",
        "Define a primary :update action on #{inspect(res)}."
      )
    end
  end

  defp check_data_layers_and_repos(acc, resources) do
    valid = Enum.filter(resources, &valid_ash_resource?/1)

    if valid == [] do
      acc
    else
      pg_resources =
        Enum.filter(valid, fn res ->
          Code.ensure_loaded?(AshPostgres.DataLayer) and
            Ash.DataLayer.data_layer(res) == AshPostgres.DataLayer
        end)

      cond do
        pg_resources == [] ->
          add_check(
            acc,
            :data_layer_durability,
            :structural,
            :warn,
            "Configured billing resources do not use AshPostgres.DataLayer; cross-node FOR UPDATE locking is unavailable",
            "Use AshPostgres.DataLayer backed by PostgreSQL 16+ for production multi-node deployments."
          )

        length(pg_resources) < length(valid) ->
          non_pg = valid -- pg_resources

          add_check(
            acc,
            :data_layer_consistency,
            :structural,
            :fail,
            "Mixed data layers detected across billing resources; non-PostgreSQL resources: #{inspect(non_pg)}",
            "Configure customer, subscription, and webhook event resources on the same AshPostgres primary Repo."
          )

        true ->
          repos =
            pg_resources
            |> Enum.map(&postgres_repo/1)
            |> Enum.uniq()

          if length(repos) == 1 do
            add_check(
              acc,
              :shared_postgres_repo,
              :structural,
              :pass,
              "All PostgreSQL billing resources share primary repo #{inspect(hd(repos))}"
            )
          else
            add_check(
              acc,
              :shared_postgres_repo,
              :structural,
              :fail,
              "Billing PostgreSQL resources use multiple repos: #{inspect(repos)}",
              "Configure customer, subscription, and webhook event resources to share one primary Ecto Repo."
            )
          end
      end
    end
  end

  defp check_deduplication_strategy(acc, dedup_res, opts) do
    strategy =
      Keyword.get(opts, :deduplication_strategy) ||
        if(dedup_res, do: :resource, else: nil) ||
        Application.get_env(:ash_billing, :deduplication_strategy, :memory)

    case {strategy, dedup_res} do
      {:resource, nil} ->
        add_check(
          acc,
          :deduplication_strategy,
          :structural,
          :fail,
          "Deduplication strategy is :resource but no :deduplication_resource is configured",
          "Pass `deduplication_resource: MyApp.Billing.WebhookEvent` or configure `:deduplication_resource`."
        )

      {:resource, res} ->
        if valid_ash_resource?(res) and postgres_resource?(res) do
          add_check(
            acc,
            :deduplication_strategy,
            :structural,
            :pass,
            "Durable PostgreSQL deduplication configured via #{inspect(res)}"
          )
        else
          add_check(
            acc,
            :deduplication_strategy,
            :structural,
            :warn,
            "Deduplication resource #{inspect(res)} is not backed by AshPostgres; replay durability across nodes is not guaranteed",
            "Back your WebhookEvent resource with AshPostgres.DataLayer on the shared primary Repo."
          )
        end

      {:memory, _} ->
        add_check(
          acc,
          :deduplication_strategy,
          :structural,
          :warn,
          "Deduplication strategy is :memory (ETS); not durable across restarts or multiple nodes",
          "Configure a PostgreSQL-backed `AshBilling.WebhookEvent` resource for production."
        )

      {other, _} ->
        add_check(
          acc,
          :deduplication_strategy,
          :structural,
          :fail,
          "Unsupported deduplication strategy #{inspect(other)}",
          "Use `:resource` (recommended for production) or `:memory`."
        )
    end
  end

  defp check_multitenancy(acc, customer_res, sub_res, dedup_res) do
    resources =
      [
        {:customer, customer_res},
        {:subscription, sub_res},
        {:webhook_event, dedup_res}
      ]
      |> Enum.filter(fn {_k, res} -> valid_ash_resource?(res) end)

    strategies =
      Enum.map(resources, fn {kind, res} ->
        {kind, res, Ash.Resource.Info.multitenancy_strategy(res)}
      end)

    any_mt? = Enum.any?(strategies, fn {_k, _r, strat} -> not is_nil(strat) end)

    if not any_mt? do
      acc
    else
      non_mt = Enum.filter(strategies, fn {_k, _r, strat} -> is_nil(strat) end)

      acc =
        if non_mt == [] do
          add_check(
            acc,
            :multitenancy_alignment,
            :structural,
            :pass,
            "All configured billing resources define multitenancy strategies"
          )
        else
          missing_names = Enum.map(non_mt, fn {k, r, _} -> "#{k} (#{inspect(r)})" end)

          add_check(
            acc,
            :multitenancy_alignment,
            :structural,
            :fail,
            "Inconsistent multitenancy configuration: missing on #{Enum.join(missing_names, ", ")}",
            "Enable matching multitenancy on customer, subscription, and webhook event resources."
          )
        end

      if valid_ash_resource?(dedup_res) and
           Ash.Resource.Info.multitenancy_strategy(dedup_res) == :attribute do
        tenant_attr = Ash.Resource.Info.multitenancy_attribute(dedup_res)
        pks = Ash.Resource.Info.primary_key(dedup_res)

        if tenant_attr in pks and :event_id in pks do
          add_check(
            acc,
            :webhook_event_tenant_pk,
            :structural,
            :pass,
            "Multitenant WebhookEvent primary key includes (#{inspect(tenant_attr)}, :event_id)"
          )
        else
          add_check(
            acc,
            :webhook_event_tenant_pk,
            :structural,
            :fail,
            "Multitenant WebhookEvent #{inspect(dedup_res)} primary key #{inspect(pks)} must include both #{inspect(tenant_attr)} and :event_id",
            "Declare `attribute #{inspect(tenant_attr)}, :string, primary_key?: true, allow_nil?: false` on #{inspect(dedup_res)}."
          )
        end
      else
        acc
      end
    end
  end

  defp check_api_key(acc, opts) do
    key =
      Keyword.get(
        opts,
        :api_key,
        Application.get_env(:ash_billing, :stripe_api_key) ||
          System.get_env("STRIPE_SECRET_KEY")
      )
      |> resolve_credential()

    case key do
      nil ->
        acc

      k when is_binary(k) ->
        if String.starts_with?(k, "sk_") or String.starts_with?(k, "rk_") do
          mode =
            cond do
              String.starts_with?(k, "sk_live_") or String.starts_with?(k, "rk_live_") -> "live"
              String.starts_with?(k, "sk_test_") or String.starts_with?(k, "rk_test_") -> "test"
              true -> "unknown"
            end

          add_check(
            acc,
            :stripe_api_key_format,
            :structural,
            :pass,
            "Stripe API key format is valid (mode=#{mode}, value redacted)"
          )
        else
          add_check(
            acc,
            :stripe_api_key_format,
            :structural,
            :fail,
            "Stripe API key does not start with standard prefix 'sk_' or 'rk'",
            "Configure a valid Stripe secret or restricted key via runtime environment."
          )
        end

      _ ->
        acc
    end
  end

  defp check_webhook_secret(acc, opts) do
    secret =
      Keyword.get(
        opts,
        :webhook_secret,
        Application.get_env(:ash_billing, :stripe_webhook_secret) ||
          System.get_env("STRIPE_WEBHOOK_SECRET")
      )
      |> resolve_credential()

    case secret do
      nil ->
        acc

      s when is_binary(s) ->
        if String.starts_with?(s, "whsec_") do
          add_check(
            acc,
            :stripe_webhook_secret_format,
            :structural,
            :pass,
            "Stripe webhook secret format is valid (value redacted)"
          )
        else
          add_check(
            acc,
            :stripe_webhook_secret_format,
            :structural,
            :fail,
            "Stripe webhook secret does not start with standard prefix 'whsec_'",
            "Configure your Stripe endpoint signing secret (`whsec_...`) via runtime environment."
          )
        end

      _ ->
        acc
    end
  end

  defp check_webhook_scope(acc, opts) do
    account = Keyword.get(opts, :stripe_account)
    expected_livemode = Keyword.get(opts, :expected_livemode, :omitted)

    cond do
      expected_livemode not in [:omitted, nil, true, false] ->
        add_check(
          acc,
          :webhook_livemode_binding,
          :structural,
          :fail,
          "Invalid :expected_livemode option (must be boolean)",
          "Pass `expected_livemode: true` (production) or `expected_livemode: false` (test mode)."
        )

      is_binary(account) and account != "" and expected_livemode not in [true, false] ->
        add_check(
          acc,
          :webhook_livemode_binding,
          :structural,
          :fail,
          "Stripe Connect :stripe_account requires explicit boolean :expected_livemode",
          "Set `expected_livemode: true` or `false` alongside `:stripe_account`."
        )

      expected_livemode in [true, false] ->
        add_check(
          acc,
          :webhook_livemode_binding,
          :structural,
          :pass,
          "Webhook :expected_livemode is explicitly bound to #{expected_livemode}"
        )

      true ->
        add_check(
          acc,
          :webhook_livemode_binding,
          :structural,
          :warn,
          "Webhook :expected_livemode is not explicitly configured",
          "Set `expected_livemode: true` in production (or `false` in test) on AshBilling.Plug."
        )
    end
  end

  defp check_http_timeouts(acc, opts) do
    req_opts = Keyword.get(opts, :req_opts) || Keyword.get(opts, :req_options)

    cond do
      is_nil(req_opts) or req_opts == [] ->
        add_check(
          acc,
          :http_timeout_configuration,
          :structural,
          :warn,
          "No explicit :req_opts configured; Req defaults (receive_timeout: 15_000, retry: :safe_transient, max_retries: 3) can hold PostgreSQL FOR UPDATE locks >60s during Stripe degradation",
          "Configure `req_opts: [connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false]` on AshBilling.Plug and reconcile calls."
        )

      is_list(req_opts) ->
        retry = Keyword.get(req_opts, :retry, :safe_transient)
        receive_timeout = Keyword.get(req_opts, :receive_timeout, 15_000)

        cond do
          retry != false ->
            add_check(
              acc,
              :http_timeout_configuration,
              :structural,
              :warn,
              "HTTP :retry is enabled (#{inspect(retry)}) inside PostgreSQL FOR UPDATE transactions",
              "Set `retry: false` in `:req_opts` so Stripe retries webhooks outside database locks."
            )

          not is_integer(receive_timeout) or receive_timeout > 10_000 ->
            add_check(
              acc,
              :http_timeout_configuration,
              :structural,
              :warn,
              "HTTP :receive_timeout (#{inspect(receive_timeout)}ms) exceeds recommended <= 10_000ms ceiling inside DB locks",
              "Set `receive_timeout: 5_000` and `connect_options: [timeout: 3_000]` in `:req_opts`."
            )

          true ->
            add_check(
              acc,
              :http_timeout_configuration,
              :structural,
              :pass,
              "Bounded HTTP timeouts and retry: false configured (receive_timeout=#{receive_timeout}ms)"
            )
        end

      true ->
        add_check(
          acc,
          :http_timeout_configuration,
          :structural,
          :fail,
          "Invalid :req_opts (expected keyword list)",
          "Pass a keyword list such as `req_opts: [connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false]`."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Database Checks (Read-Only PostgreSQL)
  # ---------------------------------------------------------------------------

  defp run_database_checks(customer_res, sub_res, dedup_res, opts) do
    pg_resources =
      [customer_res, sub_res, dedup_res]
      |> Enum.filter(&postgres_resource?/1)

    repo = Keyword.get(opts, :repo) || find_primary_repo(pg_resources)

    if is_nil(repo) do
      [
        make_check(
          :postgres_repo_missing,
          :database,
          :warn,
          "No AshPostgres repo discovered for database checks",
          "Pass PostgreSQL-backed billing resources or `:repo` when running database diagnostics."
        )
      ]
    else
      case safe_sql_query(repo, "SELECT 1", []) do
        {:ok, _} ->
          []
          |> add_check(
            :postgres_connectivity,
            :database,
            :pass,
            "PostgreSQL connection via #{inspect(repo)} succeeded (read-only)"
          )
          |> check_customer_table(repo, customer_res)
          |> check_subscription_table(repo, sub_res)
          |> check_webhook_event_table(repo, dedup_res)
          |> Enum.reverse()

        {:error, reason} ->
          [
            make_check(
              :postgres_connectivity,
              :database,
              :fail,
              "PostgreSQL connection via #{inspect(repo)} failed: #{sanitize_error(reason)}",
              "Verify database availability, credentials, and Repo startup before deploying."
            )
          ]
      end
    end
  end

  defp check_customer_table(acc, repo, res) do
    if postgres_resource?(res) do
      table = postgres_table(res)
      schema = postgres_schema(res)
      cust_col = Atom.to_string(ResourceInfo.customer_id_attribute(res))

      check_table_columns(
        acc,
        repo,
        schema,
        table,
        :customer_table_columns,
        "Customer table #{table}",
        [cust_col, "billing_deleted_at"],
        "Run `mix ash.codegen` and `mix ecto.migrate` to add missing customer billing columns."
      )
    else
      acc
    end
  end

  defp check_subscription_table(acc, repo, res) do
    if postgres_resource?(res) do
      table = postgres_table(res)
      schema = postgres_schema(res)

      acc =
        check_table_columns(
          acc,
          repo,
          schema,
          table,
          :subscription_core_columns,
          "Subscription table #{table} core columns",
          [
            "provider_subscription_id",
            "status",
            "price_id",
            "current_period_end",
            "cancel_at_period_end",
            "cancel_at",
            "trial_ends_at",
            "last_event_created_at"
          ],
          "Run `mix ash.codegen` and `mix ecto.migrate` to create missing subscription columns."
        )

      acc =
        check_table_columns(
          acc,
          repo,
          schema,
          table,
          :migration_0_6_last_reconciled_at,
          "Subscription table #{table} 0.6.0 migration (last_reconciled_at)",
          ["last_reconciled_at"],
          "Apply the 0.6.0 migration adding nullable `last_reconciled_at` (:utc_datetime_usec)."
        )

      acc =
        check_table_columns(
          acc,
          repo,
          schema,
          table,
          :migration_0_7_quantity_sync,
          "Subscription table #{table} 0.7.0 migration (quantity, provider_subscription_item_id)",
          ["quantity", "provider_subscription_item_id"],
          "Apply the 0.7.0 migration adding nullable `quantity` (:integer) and `provider_subscription_item_id` (:text)."
        )

      expected_unique_cols =
        case Ash.Resource.Info.multitenancy_strategy(res) do
          :attribute ->
            [
              Atom.to_string(Ash.Resource.Info.multitenancy_attribute(res)),
              "provider_subscription_id"
            ]

          _ ->
            ["provider_subscription_id"]
        end

      acc =
        check_unique_index(
          acc,
          repo,
          schema,
          table,
          :subscription_unique_index,
          expected_unique_cols,
          "Create a unique index on #{table}(#{Enum.join(expected_unique_cols, ", ")}) via `mix ash.codegen`."
        )

      check_quantity_constraint(acc, repo, schema, table)
    else
      acc
    end
  end

  defp check_webhook_event_table(acc, repo, res) do
    if postgres_resource?(res) do
      table = postgres_table(res)
      schema = postgres_schema(res)

      acc =
        check_table_columns(
          acc,
          repo,
          schema,
          table,
          :webhook_event_table_columns,
          "WebhookEvent table #{table}",
          [
            "event_id",
            "status",
            "lease_token",
            "attempts",
            "error",
            "last_attempt_at",
            "processed_at"
          ],
          "Run `mix ash.codegen` and `mix ecto.migrate` to create the webhook_events table."
        )

      expected_pk_cols =
        case Ash.Resource.Info.multitenancy_strategy(res) do
          :attribute ->
            [Atom.to_string(Ash.Resource.Info.multitenancy_attribute(res)), "event_id"]

          _ ->
            ["event_id"]
        end

      check_unique_index(
        acc,
        repo,
        schema,
        table,
        :webhook_event_unique_key,
        expected_pk_cols,
        "Ensure primary key / unique constraint on #{table}(#{Enum.join(expected_pk_cols, ", ")})."
      )
    else
      acc
    end
  end

  defp check_table_columns(acc, repo, schema, table, id, label, required_cols, remediation) do
    sql = """
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    """

    case safe_sql_query(repo, sql, [schema, table]) do
      {:ok, %{rows: []}} ->
        add_check(
          acc,
          id,
          :database,
          :fail,
          "#{label}: table #{schema}.#{table} does not exist",
          remediation
        )

      {:ok, %{rows: rows}} ->
        present = MapSet.new(rows, fn [col] -> col end)
        missing = Enum.reject(required_cols, &MapSet.member?(present, &1))

        if missing == [] do
          add_check(acc, id, :database, :pass, "#{label}: all required columns present")
        else
          add_check(
            acc,
            id,
            :database,
            :fail,
            "#{label}: missing column(s) #{inspect(missing)}",
            remediation
          )
        end

      {:error, reason} ->
        add_check(
          acc,
          id,
          :database,
          :fail,
          "#{label}: query failed (#{sanitize_error(reason)})",
          remediation
        )
    end
  end

  defp check_unique_index(acc, repo, schema, table, id, expected_cols, remediation) do
    sql = """
    SELECT array_agg(a.attname::text ORDER BY x.ord) AS cols
    FROM pg_index ix
    JOIN pg_class t ON t.oid = ix.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    CROSS JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS x(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = x.attnum
    WHERE n.nspname = $1
      AND t.relname = $2
      AND ix.indisunique = true
      AND ix.indpred IS NULL
    GROUP BY ix.indexrelid
    """

    expected_set = MapSet.new(expected_cols)

    case safe_sql_query(repo, sql, [schema, table]) do
      {:ok, %{rows: rows}} ->
        matched? =
          Enum.any?(rows, fn [cols] ->
            is_list(cols) and MapSet.new(cols) == expected_set
          end)

        if matched? do
          add_check(
            acc,
            id,
            :database,
            :pass,
            "Unconditional unique index/constraint verified on #{table}(#{Enum.join(expected_cols, ", ")})"
          )
        else
          add_check(
            acc,
            id,
            :database,
            :fail,
            "Missing unconditional unique index/constraint on #{table}(#{Enum.join(expected_cols, ", ")})",
            remediation
          )
        end

      {:error, reason} ->
        add_check(
          acc,
          id,
          :database,
          :fail,
          "Failed to inspect unique indexes on #{table}: #{sanitize_error(reason)}",
          remediation
        )
    end
  end

  defp check_quantity_constraint(acc, repo, schema, table) do
    sql = """
    SELECT pg_get_constraintdef(c.oid)
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = $1 AND t.relname = $2 AND c.contype = 'c'
    """

    case safe_sql_query(repo, sql, [schema, table]) do
      {:ok, %{rows: rows}} ->
        has_check? =
          Enum.any?(rows, fn [def_str] ->
            is_binary(def_str) and String.contains?(def_str, "quantity")
          end)

        if has_check? do
          add_check(
            acc,
            :subscription_quantity_constraint,
            :database,
            :pass,
            "Check constraint on #{table}.quantity is present"
          )
        else
          add_check(
            acc,
            :subscription_quantity_constraint,
            :database,
            :warn,
            "No PostgreSQL CHECK constraint found on #{table}.quantity",
            "Add `CHECK (quantity IS NULL OR quantity >= 0)` to enforce non-negative quantities at the database level."
          )
        end

      {:error, _} ->
        acc
    end
  end

  # ---------------------------------------------------------------------------
  # Provider Checks (Optional Read-Only Probe)
  # ---------------------------------------------------------------------------

  defp run_provider_checks(opts) do
    case Keyword.get(opts, :provider_check_fun) do
      fun when is_function(fun, 1) ->
        evaluate_provider_probe(fun.(opts), opts)

      _ ->
        run_default_stripe_probe(opts)
    end
  end

  defp run_default_stripe_probe(opts) do
    key =
      Keyword.get(
        opts,
        :api_key,
        Application.get_env(:ash_billing, :stripe_api_key) ||
          System.get_env("STRIPE_SECRET_KEY")
      )
      |> resolve_credential()

    if not is_binary(key) or key == "" do
      [
        make_check(
          :provider_connectivity,
          :provider,
          :fail,
          "Provider check requested but no Stripe API key is configured",
          "Configure STRIPE_SECRET_KEY or pass `:api_key` before running `--check-provider`."
        )
      ]
    else
      base_url =
        Keyword.get(
          opts,
          :base_url,
          Application.get_env(:ash_billing, :stripe_base_url, "https://api.stripe.com")
        )

      req_opts =
        [
          base_url: base_url,
          auth: {:bearer, key},
          connect_options: [timeout: 3_000],
          receive_timeout: 5_000,
          retry: false
        ]
        |> Keyword.merge(Keyword.get(opts, :req_opts) || Keyword.get(opts, :req_options) || [])

      result =
        case Req.get(Req.new(req_opts), url: "/v1/balance") do
          {:ok, %{status: 200, body: %{"livemode" => livemode}}} when is_boolean(livemode) ->
            {:ok, %{livemode: livemode}}

          {:ok, %{status: status}} ->
            {:error, {:http_status, status}}

          {:error, reason} ->
            {:error, reason}
        end

      evaluate_provider_probe(result, opts)
    end
  end

  defp evaluate_provider_probe({:ok, %{livemode: livemode}}, opts) when is_boolean(livemode) do
    expected = Keyword.get(opts, :expected_livemode)

    if is_boolean(expected) and expected != livemode do
      [
        make_check(
          :provider_connectivity,
          :provider,
          :fail,
          "Provider livemode (#{livemode}) does not match configured expected_livemode (#{expected})",
          "Align your Stripe API key and :expected_livemode configuration."
        )
      ]
    else
      [
        make_check(
          :provider_connectivity,
          :provider,
          :pass,
          "Provider API reachable (read-only check passed, livemode=#{livemode})"
        )
      ]
    end
  end

  defp evaluate_provider_probe({:error, reason}, _opts) do
    [
      make_check(
        :provider_connectivity,
        :provider,
        :fail,
        "Provider connectivity check failed: #{sanitize_error(reason)}",
        "Verify network reachability, API key validity, and Stripe service status."
      )
    ]
  end

  defp evaluate_provider_probe(other, _opts) do
    [
      make_check(
        :provider_connectivity,
        :provider,
        :fail,
        "Provider check returned unexpected response: #{sanitize_error(other)}",
        "Verify custom provider check function."
      )
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_ash_resource?(res) when is_atom(res) and not is_nil(res) do
    Code.ensure_loaded?(res) and Spark.Dsl.is?(res, Ash.Resource)
  end

  defp valid_ash_resource?(_), do: false

  defp postgres_resource?(res) do
    valid_ash_resource?(res) and
      Code.ensure_loaded?(AshPostgres.DataLayer) and
      Ash.DataLayer.data_layer(res) == AshPostgres.DataLayer
  end

  defp postgres_repo(res), do: apply(AshPostgres.DataLayer.Info, :repo, [res, :mutate])
  defp postgres_table(res), do: apply(AshPostgres.DataLayer.Info, :table, [res])
  defp postgres_schema(res), do: apply(AshPostgres.DataLayer.Info, :schema, [res]) || "public"

  defp find_primary_repo([]), do: nil
  defp find_primary_repo([first | _]), do: postgres_repo(first)

  defp safe_sql_query(repo, sql, params) do
    apply(repo, :query, [sql, params])
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp resolve_credential({mod, fun, args}) when is_atom(mod) and is_atom(fun),
    do: apply(mod, fun, args)

  defp resolve_credential(fun) when is_function(fun, 0), do: fun.()
  defp resolve_credential(val), do: val

  defp sanitize_error(%{__struct__: mod} = err) do
    msg = Exception.message(err) |> redact_secrets()
    "#{inspect(mod)}: #{msg}"
  end

  defp sanitize_error(other), do: other |> inspect() |> redact_secrets()

  defp redact_secrets(str) when is_binary(str) do
    Regex.replace(~r/(?:sk|rk)_(?:test|live)_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+/, str, "[REDACTED]")
  end

  defp add_check(acc, id, layer, status, message, remediation \\ nil) do
    [make_check(id, layer, status, message, remediation) | acc]
  end

  defp make_check(id, layer, status, message, remediation \\ nil) do
    %{
      id: id,
      layer: layer,
      status: status,
      message: message,
      remediation: remediation
    }
  end

  defp summarize(checks) do
    Enum.reduce(checks, %{pass: 0, warn: 0, fail: 0}, fn check, acc ->
      Map.update!(acc, check.status, &(&1 + 1))
    end)
  end
end
