defmodule Phantom.Repo.Migrations.QueueRuns do
  use Ecto.Migration

  # Runs are queued as Oban jobs now, so a new run starts out queued.
  def change do
    alter table(:runs) do
      modify :status, :string, null: false, default: "queued", from: {:string, default: "running"}
    end
  end
end
