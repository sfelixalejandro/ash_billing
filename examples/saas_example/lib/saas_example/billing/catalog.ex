defmodule SaasExample.Billing.Catalog do
  @moduledoc """
  Server-controlled subscription plan catalog.

  Browser requests submit plan slugs (`"starter"`, `"pro"`, `"enterprise"`), never
  arbitrary Stripe Price IDs. All Checkout and plan-swap operations resolve and
  validate price IDs against this catalog.
  """

  @default_prices %{
    starter: "price_starter_monthly",
    pro: "price_pro_monthly",
    enterprise: "price_enterprise_monthly"
  }

  @plan_specs [
    %{
      key: :starter,
      slug: "starter",
      name: "Starter",
      price_display: "$19 / seat / mo",
      description: "Core workspace access, reports, and per-seat team billing."
    },
    %{
      key: :pro,
      slug: "pro",
      name: "Pro",
      price_display: "$49 / seat / mo",
      description: "Everything in Starter plus Pro Analytics Exports (HasPrice policy)."
    },
    %{
      key: :enterprise,
      slug: "enterprise",
      name: "Enterprise",
      price_display: "$99 / seat / mo",
      description: "Everything in Pro plus Enterprise Compliance Audits (HasPrice policy)."
    }
  ]

  @doc """
  Compile-time configured price map used by `AshBilling.Checks.HasPrice` policies
  and runtime catalog lookups so policies and Checkout stay strictly aligned.
  """
  @spec configured_prices() :: %{starter: String.t(), pro: String.t(), enterprise: String.t()}
  def configured_prices do
    Map.merge(@default_prices, Application.get_env(:saas_example, :plan_prices, %{}))
  end

  @spec plans() :: [map()]
  def plans do
    prices = configured_prices()

    Enum.map(@plan_specs, fn spec ->
      Map.put(spec, :price_id, Map.fetch!(prices, spec.key))
    end)
  end

  @spec price_id!(atom()) :: String.t()
  def price_id!(key) when key in [:starter, :pro, :enterprise] do
    Map.fetch!(configured_prices(), key)
  end

  @spec resolve_plan(atom() | String.t()) :: {:ok, map()} | {:error, :unknown_plan}
  def resolve_plan(key) when is_atom(key) do
    case Enum.find(plans(), &(&1.key == key)) do
      nil -> {:error, :unknown_plan}
      plan -> {:ok, plan}
    end
  end

  def resolve_plan(slug_or_price) when is_binary(slug_or_price) do
    trimmed = String.trim(slug_or_price)

    case Enum.find(plans(), fn p -> p.slug == trimmed or p.price_id == trimmed end) do
      nil -> {:error, :unknown_plan}
      plan -> {:ok, plan}
    end
  end

  def resolve_plan(_), do: {:error, :unknown_plan}

  @spec plan_name_for_price(String.t() | nil) :: String.t()
  def plan_name_for_price(nil), do: "None"

  def plan_name_for_price(price_id) when is_binary(price_id) do
    case Enum.find(plans(), &(&1.price_id == price_id)) do
      nil -> price_id
      plan -> plan.name
    end
  end
end
