defmodule AshBilling.Test.DurablePeerHelper do
  @moduledoc false

  alias AshBilling.Test.{PostgresCustomer, PostgresDomain, PostgresSubscription, Repo}

  defmodule LiveProvider do
    @moduledoc false
    def get_subscription(_id, opts) do
      case Keyword.get(opts, :live_response) do
        %{} = payload -> {:ok, payload}
        {:error, _} = err -> err
        _ -> {:error, :missing_live_response}
      end
    end
  end

  def bootstrap(app_env) do
    for {key, val} <- app_env do
      if key == Repo do
        val =
          val
          |> Keyword.delete(:pool)
          |> Keyword.put(:pool_size, 2)

        Application.put_env(:ash_billing, key, val)
      else
        Application.put_env(:ash_billing, key, val)
      end
    end

    {:ok, _} = Application.ensure_all_started(:ash_billing)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Supervisor.start_child(AshBilling.Supervisor, Repo)
    {:ok, :os.getpid()}
  end

  def reconcile(sub_id, live_payload, opts \\ []) do
    AshBilling.reconcile_subscription(
      sub_id,
      Keyword.merge(
        [
          subscription_resource: PostgresSubscription,
          customer_resource: PostgresCustomer,
          domain: PostgresDomain,
          authorize?: false,
          provider: LiveProvider,
          live_response: live_payload
        ],
        opts
      )
    )
  end

  def sync_webhook(event, live_payload, opts \\ []) do
    AshBilling.WebhookSync.sync_event(
      event,
      Keyword.merge(
        [
          customer_resource: PostgresCustomer,
          subscription_resource: PostgresSubscription,
          domain: PostgresDomain,
          authorize?: false,
          provider: LiveProvider,
          live_response: live_payload
        ],
        opts
      )
    )
  end

  def fetch_subscription(sub_id) do
    require Ash.Query

    PostgresSubscription
    |> Ash.Query.filter(provider_subscription_id == ^sub_id)
    |> Ash.read_one(domain: PostgresDomain, authorize?: false)
  end
end
