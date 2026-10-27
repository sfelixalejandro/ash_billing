defmodule AshBilling.WebhookEvent.Transformers.AddWebhookEventAttributes do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource
  alias Spark.Dsl.Transformer

  @impl true
  def before?(Resource.Transformers.DefaultAccept), do: true
  def before?(Resource.Transformers.ValidateRelationshipAttributes), do: true
  def before?(Resource.Transformers.CachePrimaryKey), do: true
  def before?(Resource.Transformers.CacheUniqueKeys), do: true
  def before?(Resource.Transformers.AttributesByName), do: true
  def before?(Resource.Transformers.CacheActionInputs), do: true
  def before?(Resource.Transformers.SetPrimaryActions), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    attributes = [
      {:event_id, Ash.Type.String, [primary_key?: true, allow_nil?: false, public?: true]},
      {:status, Ash.Type.Atom,
       [
         constraints: [one_of: [:processing, :processed, :failed]],
         default: :processing,
         allow_nil?: false,
         public?: true
       ]},
      {:processed_at, Ash.Type.UtcDatetimeUsec, [allow_nil?: true, public?: true]},
      {:last_attempt_at, Ash.Type.UtcDatetimeUsec, [allow_nil?: true, public?: true]},
      {:attempts, Ash.Type.Integer, [default: 1, allow_nil?: false, public?: true]},
      {:error, Ash.Type.String, [allow_nil?: true, public?: true]}
    ]

    add_attributes(dsl_state, attributes)
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
end
