defmodule AshBilling.Resource.Verifiers.VerifyCustomerIdAttribute do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    attr_name =
      Verifier.get_option(
        dsl_state,
        [:billing],
        :customer_id_attribute,
        :stripe_customer_id
      )

    case Ash.Resource.Info.attribute(dsl_state, attr_name) do
      nil ->
        :ok

      %{type: type} ->
        if type in [Ash.Type.String, Ash.Type.CiString] do
          :ok
        else
          module = Verifier.get_persisted(dsl_state, :module)

          {:error,
           Spark.Error.DslError.exception(
             path: [:billing, :customer_id_attribute],
             message:
               "The customer_id_attribute #{inspect(attr_name)} on #{inspect(module)} must be of type :string or :ci_string, got: #{inspect(type)}."
           )}
        end
    end
  end
end
