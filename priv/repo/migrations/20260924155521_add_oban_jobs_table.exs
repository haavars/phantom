defmodule Phantom.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Version 1 drops everything Oban created.
  def down, do: Oban.Migration.down(version: 1)
end
