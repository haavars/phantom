defmodule Phantom.Repo.Migrations.CreateShares do
  use Ecto.Migration

  def change do
    # Exports uploaded to the S3 bucket and shared as presigned links
    # (Phantom.Biometrics.Shares).
    create table(:shares, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :subject_id, references(:subjects, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :options, :map, null: false, default: %{}
      add :status, :string, null: false, default: "queued"
      add :filename, :string, null: false
      add :key, :string
      add :content_type, :string
      add :byte_size, :bigint
      add :sha256, :string
      add :url, :text
      add :link_expires_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:shares, [:subject_id, :inserted_at])
  end
end
