defmodule AshBilling.Subscription.Transformers.AddSubscriptionAttributes do
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
    attributes = [
      {:provider_subscription_id, Ash.Type.String, [allow_nil?: false, public?: true]},
      {:status, Ash.Type.Atom,
       [
         constraints: [
           one_of: [
             :active,
             :trialing,
             :past_due,
             :canceled,
             :unpaid,
             :incomplete,
             :incomplete_expired
           ]
         ],
         allow_nil?: false,
         public?: true
       ]},
      {:price_id, Ash.Type.String, [allow_nil?: true, public?: true]},
      {:current_period_end, Ash.Type.UtcDatetimeUsec, [allow_nil?: true, public?: true]},
      {:cancel_at_period_end, Ash.Type.Boolean, [default: false, public?: true]}
    ]

    Enum.reduce(attributes, {:ok, dsl_state}, fn {name, type, opts}, {:ok, state} ->
      if Resource.Info.attribute(state, name) do
        {:ok, state}
      else
        opts = Keyword.merge(opts, name: name, type: type)
        attribute = Transformer.build_entity!(Resource.Dsl, [:attributes], :attribute, opts)
        {:ok, Transformer.add_entity(state, [:attributes], attribute)}
      end
    end)
  end
end
