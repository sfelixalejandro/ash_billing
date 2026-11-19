defmodule AshBilling.Reconciler do
  @moduledoc """
  Safe, auditable single-subscription and bulk reconciliation runner supporting
  read-only dry-run drift inspection, explicit write confirmation, pagination,
  bounded concurrency, rate limiting, and full actor/tenant/account isolation.

  Used programmatically or via `mix ash_billing.reconcile`.
  """

  require Ash.Query

  alias AshBilling.WebhookSync

  @default_req_opts [
    connect_options: [timeout: 3_000],
    receive_timeout: 5_000,
    retry: false
  ]

  @type mode :: :dry_run | :execute

  @type item_result :: %{
          id: term(),
          provider_subscription_id: String.t(),
          status: :drifted | :reconciled | :unchanged | :skipped | :failed,
          changed_fields: [atom()],
          diff: %{optional(atom()) => %{local: term(), remote: term()}},
          error: String.t() | nil
        }

  @type batch_report :: %{
          mode: mode(),
          total: non_neg_integer(),
          drifted: non_neg_integer(),
          reconciled: non_neg_integer(),
          unchanged: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          results: [item_result()]
        }

  @doc """
  Runs a single-subscription or filtered bulk reconciliation pass.

  Defaults to `mode: :dry_run` (read-only). Writing to PostgreSQL requires both
  `mode: :execute` and `confirm?: true`.

  ## Required Options

    * `:subscription_resource` - The Ash subscription resource module.
    * `:domain` - The Ash domain module.

  ## Selection Options (at least one required)

    * `:subscription_id` - Remote `provider_subscription_id` (e.g. `"sub_123"`).
    * `:id` - Local subscription primary key.
    * `:older_than_hours` - Positive number; selects records where `last_reconciled_at` is `nil` or older than `N` hours.
    * `:stale_before` - `%DateTime{}` cutoff for `last_reconciled_at`.
    * `:statuses` - List of status atoms/strings to filter (e.g. `[:active, :past_due]`).
    * `:missing_quantity?` - When `true`, selects subscriptions where `quantity` is `nil`.
    * `:all?` - Explicit opt-in to scan all matching subscriptions without a narrower filter.

  ## Safety, Isolation & Throughput Options

    * `:mode` - `:dry_run` (default) or `:execute`.
    * `:confirm?` - Must be `true` when `mode: :execute`. Defaults to `false`.
    * `:authorize?` - Defaults to `true` so unauthorized actors cannot inspect or repair subscriptions. Pass `authorize?: false` only for trusted system jobs.
    * `:actor` - Ash actor used for policy checks on reads and reconciliation writes.
    * `:tenant` - Optional tenant identifier for multitenant deployments.
    * `:stripe_account` - Optional Stripe Connect account ID forwarded to provider calls.
    * `:provider` - Optional provider module override.
    * `:customer_resource` - Optional customer resource module override.
    * `:reset_event_cursor?` - Forwarded to `AshBilling.reconcile_subscription/2` in `:execute` mode.
    * `:page_size` - Pagination batch size (`1..500`, default `50`).
    * `:limit` - Optional maximum number of subscriptions to process.
    * `:concurrency` - Max concurrent workers (`1..10`, default `2`).
    * `:rate_limit_ms` - Non-negative delay in milliseconds applied before each provider call (default `0`).
    * `:req_opts` - Outbound HTTP `Req` options (defaults to bounded timeouts with `retry: false`).
  """
  @spec run(keyword()) :: {:ok, batch_report()} | {:error, term()}
  def run(opts) when is_list(opts) do
    start_time = System.monotonic_time()

    with {:ok, config} <- validate_opts(opts),
         {:ok, records} <- fetch_target_records(config) do
      results = process_records(records, config)
      report = build_report(config.mode, results)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ash_billing, :reconciler, :batch],
        %{
          duration: duration,
          total: report.total,
          drifted: report.drifted,
          reconciled: report.reconciled,
          unchanged: report.unchanged,
          skipped: report.skipped,
          failed: report.failed
        },
        %{mode: report.mode}
      )

      {:ok, report}
    end
  end

  @doc """
  Formats a reconciliation batch report as human-readable text.
  """
  @spec format_text(batch_report()) :: String.t()
  def format_text(report) do
    header =
      "AshBilling Reconcile — mode=#{report.mode} " <>
        "(total=#{report.total}, drifted=#{report.drifted}, reconciled=#{report.reconciled}, " <>
        "unchanged=#{report.unchanged}, skipped=#{report.skipped}, failed=#{report.failed})"

    lines =
      Enum.map_join(report.results, "\n", fn item ->
        tag = item.status |> Atom.to_string() |> String.upcase()

        fields =
          if item.changed_fields == [], do: "", else: " fields=#{inspect(item.changed_fields)}"

        err = if item.error, do: " error=#{item.error}", else: ""
        "  [#{tag}] #{item.provider_subscription_id}#{fields}#{err}"
      end)

    if lines == "", do: header, else: header <> "\n" <> lines
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_opts(opts) do
    sub_res = Keyword.get(opts, :subscription_resource)
    domain = Keyword.get(opts, :domain)
    mode = Keyword.get(opts, :mode, :dry_run)
    confirm? = Keyword.get(opts, :confirm?, false)
    page_size = Keyword.get(opts, :page_size, 50)
    limit = Keyword.get(opts, :limit)
    concurrency = Keyword.get(opts, :concurrency, 2)
    rate_limit_ms = Keyword.get(opts, :rate_limit_ms, 0)

    cond do
      not (is_atom(sub_res) and not is_nil(sub_res) and Code.ensure_loaded?(sub_res) and
               Spark.Dsl.is?(sub_res, Ash.Resource)) ->
        {:error, :invalid_subscription_resource}

      is_nil(domain) ->
        {:error, :missing_domain}

      mode not in [:dry_run, :execute] ->
        {:error, {:invalid_mode, mode}}

      mode == :execute and confirm? != true ->
        {:error, :confirmation_required}

      not has_selection_filter?(opts) ->
        {:error, :selection_filter_required}

      not is_integer(page_size) or page_size < 1 or page_size > 500 ->
        {:error, :invalid_page_size}

      not is_nil(limit) and (not is_integer(limit) or limit < 1) ->
        {:error, :invalid_limit}

      not is_integer(concurrency) or concurrency < 1 or concurrency > 10 ->
        {:error, :invalid_concurrency}

      not is_integer(rate_limit_ms) or rate_limit_ms < 0 ->
        {:error, :invalid_rate_limit}

      true ->
        req_opts =
          Keyword.merge(
            @default_req_opts,
            Keyword.get(opts, :req_opts) || Keyword.get(opts, :req_options) || []
          )

        {:ok,
         %{
           subscription_resource: sub_res,
           customer_resource: Keyword.get(opts, :customer_resource),
           domain: domain,
           mode: mode,
           authorize?: Keyword.get(opts, :authorize?, true),
           actor: Keyword.get(opts, :actor),
           has_actor?: Keyword.has_key?(opts, :actor),
           tenant: Keyword.get(opts, :tenant),
           has_tenant?: Keyword.has_key?(opts, :tenant),
           stripe_account: Keyword.get(opts, :stripe_account),
           provider: Keyword.get(opts, :provider),
           reset_event_cursor?: Keyword.get(opts, :reset_event_cursor?, false),
           subscription_id: Keyword.get(opts, :subscription_id),
           id: Keyword.get(opts, :id),
           older_than_hours: Keyword.get(opts, :older_than_hours),
           stale_before: Keyword.get(opts, :stale_before),
           statuses: normalize_statuses(Keyword.get(opts, :statuses)),
           missing_quantity?: Keyword.get(opts, :missing_quantity?, false),
           all?: Keyword.get(opts, :all?, false),
           page_size: page_size,
           limit: limit,
           concurrency: concurrency,
           rate_limit_ms: rate_limit_ms,
           req_opts: req_opts,
           extra_provider_opts:
             Keyword.drop(opts, [
               :subscription_resource,
               :customer_resource,
               :domain,
               :mode,
               :confirm?,
               :authorize?,
               :actor,
               :tenant,
               :stripe_account,
               :provider,
               :reset_event_cursor?,
               :subscription_id,
               :id,
               :older_than_hours,
               :stale_before,
               :statuses,
               :missing_quantity?,
               :all?,
               :page_size,
               :limit,
               :concurrency,
               :rate_limit_ms,
               :req_opts,
               :req_options
             ])
         }}
    end
  end

  defp has_selection_filter?(opts) do
    is_binary(Keyword.get(opts, :subscription_id)) or
      not is_nil(Keyword.get(opts, :id)) or
      not is_nil(Keyword.get(opts, :older_than_hours)) or
      match?(%DateTime{}, Keyword.get(opts, :stale_before)) or
      is_list(Keyword.get(opts, :statuses)) or
      Keyword.get(opts, :missing_quantity?, false) == true or
      Keyword.get(opts, :all?, false) == true
  end

  defp normalize_statuses(nil), do: nil

  defp normalize_statuses(list) when is_list(list) do
    Enum.map(list, fn
      s when is_atom(s) -> s
      s when is_binary(s) -> String.to_existing_atom(String.trim(s))
    end)
  rescue
    ArgumentError -> []
  end

  # ---------------------------------------------------------------------------
  # Querying & Pagination
  # ---------------------------------------------------------------------------

  defp fetch_target_records(config) do
    ash_opts = build_ash_opts(config)

    cond do
      is_binary(config.subscription_id) ->
        query =
          config.subscription_resource
          |> Ash.Query.new()
          |> Ash.Query.filter(provider_subscription_id == ^config.subscription_id)

        case Ash.read_one(query, ash_opts) do
          {:ok, nil} -> {:ok, []}
          {:ok, record} -> {:ok, [record]}
          {:error, reason} -> {:error, reason}
        end

      not is_nil(config.id) ->
        query =
          config.subscription_resource
          |> Ash.Query.new()
          |> Ash.Query.filter(id == ^config.id)

        case Ash.read_one(query, ash_opts) do
          {:ok, nil} -> {:ok, []}
          {:ok, record} -> {:ok, [record]}
          {:error, reason} -> {:error, reason}
        end

      true ->
        base_query = build_bulk_query(config)
        paginate_query(base_query, ash_opts, config.page_size, config.limit, 0, [])
    end
  end

  defp build_bulk_query(config) do
    query =
      config.subscription_resource
      |> Ash.Query.new()
      |> Ash.Query.sort(id: :asc)

    query =
      case resolve_cutoff(config) do
        %DateTime{} = cutoff ->
          if Ash.Resource.Info.attribute(config.subscription_resource, :last_reconciled_at) != nil do
            Ash.Query.filter(
              query,
              is_nil(last_reconciled_at) or last_reconciled_at < ^cutoff
            )
          else
            query
          end

        nil ->
          query
      end

    query =
      case config.statuses do
        [_ | _] = statuses ->
          Ash.Query.filter(query, status in ^statuses)

        _ ->
          query
      end

    if config.missing_quantity? and
         Ash.Resource.Info.attribute(config.subscription_resource, :quantity) != nil do
      Ash.Query.filter(query, is_nil(quantity))
    else
      query
    end
  end

  defp resolve_cutoff(%{stale_before: %DateTime{} = dt}), do: dt

  defp resolve_cutoff(%{older_than_hours: hours}) when is_number(hours) and hours > 0 do
    DateTime.add(DateTime.utc_now(), -round(hours * 3600), :second)
  end

  defp resolve_cutoff(_), do: nil

  defp paginate_query(_query, _ash_opts, _page_size, limit, _offset, acc)
       when is_integer(limit) and length(acc) >= limit do
    {:ok, Enum.take(Enum.reverse(acc), limit)}
  end

  defp paginate_query(query, ash_opts, page_size, limit, offset, acc) do
    remaining = if is_integer(limit), do: min(page_size, limit - length(acc)), else: page_size

    page_query =
      query
      |> Ash.Query.limit(remaining)
      |> Ash.Query.offset(offset)

    case Ash.read(page_query, ash_opts) do
      {:ok, []} ->
        {:ok, Enum.reverse(acc)}

      {:ok, page} ->
        new_acc = Enum.reverse(page) ++ acc

        if length(page) < remaining do
          {:ok, Enum.reverse(new_acc)}
        else
          paginate_query(query, ash_opts, page_size, limit, offset + length(page), new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Execution (Bounded Concurrency & Rate Limiting)
  # ---------------------------------------------------------------------------

  defp process_records([], _config), do: []

  defp process_records(records, config) do
    records
    |> Task.async_stream(
      fn record ->
        if config.rate_limit_ms > 0 do
          Process.sleep(config.rate_limit_ms)
        end

        process_one(record, config)
      end,
      max_concurrency: config.concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        %{
          id: nil,
          provider_subscription_id: "unknown",
          status: :failed,
          changed_fields: [],
          diff: %{},
          error: sanitize_error(reason)
        }
    end)
  end

  defp process_one(record, %{mode: :dry_run} = config) do
    provider_opts = build_provider_opts(config)

    case AshBilling.get_subscription(record, provider_opts) do
      {:ok, live_sub} when is_map(live_sub) ->
        case WebhookSync.extract_live_snapshot(live_sub) do
          {:ok, snapshot} ->
            diff = WebhookSync.diff_financial_fields(record, snapshot)
            changed_fields = Map.keys(diff) |> Enum.sort()

            %{
              id: record.id,
              provider_subscription_id: record.provider_subscription_id,
              status: if(changed_fields == [], do: :unchanged, else: :drifted),
              changed_fields: changed_fields,
              diff: serialize_diff(diff),
              error: nil
            }

          {:error, reason} ->
            %{
              id: record.id,
              provider_subscription_id: record.provider_subscription_id,
              status: :failed,
              changed_fields: [],
              diff: %{},
              error: sanitize_error(reason)
            }
        end

      {:error, reason} ->
        %{
          id: record.id,
          provider_subscription_id: record.provider_subscription_id,
          status: :failed,
          changed_fields: [],
          diff: %{},
          error: sanitize_error(reason)
        }
    end
  end

  defp process_one(record, %{mode: :execute} = config) do
    provider_opts = build_provider_opts(config)
    reconcile_opts = build_reconcile_opts(config, provider_opts)

    case AshBilling.reconcile_subscription(record, reconcile_opts) do
      {:ok, updated} when is_struct(updated) ->
        diff = WebhookSync.diff_financial_fields(record, updated)
        changed_fields = Map.keys(diff) |> Enum.sort()

        %{
          id: record.id,
          provider_subscription_id: record.provider_subscription_id,
          status: if(changed_fields == [], do: :unchanged, else: :reconciled),
          changed_fields: changed_fields,
          diff: serialize_diff(diff),
          error: nil
        }

      {:ok, _other} ->
        %{
          id: record.id,
          provider_subscription_id: record.provider_subscription_id,
          status: :skipped,
          changed_fields: [],
          diff: %{},
          error: nil
        }

      {:error, reason} ->
        %{
          id: record.id,
          provider_subscription_id: record.provider_subscription_id,
          status: :failed,
          changed_fields: [],
          diff: %{},
          error: sanitize_error(reason)
        }
    end
  end

  defp build_ash_opts(config) do
    [domain: config.domain, authorize?: config.authorize?]
    |> maybe_put(:actor, config.actor, config.has_actor?)
    |> maybe_put(:tenant, config.tenant, config.has_tenant?)
  end

  defp build_provider_opts(config) do
    config.extra_provider_opts
    |> Keyword.put(:req_opts, config.req_opts)
    |> maybe_put(:provider, config.provider, not is_nil(config.provider))
    |> maybe_put(:stripe_account, config.stripe_account, is_binary(config.stripe_account))
  end

  defp build_reconcile_opts(config, provider_opts) do
    provider_opts
    |> Keyword.put(:domain, config.domain)
    |> Keyword.put(:subscription_resource, config.subscription_resource)
    |> Keyword.put(:authorize?, config.authorize?)
    |> Keyword.put(:reset_event_cursor?, config.reset_event_cursor?)
    |> maybe_put(
      :customer_resource,
      config.customer_resource,
      not is_nil(config.customer_resource)
    )
    |> maybe_put(:actor, config.actor, config.has_actor?)
    |> maybe_put(:tenant, config.tenant, config.has_tenant?)
  end

  defp maybe_put(opts, key, value, true), do: Keyword.put(opts, key, value)
  defp maybe_put(opts, _key, _value, false), do: opts

  defp serialize_diff(diff) do
    Map.new(diff, fn {field, %{local: local, remote: remote}} ->
      {field, %{local: serialize_val(local), remote: serialize_val(remote)}}
    end)
  end

  defp serialize_val(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_val(val), do: val

  defp build_report(mode, results) do
    counts =
      Enum.reduce(
        results,
        %{drifted: 0, reconciled: 0, unchanged: 0, skipped: 0, failed: 0},
        fn item, acc -> Map.update!(acc, item.status, &(&1 + 1)) end
      )

    Map.merge(
      %{
        mode: mode,
        total: length(results),
        results: results
      },
      counts
    )
  end

  defp sanitize_error(%{__struct__: mod} = err) do
    "#{inspect(mod)}: #{Exception.message(err)}" |> redact_secrets()
  end

  defp sanitize_error(other), do: other |> inspect() |> redact_secrets()

  defp redact_secrets(str) when is_binary(str) do
    Regex.replace(~r/(?:sk|rk)_(?:test|live)_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+/, str, "[REDACTED]")
  end
end
