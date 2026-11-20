defmodule AshBilling.Reconciler do
  @moduledoc """
  Safe, auditable single-subscription and bulk reconciliation runner supporting
  read-only dry-run drift inspection, explicit write confirmation, stable keyset
  batch pagination, bounded concurrency, global cross-worker rate limiting, and
  strict actor/tenant/Stripe Connect isolation.

  Used programmatically or via `mix ash_billing.reconcile`.
  """

  require Ash.Query

  alias AshBilling.WebhookSync

  @default_req_opts [
    connect_options: [timeout: 3_000],
    receive_timeout: 5_000,
    retry: false
  ]

  @default_allowed_statuses [
    :active,
    :trialing,
    :past_due,
    :canceled,
    :unpaid,
    :incomplete,
    :incomplete_expired,
    :paused
  ]

  @connect_account_attribute_candidates [:stripe_account_id, :stripe_account]

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
          pages_processed: non_neg_integer(),
          results: [item_result()]
        }

  @doc """
  Runs a single-subscription or filtered bulk reconciliation pass.

  Defaults to `mode: :dry_run` (read-only). Writing to PostgreSQL requires both
  `mode: :execute` and `confirm?: true`.

  All selectors and isolation options are strictly validated before any database
  query or outbound provider HTTP request is executed. Invalid filters never fall
  back to an unfiltered scan; only an explicit `all?: true` authorizes an
  unfiltered sweep (still strictly scoped by tenant and Stripe Connect isolation).

  ## Required Options

    * `:subscription_resource` - The Ash subscription resource module.
    * `:domain` - The Ash domain module.

  ## Selection Options (at least one required)

    * `:subscription_id` - Remote `provider_subscription_id` (e.g. `"sub_123"`).
    * `:id` - Local subscription primary key.
    * `:older_than_hours` - Strictly positive number (`> 0`); selects records where `last_reconciled_at` is `nil` or older than `N` hours.
    * `:stale_before` - `%DateTime{}` cutoff for `last_reconciled_at`.
    * `:statuses` - Non-empty list of valid status atoms/strings to filter (e.g. `[:active, :past_due]`).
    * `:missing_quantity?` - When `true`, selects subscriptions where `quantity` is `nil` (fails if the resource lacks `:quantity`).
    * `:all?` - Explicit opt-in to scan all matching subscriptions without a narrower filter.

  ## Safety, Isolation & Throughput Options

    * `:mode` - `:dry_run` (default) or `:execute`.
    * `:confirm?` - Must be `true` when `mode: :execute`. Defaults to `false`.
    * `:authorize?` - Defaults to `true` so unauthorized actors cannot inspect or repair subscriptions. Pass `authorize?: false` only for trusted system jobs.
    * `:actor` - Ash actor used for policy checks on reads and reconciliation writes.
    * `:tenant` - Required for multitenant resources; rejected on non-multitenant resources.
    * `:stripe_account` - Optional Stripe Connect account ID forwarded to provider calls and enforced at the database layer.
    * `:stripe_account_attribute` - Optional attribute name (atom or string) on the subscription resource storing the Stripe Connect account ID. Auto-detected if `:stripe_account_id` or `:stripe_account` exists on the resource.
    * `:stripe_account_scope` - Pass `:tenant` (`"tenant"`) to explicitly opt into bulk Connect reconciliation on a multitenant resource without a dedicated Connect account column (when tenants map 1:1 to Connect accounts).
    * `:provider` - Optional provider module override.
    * `:customer_resource` - Optional customer resource module override.
    * `:reset_event_cursor?` - Forwarded to `AshBilling.reconcile_subscription/2` in `:execute` mode.
    * `:page_size` - Keyset pagination batch size (`1..500`, default `50`). Records are fetched and processed one page at a time.
    * `:limit` - Optional maximum number of subscriptions to process.
    * `:concurrency` - Max concurrent workers per batch (`1..10`, default `2`).
    * `:rate_limit_ms` - Global minimum interval in milliseconds enforced across **all** concurrent workers before issuing provider requests (default `0`).
    * `:req_opts` - Outbound HTTP `Req` options (defaults to bounded timeouts with `retry: false`).
  """
  @spec run(keyword()) :: {:ok, batch_report()} | {:error, term()}
  def run(opts) when is_list(opts) do
    start_time = System.monotonic_time()

    with {:ok, config} <- validate_opts(opts),
         base_query = build_base_query(config),
         rate_limiter = new_rate_limiter(config.rate_limit_ms),
         {:ok, acc} <- stream_and_process_batches(base_query, config, rate_limiter) do
      report = build_report(config.mode, acc)
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
          failed: report.failed,
          pages: report.pages_processed
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
  # Fail-Closed Validation
  # ---------------------------------------------------------------------------

  defp validate_opts(opts) do
    with {:ok, sub_res} <-
           validate_subscription_resource(Keyword.get(opts, :subscription_resource)),
         {:ok, domain} <- validate_domain(Keyword.get(opts, :domain)),
         {:ok, customer_res} <- validate_customer_resource(Keyword.get(opts, :customer_resource)),
         {:ok, primary_key} <- resolve_primary_key(sub_res),
         {:ok, mode} <- validate_mode(Keyword.get(opts, :mode, :dry_run)),
         {:ok, subscription_id} <-
           validate_subscription_id(Keyword.get(opts, :subscription_id), sub_res),
         {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, older_than_hours} <-
           validate_older_than_hours(Keyword.get(opts, :older_than_hours), sub_res),
         {:ok, stale_before} <- validate_stale_before(Keyword.get(opts, :stale_before), sub_res),
         :ok <- validate_time_filter_combination(older_than_hours, stale_before),
         {:ok, statuses} <- validate_statuses(Keyword.get(opts, :statuses), sub_res),
         {:ok, missing_quantity?} <-
           validate_missing_quantity(Keyword.get(opts, :missing_quantity?, false), sub_res),
         {:ok, all?} <- validate_boolean(Keyword.get(opts, :all?, false), :invalid_all_option),
         :ok <-
           validate_selection_present(
             subscription_id,
             id,
             older_than_hours,
             stale_before,
             statuses,
             missing_quantity?,
             all?
           ),
         {:ok, tenant, has_tenant?} <- validate_tenant(opts, sub_res, customer_res),
         {:ok, stripe_account} <- validate_stripe_account(Keyword.get(opts, :stripe_account)),
         {:ok, stripe_account_scope} <-
           validate_stripe_account_scope(Keyword.get(opts, :stripe_account_scope)),
         {:ok, stripe_account_attr} <-
           resolve_stripe_account_attribute(Keyword.get(opts, :stripe_account_attribute), sub_res),
         :ok <-
           validate_stripe_account_isolation(
             stripe_account,
             stripe_account_attr,
             stripe_account_scope,
             sub_res,
             tenant,
             not is_nil(subscription_id) or not is_nil(id)
           ),
         :ok <- validate_confirmation(mode, Keyword.get(opts, :confirm?, false)),
         {:ok, page_size} <- validate_page_size(Keyword.get(opts, :page_size, 50)),
         {:ok, limit} <- validate_limit(Keyword.get(opts, :limit)),
         {:ok, concurrency} <- validate_concurrency(Keyword.get(opts, :concurrency, 2)),
         {:ok, rate_limit_ms} <- validate_rate_limit(Keyword.get(opts, :rate_limit_ms, 0)) do
      req_opts =
        Keyword.merge(
          @default_req_opts,
          Keyword.get(opts, :req_opts) || Keyword.get(opts, :req_options) || []
        )

      {:ok,
       %{
         subscription_resource: sub_res,
         customer_resource: customer_res,
         domain: domain,
         primary_key: primary_key,
         mode: mode,
         authorize?: Keyword.get(opts, :authorize?, true),
         actor: Keyword.get(opts, :actor),
         has_actor?: Keyword.has_key?(opts, :actor),
         tenant: tenant,
         has_tenant?: has_tenant?,
         stripe_account: stripe_account,
         stripe_account_attribute: stripe_account_attr,
         stripe_account_scope: stripe_account_scope,
         provider: Keyword.get(opts, :provider),
         reset_event_cursor?: Keyword.get(opts, :reset_event_cursor?, false),
         subscription_id: subscription_id,
         id: id,
         cutoff: compute_cutoff(older_than_hours, stale_before),
         statuses: statuses,
         missing_quantity?: missing_quantity?,
         all?: all?,
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
             :stripe_account_attribute,
             :stripe_account_scope,
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

  defp validate_subscription_resource(sub_res) do
    if is_atom(sub_res) and not is_nil(sub_res) and Code.ensure_loaded?(sub_res) and
         Spark.Dsl.is?(sub_res, Ash.Resource) do
      {:ok, sub_res}
    else
      {:error, :invalid_subscription_resource}
    end
  end

  defp validate_domain(nil), do: {:error, :missing_domain}
  defp validate_domain(domain) when is_atom(domain), do: {:ok, domain}
  defp validate_domain(_), do: {:error, :missing_domain}

  defp validate_customer_resource(nil), do: {:ok, nil}

  defp validate_customer_resource(res) do
    if is_atom(res) and Code.ensure_loaded?(res) and Spark.Dsl.is?(res, Ash.Resource) do
      {:ok, res}
    else
      {:error, :invalid_customer_resource}
    end
  end

  defp resolve_primary_key(sub_res) do
    case Ash.Resource.Info.primary_key(sub_res) do
      [pk] -> {:ok, pk}
      _ -> {:error, :unsupported_primary_key}
    end
  end

  defp validate_mode(mode) when mode in [:dry_run, :execute], do: {:ok, mode}
  defp validate_mode(other), do: {:error, {:invalid_mode, other}}

  defp validate_confirmation(:dry_run, confirm?) when is_boolean(confirm?), do: :ok
  defp validate_confirmation(:execute, true), do: :ok
  defp validate_confirmation(:execute, false), do: {:error, :confirmation_required}
  defp validate_confirmation(_mode, _non_bool), do: {:error, :invalid_confirm_option}

  defp validate_subscription_id(nil, _sub_res), do: {:ok, nil}

  defp validate_subscription_id(val, sub_res) when is_binary(val) do
    trimmed = String.trim(val)

    cond do
      trimmed == "" ->
        {:error, :invalid_subscription_id}

      is_nil(Ash.Resource.Info.attribute(sub_res, :provider_subscription_id)) ->
        {:error, :missing_provider_subscription_id_attribute}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_subscription_id(_, _sub_res), do: {:error, :invalid_subscription_id}

  defp validate_id(nil), do: {:ok, nil}

  defp validate_id(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: {:error, :invalid_id}, else: {:ok, trimmed}
  end

  defp validate_id(val), do: {:ok, val}

  defp validate_older_than_hours(nil, _sub_res), do: {:ok, nil}

  defp validate_older_than_hours(hours, sub_res) when is_number(hours) and hours > 0 do
    if Ash.Resource.Info.attribute(sub_res, :last_reconciled_at) != nil do
      {:ok, hours}
    else
      {:error, :missing_last_reconciled_at_attribute}
    end
  end

  defp validate_older_than_hours(_, _sub_res), do: {:error, :invalid_older_than_hours}

  defp validate_stale_before(nil, _sub_res), do: {:ok, nil}

  defp validate_stale_before(%DateTime{} = dt, sub_res) do
    if Ash.Resource.Info.attribute(sub_res, :last_reconciled_at) != nil do
      {:ok, dt}
    else
      {:error, :missing_last_reconciled_at_attribute}
    end
  end

  defp validate_stale_before(_, _sub_res), do: {:error, :invalid_stale_before}

  defp validate_time_filter_combination(hours, dt) when not is_nil(hours) and not is_nil(dt) do
    {:error, :conflicting_time_filters}
  end

  defp validate_time_filter_combination(_, _), do: :ok

  defp validate_statuses(nil, _sub_res), do: {:ok, nil}
  defp validate_statuses([], _sub_res), do: {:error, :invalid_statuses}

  defp validate_statuses(list, sub_res) when is_list(list) do
    case Ash.Resource.Info.attribute(sub_res, :status) do
      nil ->
        {:error, :missing_status_attribute}

      attr ->
        allowed = allowed_statuses_for(attr)
        allowed_by_name = Map.new(allowed, &{Atom.to_string(&1), &1})

        {valid_rev, invalid_rev} =
          Enum.reduce(list, {[], []}, fn item, {valids, invalids} ->
            case normalize_single_status(item, allowed, allowed_by_name) do
              {:ok, atom} -> {[atom | valids], invalids}
              :error -> {valids, [item | invalids]}
            end
          end)

        if invalid_rev == [] do
          {:ok, valid_rev |> Enum.reverse() |> Enum.uniq()}
        else
          {:error, {:invalid_statuses, Enum.reverse(invalid_rev)}}
        end
    end
  end

  defp validate_statuses(_, _sub_res), do: {:error, :invalid_statuses}

  defp allowed_statuses_for(attr) do
    case Keyword.get(attr.constraints || [], :one_of) do
      [_ | _] = list -> list
      _ -> @default_allowed_statuses
    end
  end

  defp normalize_single_status(item, allowed, _allowed_by_name) when is_atom(item) do
    if item in allowed, do: {:ok, item}, else: :error
  end

  defp normalize_single_status(item, _allowed, allowed_by_name) when is_binary(item) do
    case Map.fetch(allowed_by_name, String.trim(item)) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  defp normalize_single_status(_, _allowed, _allowed_by_name), do: :error

  defp validate_missing_quantity(false, _sub_res), do: {:ok, false}

  defp validate_missing_quantity(true, sub_res) do
    if Ash.Resource.Info.attribute(sub_res, :quantity) != nil do
      {:ok, true}
    else
      {:error, :missing_quantity_attribute}
    end
  end

  defp validate_missing_quantity(_, _sub_res), do: {:error, :invalid_missing_quantity}

  defp validate_boolean(val, _err) when is_boolean(val), do: {:ok, val}
  defp validate_boolean(_, err), do: {:error, err}

  defp validate_selection_present(
         subscription_id,
         id,
         older_than_hours,
         stale_before,
         statuses,
         missing_quantity?,
         all?
       ) do
    if not is_nil(subscription_id) or
         not is_nil(id) or
         not is_nil(older_than_hours) or
         not is_nil(stale_before) or
         not is_nil(statuses) or
         missing_quantity? == true or
         all? == true do
      :ok
    else
      {:error, :selection_filter_required}
    end
  end

  defp validate_tenant(opts, sub_res, customer_res) do
    has_tenant? = Keyword.has_key?(opts, :tenant)
    tenant = Keyword.get(opts, :tenant)
    sub_mt = Ash.Resource.Info.multitenancy_strategy(sub_res)

    cond do
      is_binary(tenant) and String.trim(tenant) == "" ->
        {:error, :invalid_tenant}

      not is_nil(sub_mt) and is_nil(tenant) ->
        {:error, :tenant_required}

      is_nil(sub_mt) and not is_nil(tenant) ->
        {:error, :multitenancy_not_configured}

      not is_nil(customer_res) and Ash.Resource.Info.multitenancy_strategy(customer_res) != sub_mt ->
        {:error, :multitenancy_mismatch}

      true ->
        {:ok, tenant, has_tenant? and not is_nil(tenant)}
    end
  end

  defp validate_stripe_account(nil), do: {:ok, nil}

  defp validate_stripe_account(account) when is_binary(account) do
    trimmed = String.trim(account)
    if trimmed == "", do: {:error, :invalid_stripe_account}, else: {:ok, trimmed}
  end

  defp validate_stripe_account(_), do: {:error, :invalid_stripe_account}

  defp validate_stripe_account_scope(nil), do: {:ok, nil}
  defp validate_stripe_account_scope(:tenant), do: {:ok, :tenant}
  defp validate_stripe_account_scope("tenant"), do: {:ok, :tenant}
  defp validate_stripe_account_scope(_), do: {:error, :invalid_stripe_account_scope}

  defp resolve_stripe_account_attribute(nil, sub_res) do
    detected =
      Enum.find(@connect_account_attribute_candidates, fn attr ->
        Ash.Resource.Info.attribute(sub_res, attr) != nil
      end)

    {:ok, detected}
  end

  defp resolve_stripe_account_attribute(attr, sub_res) when is_atom(attr) do
    if Ash.Resource.Info.attribute(sub_res, attr) != nil do
      {:ok, attr}
    else
      {:error, :missing_stripe_account_attribute}
    end
  end

  defp resolve_stripe_account_attribute(attr, sub_res) when is_binary(attr) do
    trimmed = String.trim(attr)

    match =
      Enum.find(Ash.Resource.Info.attributes(sub_res), fn attribute ->
        Atom.to_string(attribute.name) == trimmed
      end)

    case match do
      nil -> {:error, :missing_stripe_account_attribute}
      attribute -> {:ok, attribute.name}
    end
  end

  defp resolve_stripe_account_attribute(_, _sub_res),
    do: {:error, :missing_stripe_account_attribute}

  defp validate_stripe_account_isolation(
         stripe_account,
         stripe_account_attr,
         stripe_account_scope,
         sub_res,
         tenant,
         single_target?
       ) do
    multitenant? = Ash.Resource.Info.multitenancy_strategy(sub_res) != nil

    cond do
      stripe_account_scope == :tenant and not (multitenant? and not is_nil(tenant)) ->
        {:error, :stripe_account_isolation_required}

      not is_nil(stripe_account) and is_nil(stripe_account_attr) and not single_target? and
          stripe_account_scope != :tenant ->
        {:error, :stripe_account_isolation_required}

      true ->
        :ok
    end
  end

  defp validate_page_size(page_size)
       when is_integer(page_size) and page_size >= 1 and page_size <= 500,
       do: {:ok, page_size}

  defp validate_page_size(_), do: {:error, :invalid_page_size}

  defp validate_limit(nil), do: {:ok, nil}
  defp validate_limit(limit) when is_integer(limit) and limit >= 1, do: {:ok, limit}
  defp validate_limit(_), do: {:error, :invalid_limit}

  defp validate_concurrency(concurrency)
       when is_integer(concurrency) and concurrency >= 1 and concurrency <= 10,
       do: {:ok, concurrency}

  defp validate_concurrency(_), do: {:error, :invalid_concurrency}

  defp validate_rate_limit(ms) when is_integer(ms) and ms >= 0, do: {:ok, ms}
  defp validate_rate_limit(_), do: {:error, :invalid_rate_limit}

  defp compute_cutoff(nil, %DateTime{} = dt), do: dt

  defp compute_cutoff(hours, nil) when is_number(hours) and hours > 0 do
    DateTime.add(DateTime.utc_now(), -round(hours * 3600), :second)
  end

  defp compute_cutoff(nil, nil), do: nil

  # ---------------------------------------------------------------------------
  # Querying & Stable Keyset Streaming Batches
  # ---------------------------------------------------------------------------

  defp build_base_query(config) do
    query =
      config.subscription_resource
      |> Ash.Query.new()
      |> Ash.Query.sort([{config.primary_key, :asc}])

    query =
      if is_binary(config.subscription_id) do
        Ash.Query.filter(query, provider_subscription_id == ^config.subscription_id)
      else
        query
      end

    query =
      if not is_nil(config.id) do
        Ash.Query.filter(query, ^[{config.primary_key, config.id}])
      else
        query
      end

    query =
      case config.cutoff do
        %DateTime{} = cutoff ->
          Ash.Query.filter(query, is_nil(last_reconciled_at) or last_reconciled_at < ^cutoff)

        nil ->
          query
      end

    query =
      case config.statuses do
        [_ | _] = statuses ->
          Ash.Query.filter(query, status in ^statuses)

        nil ->
          query
      end

    query =
      if config.missing_quantity? do
        Ash.Query.filter(query, is_nil(quantity))
      else
        query
      end

    case {config.stripe_account_attribute, config.stripe_account} do
      {nil, _} ->
        query

      {attr, nil} ->
        Ash.Query.filter(query, ^[{attr, [is_nil: true]}])

      {attr, account} when is_binary(account) ->
        Ash.Query.filter(query, ^[{attr, account}])
    end
  end

  defp stream_and_process_batches(base_query, config, rate_limiter) do
    ash_opts = build_ash_opts(config)

    initial_acc = %{
      total: 0,
      drifted: 0,
      reconciled: 0,
      unchanged: 0,
      skipped: 0,
      failed: 0,
      pages_processed: 0,
      results_rev: []
    }

    do_stream_batches(base_query, ash_opts, config, rate_limiter, nil, initial_acc)
  end

  defp do_stream_batches(_base_query, _ash_opts, %{limit: limit}, _rate_limiter, _cursor, acc)
       when is_integer(limit) and acc.total >= limit do
    {:ok, acc}
  end

  defp do_stream_batches(base_query, ash_opts, config, rate_limiter, cursor, acc) do
    batch_limit =
      case config.limit do
        nil -> config.page_size
        limit -> min(config.page_size, limit - acc.total)
      end

    page_query =
      base_query
      |> maybe_apply_cursor(config.primary_key, cursor)
      |> Ash.Query.limit(batch_limit)

    case Ash.read(page_query, ash_opts) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, page} ->
        batch_results = process_batch(page, config, rate_limiter)
        next_acc = merge_batch_results(acc, batch_results)
        next_cursor = Map.fetch!(List.last(page), config.primary_key)

        if length(page) < batch_limit or
             (is_integer(config.limit) and next_acc.total >= config.limit) do
          {:ok, next_acc}
        else
          do_stream_batches(base_query, ash_opts, config, rate_limiter, next_cursor, next_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_cursor(query, _pk, nil), do: query

  defp maybe_apply_cursor(query, pk, cursor) do
    Ash.Query.filter(query, ^[{pk, [greater_than: cursor]}])
  end

  defp merge_batch_results(acc, batch_results) do
    Enum.reduce(
      batch_results,
      %{acc | pages_processed: acc.pages_processed + 1},
      fn item, state ->
        state
        |> Map.update!(:total, &(&1 + 1))
        |> Map.update!(item.status, &(&1 + 1))
        |> Map.update!(:results_rev, &[item | &1])
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Global Cross-Worker Rate Limiter (Lock-Free :atomics GCRA Pacer)
  # ---------------------------------------------------------------------------

  defp new_rate_limiter(0), do: nil

  defp new_rate_limiter(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    {:global_pacer, :atomics.new(1, signed: true), System.monotonic_time(:millisecond),
     interval_ms}
  end

  defp acquire_rate_limit(nil), do: :ok

  defp acquire_rate_limit({:global_pacer, ref, base_ms, interval_ms}) do
    wait_ms = reserve_rate_limit_slot(ref, base_ms, interval_ms, :atomics.get(ref, 1))
    if wait_ms > 0, do: Process.sleep(wait_ms)
    :ok
  end

  defp reserve_rate_limit_slot(ref, base_ms, interval_ms, current) do
    now = max(0, System.monotonic_time(:millisecond) - base_ms)

    scheduled =
      if current == 0 do
        now
      else
        max(now, current - 1)
      end

    next_stored = scheduled + interval_ms + 1

    case :atomics.compare_exchange(ref, 1, current, next_stored) do
      :ok -> scheduled - now
      observed -> reserve_rate_limit_slot(ref, base_ms, interval_ms, observed)
    end
  end

  # ---------------------------------------------------------------------------
  # Execution (Bounded Concurrency & Per-Item Handling)
  # ---------------------------------------------------------------------------

  defp process_batch(records, config, rate_limiter) do
    records
    |> Task.async_stream(
      fn record ->
        acquire_rate_limit(rate_limiter)
        process_one(record, config)
      end,
      max_concurrency: config.concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.zip(records)
    |> Enum.map(fn
      {{:ok, result}, _record} ->
        result

      {{:exit, reason}, record} ->
        %{
          id: Map.get(record, config.primary_key),
          provider_subscription_id: Map.get(record, :provider_subscription_id, "unknown"),
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
              id: Map.get(record, config.primary_key),
              provider_subscription_id: record.provider_subscription_id,
              status: if(changed_fields == [], do: :unchanged, else: :drifted),
              changed_fields: changed_fields,
              diff: serialize_diff(diff),
              error: nil
            }

          {:error, reason} ->
            %{
              id: Map.get(record, config.primary_key),
              provider_subscription_id: record.provider_subscription_id,
              status: :failed,
              changed_fields: [],
              diff: %{},
              error: sanitize_error(reason)
            }
        end

      {:error, reason} ->
        %{
          id: Map.get(record, config.primary_key),
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
          id: Map.get(record, config.primary_key),
          provider_subscription_id: record.provider_subscription_id,
          status: if(changed_fields == [], do: :unchanged, else: :reconciled),
          changed_fields: changed_fields,
          diff: serialize_diff(diff),
          error: nil
        }

      {:ok, _other} ->
        %{
          id: Map.get(record, config.primary_key),
          provider_subscription_id: record.provider_subscription_id,
          status: :skipped,
          changed_fields: [],
          diff: %{},
          error: nil
        }

      {:error, reason} ->
        %{
          id: Map.get(record, config.primary_key),
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

  defp build_report(mode, acc) do
    %{
      mode: mode,
      total: acc.total,
      drifted: acc.drifted,
      reconciled: acc.reconciled,
      unchanged: acc.unchanged,
      skipped: acc.skipped,
      failed: acc.failed,
      pages_processed: acc.pages_processed,
      results: Enum.reverse(acc.results_rev)
    }
  end

  defp sanitize_error(%{__struct__: mod} = err) do
    "#{inspect(mod)}: #{Exception.message(err)}" |> redact_secrets()
  end

  defp sanitize_error(other), do: other |> inspect() |> redact_secrets()

  defp redact_secrets(str) when is_binary(str) do
    Regex.replace(~r/(?:sk|rk)_(?:test|live)_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+/, str, "[REDACTED]")
  end
end
