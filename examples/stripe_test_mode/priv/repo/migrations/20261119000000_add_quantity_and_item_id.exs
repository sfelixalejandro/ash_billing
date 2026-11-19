defmodule AshBillingConsumer.Repo.Migrations.AddQuantityAndItemId do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add(:quantity, :integer)
      add(:provider_subscription_item_id, :text)
    end

    create(
      constraint(:subscriptions, :subscriptions_quantity_positive,
        check: "quantity IS NULL OR quantity >= 1"
      )
    )
  end
end
