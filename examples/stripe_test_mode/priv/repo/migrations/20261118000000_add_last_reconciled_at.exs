defmodule AshBillingConsumer.Repo.Migrations.AddLastReconciledAt do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add(:last_reconciled_at, :utc_datetime_usec)
    end
  end
end
