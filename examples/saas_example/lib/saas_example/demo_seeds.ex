defmodule SaasExample.DemoSeeds do
  @moduledoc """
  Idempotent demo data seeder restricted strictly to local development / demo
  environments via `SaasExample.Security.ensure_demo_seeds_allowed!/1`.
  """

  require Ash.Query

  alias SaasExample.{Accounts, Billing, Security, Workspace}
  alias SaasExample.Accounts.User
  alias SaasExample.Billing.{Catalog, Subscription}
  alias SaasExample.Workspace.{Report, Seat}

  @demo_password "password1234"

  @spec run!(keyword()) :: :ok
  def run!(opts \\ []) do
    Security.ensure_demo_seeds_allowed!(opts)

    period_end = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)

    _free = ensure_user("free@example.com", "Free User", :member, nil)

    starter =
      ensure_user("starter@example.com", "Starter Owner", :member, "cus_demo_starter")

    pro = ensure_user("pro@example.com", "Pro Owner", :member, "cus_demo_pro")

    enterprise =
      ensure_user("enterprise@example.com", "Enterprise Admin", :admin, "cus_demo_enterprise")

    ensure_subscription(starter, %{
      provider_subscription_id: "sub_demo_starter",
      status: :active,
      price_id: Catalog.price_id!(:starter),
      quantity: 2,
      provider_subscription_item_id: "si_demo_starter",
      current_period_end: period_end,
      last_reconciled_at: DateTime.utc_now()
    })

    ensure_subscription(pro, %{
      provider_subscription_id: "sub_demo_pro",
      status: :active,
      price_id: Catalog.price_id!(:pro),
      quantity: 5,
      provider_subscription_item_id: "si_demo_pro",
      current_period_end: period_end,
      last_reconciled_at: DateTime.utc_now()
    })

    ensure_subscription(enterprise, %{
      provider_subscription_id: "sub_demo_enterprise",
      status: :active,
      price_id: Catalog.price_id!(:enterprise),
      quantity: 20,
      provider_subscription_item_id: "si_demo_enterprise",
      current_period_end: period_end,
      last_reconciled_at: DateTime.utc_now()
    })

    for {owner, emails} <- [
          {starter, ["teammate1@starter.example"]},
          {pro, ["alice@pro.example", "bob@pro.example"]},
          {enterprise, ["ops@enterprise.example", "security@enterprise.example"]}
        ],
        member_email <- emails do
      ensure_seat(owner, member_email)
    end

    for {owner, title} <- [
          {starter, "Starter Monthly Overview"},
          {pro, "Pro Growth Cohort Report"},
          {enterprise, "Enterprise Compliance Ledger"}
        ] do
      ensure_report(owner, title)
    end

    :ok
  end

  defp ensure_user(email, name, role, stripe_customer_id) do
    case User
         |> Ash.Query.filter(email == ^email)
         |> Ash.read_one(domain: Accounts, authorize?: false) do
      {:ok, nil} ->
        attrs = %{email: email, name: name, password: @demo_password}

        {:ok, user} =
          case role do
            :admin -> Accounts.create_admin_user(attrs)
            :member -> Accounts.register_user(attrs)
          end

        if stripe_customer_id do
          user
          |> Ash.Changeset.for_update(:update, %{stripe_customer_id: stripe_customer_id})
          |> Ash.update!(domain: Accounts, authorize?: false)
        else
          user
        end

      {:ok, existing} ->
        existing
    end
  end

  defp ensure_subscription(user, attrs) do
    sub_id = attrs.provider_subscription_id

    case Subscription
         |> Ash.Query.filter(provider_subscription_id == ^sub_id)
         |> Ash.read_one(domain: Billing, authorize?: false) do
      {:ok, nil} ->
        Subscription
        |> Ash.Changeset.for_create(:create, %{})
        |> Ash.Changeset.force_change_attributes(Map.put(attrs, :user_id, user.id))
        |> Ash.create!(domain: Billing, authorize?: false)

      {:ok, existing} ->
        existing
    end
  end

  defp ensure_seat(owner, member_email) do
    case Seat
         |> Ash.Query.filter(
           owner_id == ^owner.id and member_email == ^member_email and status == :active
         )
         |> Ash.read_one(domain: Workspace, authorize?: false) do
      {:ok, nil} ->
        Ash.create!(Seat, %{owner_id: owner.id, member_email: member_email},
          domain: Workspace,
          authorize?: false
        )

      {:ok, _} ->
        :ok
    end
  end

  defp ensure_report(owner, title) do
    case Report
         |> Ash.Query.filter(owner_id == ^owner.id and title == ^title)
         |> Ash.read_one(domain: Workspace, authorize?: false) do
      {:ok, nil} ->
        Ash.create!(
          Report,
          %{owner_id: owner.id, title: title, summary: "Demo report seeded for #{owner.email}"},
          domain: Workspace,
          authorize?: false
        )

      {:ok, _} ->
        :ok
    end
  end
end
