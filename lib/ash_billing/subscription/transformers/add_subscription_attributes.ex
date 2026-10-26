defmodule AshBilling.Subscription.Transformers.AddSubscriptionAttributes do
  @moduledoc false
  use Spark.Dsl.Transformer
  require Ash.Expr
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

    with {:ok, state} <- add_attributes(dsl_state, attributes),
         {:ok, state} <- maybe_add_active_calculation(state) do
      {:ok, state}
    end
  end

  defp add_attributes(dsl_state, attributes) do
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

  defp maybe_add_active_calculation(state) do
    if Resource.Info.calculation(state, :active?) do
      {:ok, state}
    else
      expr = Ash.Expr.expr(status in [:active, :trialing])

      calculation =
        Transformer.build_entity!(Resource.Dsl, [:calculations], :calculate,
          name: :active?,
          type: Ash.Type.Boolean,
          calculation: expr,
          public?: true,
          filterable?: true
        )

      {:ok, Transformer.add_entity(state, [:calculations], calculation)}
    end
  end
end
