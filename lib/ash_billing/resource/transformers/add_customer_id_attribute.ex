defmodule AshBilling.Resource.Transformers.AddCustomerIdAttribute do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource
  alias Spark.Dsl.Transformer

  @impl true
  def before?(Resource.Transformers.DefaultAccept), do: true
  def before?(Resource.Transformers.ValidateRelationshipAttributes), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    attr_name =
      Transformer.get_option(
        dsl_state,
        [:billing],
        :customer_id_attribute,
        :stripe_customer_id
      )

    if Resource.Info.attribute(dsl_state, attr_name) do
      {:ok, dsl_state}
    else
      attribute =
        Transformer.build_entity!(Resource.Dsl, [:attributes], :attribute,
          name: attr_name,
          type: Ash.Type.String,
          allow_nil?: true,
          public?: true
        )

      {:ok, Transformer.add_entity(dsl_state, [:attributes], attribute)}
    end
  end
end
