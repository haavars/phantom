defmodule Phantom.Repo.Migrations.AddTraitsToRuns do
  use Ecto.Migration

  # The appearance every subject of a run shares (`Phantom.Biometrics.Traits`).
  def change do
    alter table(:runs) do
      add :traits, :map, null: false, default: %{}
    end
  end
end
