defmodule Mix.Tasks.AshBilling.Reconcile do
  @shortdoc "Inspects drift (--dry-run) or safely reconciles subscriptions against the billing provider"

  @moduledoc """
  Inspects financial drift or reconciles one or more subscriptions against the authoritative
  billing provider using `AshBilling.Reconciler` and `AshBilling.reconcile_subscription/2`.

  **Read-only by default (`--dry-run`).** Writes to PostgreSQL require `--execute` together
  with explicit confirmation (`--confirm` or interactive prompt confirmation).

  ## Usage

      # Dry-run single subscription
      mix ash_billing.reconcile \\
        --domain MyApp.Billing \\
        --subscription-resource MyApp.Billing.Subscription \\
        --subscription-id sub_123 \\
        --system

      # Execute bulk reconciliation for subscriptions not reconciled in 24h
      mix ash_billing.reconcile \\
        --domain MyApp.Billing \\
        --subscription-resource MyApp.Billing.Subscription \\
        --older-than-hours 24 \\
        --concurrency 2 \\
        --rate-limit-ms 100 \\
        --system \\
        --execute \\
        --confirm

  ## Options

    * `--domain` - Ash domain module (required unless configured under `:ash_billing`).
    * `--subscription-resource` - Ash subscription resource module (required unless configured).
    * `--customer-resource` - Optional Ash customer resource module override.
    * `--subscription-id` - Reconcile a single subscription by `provider_subscription_id`.
    * `--id` - Reconcile a single subscription by local primary key.
    * `--older-than-hours` - Bulk filter: select records with `last_reconciled_at` `nil` or older than `N` hours.
    * `--status` - Comma-separated status filter (e.g. `active,past_due`).
    * `--missing-quantity` - Bulk filter: select subscriptions with `quantity IS NULL`.
    * `--all` - Explicit opt-in to scan all subscriptions without a narrower filter.
    * `--dry-run` - Inspect drift without writing to PostgreSQL (default).
    * `--execute` - Perform transactional reconciliation writes (requires `--confirm` or interactive confirmation).
    * `--confirm` - Explicit confirmation for `--execute` in non-interactive environments.
    * `--system` - Run with `authorize?: false` for trusted CLI system maintenance (without `--system`, Ash authorization remains enabled).
    * `--tenant` - Scope reads and writes to a specific tenant.
    * `--stripe-account` - Scope provider requests to a Stripe Connect account ID.
    * `--reset-event-cursor` - Pass `reset_event_cursor?: true` during `--execute`.
    * `--page-size` - Pagination batch size (`1..500`, default `50`).
    * `--limit` - Maximum subscriptions to process.
    * `--concurrency` - Max concurrent workers (`1..10`, default `2`).
    * `--rate-limit-ms` - Milliseconds to pause before each provider request (default `0`).
    * `--format` - `text` (default) or `json`.
    * `--json` - Shorthand for `--format json`.
    * `--no-start` - Do not start the application before running.
  """

  use Mix.Task

  alias AshBilling.Reconciler

  @switches [
    domain: :string,
    subscription_resource: :string,
    customer_resource: :string,
    subscription_id: :string,
    id: :string,
    older_than_hours: :float,
    status: :string,
    missing_quantity: :boolean,
    all: :boolean,
    dry_run: :boolean,
    execute: :boolean,
    confirm: :boolean,
    system: :boolean,
    tenant: :string,
    stripe_account: :string,
    reset_event_cursor: :boolean,
    page_size: :integer,
    limit: :integer,
    concurrency: :integer,
    rate_limit_ms: :integer,
    format: :string,
    json: :boolean,
    start: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options for mix ash_billing.reconcile: #{inspect(invalid)}")
    end

    if Keyword.get(parsed, :start, true) do
      Mix.Task.run("app.start")
    end

    case execute(parsed) do
      {:ok, report} ->
        output =
          case resolve_format(parsed) do
            :json -> Jason.encode!(report, pretty: true)
            :text -> Reconciler.format_text(report)
          end

        Mix.shell().info(output)

        if report.failed > 0 do
          Mix.raise("AshBilling reconcile completed with #{report.failed} failure(s)")
        end

      {:error, reason} ->
        Mix.raise("AshBilling reconcile failed: #{inspect(reason)}")
    end
  end

  @doc false
  def execute(parsed, extra_opts \\ []) do
    execute? = Keyword.get(parsed, :execute, false)
    dry_run? = Keyword.get(parsed, :dry_run, not execute?)

    if execute? and Keyword.get(parsed, :dry_run, false) do
      {:error, :conflicting_mode_flags}
    else
      mode = if execute? and not dry_run?, do: :execute, else: :dry_run

      confirm? =
        cond do
          mode == :dry_run ->
            false

          Keyword.get(parsed, :confirm, false) ->
            true

          Keyword.get(extra_opts, :confirm?, false) ->
            true

          Keyword.get(extra_opts, :interactive?, true) ->
            Mix.shell().yes?(
              "Execute live PostgreSQL reconciliation writes against the billing provider?"
            )

          true ->
            false
        end

      opts =
        build_reconciler_opts(parsed, mode, confirm?)
        |> Keyword.merge(Keyword.drop(extra_opts, [:interactive?]))

      Reconciler.run(opts)
    end
  end

  defp build_reconciler_opts(parsed, mode, confirm?) do
    domain =
      parse_module(Keyword.get(parsed, :domain)) ||
        Application.get_env(:ash_billing, :domain)

    sub_res =
      parse_module(Keyword.get(parsed, :subscription_resource)) ||
        Application.get_env(:ash_billing, :subscription_resource)

    cust_res =
      parse_module(Keyword.get(parsed, :customer_resource)) ||
        Application.get_env(:ash_billing, :customer_resource)

    statuses =
      case Keyword.get(parsed, :status) do
        nil -> nil
        str -> str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    [
      domain: domain,
      subscription_resource: sub_res,
      customer_resource: cust_res,
      mode: mode,
      confirm?: confirm?,
      authorize?: not Keyword.get(parsed, :system, false),
      missing_quantity?: Keyword.get(parsed, :missing_quantity, false),
      all?: Keyword.get(parsed, :all, false),
      reset_event_cursor?: Keyword.get(parsed, :reset_event_cursor, false),
      page_size: Keyword.get(parsed, :page_size, 50),
      concurrency: Keyword.get(parsed, :concurrency, 2),
      rate_limit_ms: Keyword.get(parsed, :rate_limit_ms, 0)
    ]
    |> maybe_put(:subscription_id, Keyword.get(parsed, :subscription_id))
    |> maybe_put(:id, Keyword.get(parsed, :id))
    |> maybe_put(:older_than_hours, Keyword.get(parsed, :older_than_hours))
    |> maybe_put(:statuses, statuses)
    |> maybe_put(:tenant, Keyword.get(parsed, :tenant))
    |> maybe_put(:stripe_account, Keyword.get(parsed, :stripe_account))
    |> maybe_put(:limit, Keyword.get(parsed, :limit))
  end

  defp resolve_format(parsed) do
    cond do
      Keyword.get(parsed, :json, false) ->
        :json

      Keyword.get(parsed, :format) == "json" ->
        :json

      Keyword.get(parsed, :format) in [nil, "text"] ->
        :text

      true ->
        Mix.raise(
          "Unsupported --format #{inspect(Keyword.get(parsed, :format))}; use text or json"
        )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp parse_module(nil), do: nil
  defp parse_module(mod) when is_atom(mod), do: mod

  defp parse_module(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      nil
    else
      mod = Module.concat([trimmed])

      if Code.ensure_loaded?(mod) do
        mod
      else
        Mix.raise("Module #{trimmed} could not be loaded")
      end
    end
  end
end
