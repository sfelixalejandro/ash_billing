# Idempotent demo seed for SaasExample
# Run with: mix run priv/repo/seeds.exs

alias SaasExample.{Accounts, Billing, Workspace}
alias SaasExample.Accounts.User
alias SaasExample.Billing.{Catalog, Subscription}
alias SaasExample.Workspace.{Report, Seat}

require Ash.Query

ensure_user = fn email, name, password, role, stripe_customer_id ->
  case User
       |> Ash.Query.filter(email == ^email)
       |> Ash.read_one(domain: Accounts, authorize?: false) do
    {:ok, nil} ->
      {:ok, user} =
        Accounts.register_user(%{
          email: email,
          name: name,
          password: password,
          role: role
        })

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

ensure_subscription = fn user, attrs ->
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

period_end = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)

_free = ensure_user.("free@example.com", "Free User", "password1234", :member, nil)

starter =
  ensure_user.(
    "starter@example.com",
    "Starter Owner",
    "password1234",
    :member,
    "cus_demo_starter"
  )

pro = ensure_user.("pro@example.com", "Pro Owner", "password1234", :member, "cus_demo_pro")

enterprise =
  ensure_user.(
    "enterprise@example.com",
    "Enterprise Admin",
    "password1234",
    :admin,
    "cus_demo_enterprise"
  )

ensure_subscription.(starter, %{
  provider_subscription_id: "sub_demo_starter",
  status: :active,
  price_id: Catalog.price_id!(:starter),
  quantity: 2,
  provider_subscription_item_id: "si_demo_starter",
  current_period_end: period_end,
  last_reconciled_at: DateTime.utc_now()
})

ensure_subscription.(pro, %{
  provider_subscription_id: "sub_demo_pro",
  status: :active,
  price_id: Catalog.price_id!(:pro),
  quantity: 5,
  provider_subscription_item_id: "si_demo_pro",
  current_period_end: period_end,
  last_reconciled_at: DateTime.utc_now()
})

ensure_subscription.(enterprise, %{
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
    ] do
  for member_email <- emails do
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
end

for {owner, title} <- [
      {starter, "Starter Monthly Overview"},
      {pro, "Pro Growth Cohort Report"},
      {enterprise, "Enterprise Compliance Ledger"}
    ] do
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

IO.puts("""
Seeded SaasExample demo accounts (password for all: password1234):
  - free@example.com       (No subscription)
  - starter@example.com    (Starter plan, 2 seats contracted, 1 used)
  - pro@example.com        (Pro plan, 5 seats contracted, 2 used)
  - enterprise@example.com (Enterprise plan, 20 seats contracted, 2 used, admin)
""")
