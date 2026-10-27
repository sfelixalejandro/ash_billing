defmodule AshBilling.Subscription.Verifiers.VerifyCustomerRelationship do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:billing_subscription], :customer_relationship) do
      nil ->
        :ok

      rel_name ->
        if Ash.Resource.Info.relationship(dsl_state, rel_name) do
          :ok
        else
          module = Verifier.get_persisted(dsl_state, :module)

          {:error,
           Spark.Error.DslError.exception(
             path: [:billing_subscription, :customer_relationship],
             message:
               "The customer_relationship #{inspect(rel_name)} configured for #{inspect(module)} was not found in its relationships."
           )}
        end
    end
  end
end
