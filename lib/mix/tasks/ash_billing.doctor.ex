defmodule Mix.Tasks.AshBilling.Doctor do
  @shortdoc "Runs read-only AshBilling configuration, PostgreSQL, and optional provider diagnostics"

  @moduledoc """
  Inspects an `AshBilling` deployment and reports `PASS`, `WARN`, and `FAIL` checks across
  structural Ash contracts, PostgreSQL migrations/indexes, and optional read-only provider
  connectivity.

  By default, this task is strictly **read-only** and never mutates PostgreSQL or Stripe.
  Secrets, API keys, and sensitive customer identifiers are never printed.

  ## Usage

      mix ash_billing.doctor \\
        --customer-resource MyApp.Accounts.User \\
        --subscription-resource MyApp.Billing.Subscription \\
        --deduplication-resource MyApp.Billing.WebhookEvent

  ## Options

    * `--customer-resource` - Ash customer resource module.
    * `--subscription-resource` - Ash subscription resource module.
    * `--deduplication-resource` (alias `--webhook-event-resource`) - Ash webhook event resource module.
    * `--expected-livemode` - Explicit boolean (`true` or `false`) for Stripe livemode checks.
    * `--stripe-account` - Optional Stripe Connect account ID.
    * `--format` - Output format: `text` (default) or `json`.
    * `--json` - Shorthand for `--format json`.
    * `--check-database` / `--no-check-database` - Enable/disable read-only PostgreSQL checks (defaults to `true` when PostgreSQL resources are provided).
    * `--check-provider` - Enable optional read-only provider connectivity probe (default `false`).
    * `--strict` - Exit non-zero on warnings as well as failures.
    * `--no-start` - Do not start the application before running diagnostics.
  """

  use Mix.Task

  alias AshBilling.Diagnostics

  @switches [
    customer_resource: :string,
    subscription_resource: :string,
    deduplication_resource: :string,
    webhook_event_resource: :string,
    expected_livemode: :string,
    stripe_account: :string,
    format: :string,
    json: :boolean,
    check_database: :boolean,
    check_provider: :boolean,
    strict: :boolean,
    start: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options for mix ash_billing.doctor: #{inspect(invalid)}")
    end

    if Keyword.get(parsed, :start, true) do
      Mix.Task.run("app.start")
    end

    {report, exit_status} = execute(parsed)
    format = resolve_format(parsed)

    output =
      case format do
        :json -> Jason.encode!(report, pretty: true)
        :text -> Diagnostics.format_text(report)
      end

    Mix.shell().info(output)

    if exit_status != :ok do
      Mix.raise("AshBilling doctor reported status=#{report.status}")
    end
  end

  @doc false
  def execute(parsed, extra_opts \\ []) do
    opts = build_diagnostic_opts(parsed, extra_opts)
    report = Diagnostics.run(opts)
    strict? = Keyword.get(parsed, :strict, false)

    exit_status =
      cond do
        report.status == :fail -> :error
        strict? and report.status == :warn -> :error
        true -> :ok
      end

    {report, exit_status}
  end

  @doc false
  def build_diagnostic_opts(parsed, extra_opts \\ []) do
    customer_res =
      parse_module(Keyword.get(parsed, :customer_resource)) ||
        Application.get_env(:ash_billing, :customer_resource)

    sub_res =
      parse_module(Keyword.get(parsed, :subscription_resource)) ||
        Application.get_env(:ash_billing, :subscription_resource)

    dedup_res =
      parse_module(
        Keyword.get(parsed, :deduplication_resource) ||
          Keyword.get(parsed, :webhook_event_resource)
      ) || Application.get_env(:ash_billing, :deduplication_resource)

    has_pg_resource? =
      Enum.any?([customer_res, sub_res, dedup_res], fn res ->
        is_atom(res) and not is_nil(res) and Code.ensure_loaded?(res) and
          Code.ensure_loaded?(AshPostgres.DataLayer) and
          Spark.Dsl.is?(res, Ash.Resource) and
          Ash.DataLayer.data_layer(res) == AshPostgres.DataLayer
      end)

    check_database? = Keyword.get(parsed, :check_database, has_pg_resource?)
    check_provider? = Keyword.get(parsed, :check_provider, false)

    base =
      [
        customer_resource: customer_res,
        subscription_resource: sub_res,
        deduplication_resource: dedup_res,
        check_database?: check_database?,
        check_provider?: check_provider?
      ]
      |> maybe_put_livemode(Keyword.get(parsed, :expected_livemode))
      |> maybe_put(:stripe_account, Keyword.get(parsed, :stripe_account))

    Keyword.merge(base, extra_opts)
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

  defp maybe_put_livemode(opts, nil), do: opts
  defp maybe_put_livemode(opts, "true"), do: Keyword.put(opts, :expected_livemode, true)
  defp maybe_put_livemode(opts, "false"), do: Keyword.put(opts, :expected_livemode, false)

  defp maybe_put_livemode(_opts, other) do
    Mix.raise("Invalid --expected-livemode #{inspect(other)}; expected true or false")
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
