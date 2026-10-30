defmodule AshBilling.Transformers.ProtectBillingAttributes do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  # Trusted provider attributes are present before action changes/validations.
  # Widen only this in-memory action, not the resource's public action contract.
  # Actor, tenant, policies, validations and identities still run normally.
  def create(resource, attrs, opts) do
    action = Ash.Resource.Info.primary_action!(resource, :create)
    action = %{action | accept: Enum.uniq((action.accept || []) ++ Map.keys(attrs))}

    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.force_change_attributes(attrs)
    |> Ash.Changeset.for_create(action, %{}, opts)
    |> Ash.create(opts)
  end

  # Record the wildcard's intent before Ash expands it. Apply exclusions after
  # DefaultAccept so attributes injected by other extensions remain available.
  def exclude_from_wildcards(state, protected) do
    default =
      Transformer.get_option(state, [:actions], :default_accept) ||
        if(Ash.Resource.Info.embedded?(state), do: :*, else: [])

    default_input = List.wrap(default)
    default_blocked = if :* in default_input, do: protected -- default_input, else: []
    previous = Transformer.get_persisted(state, {__MODULE__, :default_blocked}, [])

    state =
      Transformer.persist(
        state,
        {__MODULE__, :default_blocked},
        Enum.uniq(previous ++ default_blocked)
      )

    blocked = Transformer.get_persisted(state, {__MODULE__, :blocked}, %{})

    blocked =
      Enum.reduce(Transformer.get_entities(state, [:actions]), blocked, fn action, acc ->
        if Map.has_key?(action, :accept) do
          input = List.wrap(action.accept || default)
          excluded = if :* in input, do: protected -- input, else: []
          Map.update(acc, {action.type, action.name}, excluded, &Enum.uniq(&1 ++ excluded))
        else
          acc
        end
      end)

    Transformer.persist(state, {__MODULE__, :blocked}, blocked)
  end

  @impl true
  def after?(Ash.Resource.Transformers.DefaultAccept), do: true
  def after?(_), do: false

  @impl true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(_), do: false

  @impl true
  def transform(state) do
    blocked = Transformer.get_persisted(state, {__MODULE__, :blocked}, %{})

    fallback = Transformer.get_persisted(state, {__MODULE__, :default_blocked}, [])

    state =
      Enum.reduce(Transformer.get_entities(state, [:actions]), state, fn action, acc ->
        excluded =
          if Map.has_key?(action, :accept),
            do: Map.get(blocked, {action.type, action.name}, fallback),
            else: []

        case excluded do
          [] ->
            acc

          fields ->
            Transformer.replace_entity(
              acc,
              [:actions],
              %{action | accept: action.accept -- fields},
              &(&1.name == action.name and &1.type == action.type)
            )
        end
      end)

    {:ok, state}
  end
end
