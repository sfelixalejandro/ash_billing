defmodule SaasExampleWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor defining low-cardinality `AshBilling` and Phoenix metrics.
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("ash_billing.reconcile.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider, :status, :drift_detected]
      ),
      counter("ash_billing.reconcile.stop.count",
        tags: [:provider, :status, :drift_detected, :error_category]
      ),
      summary("ash_billing.reverify.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider, :status]
      ),
      counter("ash_billing.deduplication.acquire.count",
        tags: [:strategy, :outcome, :error_category]
      ),
      counter("ash_billing.postgres.contention.count",
        tags: [:operation, :reason]
      ),
      summary("ash_billing.webhook.stop.duration",
        unit: {:native, :millisecond},
        tags: [:status]
      )
    ]
  end

  defp periodic_measurements, do: []
end
