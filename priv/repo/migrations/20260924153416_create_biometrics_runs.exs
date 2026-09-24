defmodule Phantom.Repo.Migrations.CreateBiometricsRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :name, :string, null: false
      add :seed, :bigint, null: false
      add :status, :string, null: false, default: "running"
      add :shots, {:array, :string}, null: false, default: []
      add :captures, :integer, null: false, default: 1
      add :renderer, :string
      add :steps, :integer
      add :prompt_version, :string
      add :subject_count, :integer, null: false
      add :report, :map
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runs, [:name])

    create table(:subjects) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :name, :string, null: false
      add :seed, :bigint, null: false
      add :description, :text
      add :attributes, :map, null: false, default: %{}
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subjects, [:run_id, :position])
    create unique_index(:subjects, [:run_id, :name])

    create table(:images) do
      add :subject_id, references(:subjects, on_delete: :delete_all), null: false
      add :shot, :string, null: false
      add :modality, :string, null: false
      add :capture, :integer, null: false, default: 0
      add :pos, :string
      add :status, :string, null: false
      add :width, :integer
      add :height, :integer
      add :seed, :bigint
      add :prompt, :text
      add :reference_id, references(:images, on_delete: :nilify_all)
      add :storage_key, :string
      add :content_type, :string
      add :byte_size, :integer
      add :sha256, :string
      add :meta, :map
      add :ground_truth, :map
      add :duration_ms, :integer
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:images, [:subject_id, :shot])
    create index(:images, [:reference_id])
  end
end
