defmodule Phantom.Repo.Migrations.AddTemplateToImages do
  use Ecto.Migration

  def change do
    # The anchor's ArcFace template, for comparing it with the other anchors
    # of its run (Phantom.Biometrics.FaceGate).
    alter table(:images) do
      add :template, :binary
    end
  end
end
