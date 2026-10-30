defmodule AshBilling.Resource.Transformers.AddCustomerIdAttribute do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource
  alias Spark.Dsl.Transformer

  @impl true
  def before?(Resource.Transformers.DefaultAccept), do: true
  def before?(Resource.Transformers.ValidateRelationshipAttributes), do: true
  def before?(Resource.Transformers.AttributesByName), do: true
  def before?(Resource.Transformers.CacheActionInputs), do: true
  def before?(Resource.Transformers.SetPrimaryActions), do: true
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

    dsl_state =
      if Resource.Info.attribute(dsl_state, :billing_deleted_at) do
        dsl_state
      else
        tombstone =
          Transformer.build_entity!(Resource.Dsl, [:attributes], :attribute,
            name: :billing_deleted_at,
            type: Ash.Type.UtcDatetimeUsec,
            allow_nil?: true,
            public?: false
          )

        Transformer.add_entity(dsl_state, [:attributes], tombstone)
      end

    result =
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

    with {:ok, state} <- result do
      {:ok,
       AshBilling.Transformers.ProtectBillingAttributes.exclude_from_wildcards(state, [
         attr_name,
         :billing_deleted_at
       ])}
    end
  end
end
