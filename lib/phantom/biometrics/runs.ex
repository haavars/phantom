defmodule Phantom.Biometrics.Runs do
  @moduledoc """
  Runs, their subjects and images, in the database (`Phantom.Biometrics.Run`,
  `Phantom.Biometrics.Subject`, `Phantom.Biometrics.Image`). Image files live
  in `Phantom.Biometrics.Storage`; images only keep their storage key.

  `Phantom.Biometrics.Harness` writes through this module as it renders, so
  pages that read a run see it fill in, and a cancelled run can be resumed
  from what is already stored.
  """

  import Ecto.Query

  alias Phantom.Repo
  alias Phantom.Biometrics.{Image, Run, Subject}

  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

  @doc "True for names that are safe in URLs and storage keys (run and subject names)."
  def valid_name?(name) when is_binary(name), do: name =~ @name_format
  def valid_name?(_name), do: false

  ## Reading

  @doc """
  All runs, newest first. Each has `:completed_subjects` (subjects with every
  shot attempted) and `:cover` (the first subject's frontal mugshot or index
  finger, or nil) set.
  """
  def list_runs do
    Repo.all(from r in Run, order_by: [desc: r.inserted_at, desc: r.id]) |> with_summary()
  end

  @doc "One run by name, with the same fields set as in `list_runs/0`."
  def summary(name) do
    case Repo.get_by(Run, name: name) do
      nil -> {:error, :not_found}
      run -> {:ok, run |> List.wrap() |> with_summary() |> hd()}
    end
  end

  defp with_summary(runs) do
    run_ids = Enum.map(runs, & &1.id)

    completed =
      from(s in Subject,
        where: s.run_id in ^run_ids and not is_nil(s.completed_at),
        group_by: s.run_id,
        select: {s.run_id, count(s.id)}
      )
      |> Repo.all()
      |> Map.new()

    covers = covers(run_ids)

    Enum.map(runs, fn run ->
      %{run | completed_subjects: Map.get(completed, run.id, 0), cover: covers[run.id]}
    end)
  end

  # Per run: the first subject's frontal mugshot, else its right index finger,
  # else its right thumb.
  defp covers(run_ids) do
    shots = ["mugshot_frontal", "rolled_02", "rolled_01"]

    from(i in Image,
      join: s in assoc(i, :subject),
      where: s.run_id in ^run_ids and i.shot in ^shots and i.status == "ok",
      order_by: [asc: s.position],
      select: {s.run_id, s.position, i}
    )
    |> Repo.all()
    |> Enum.group_by(fn {run_id, _position, _image} -> run_id end)
    |> Map.new(fn {run_id, [{_run_id, first_position, _image} | _] = rows} ->
      images = for {_run_id, ^first_position, image} <- rows, do: image
      {run_id, Enum.min_by(images, fn image -> Enum.find_index(shots, &(&1 == image.shot)) end)}
    end)
  end

  @doc "True when a run with this name exists."
  def exists?(name), do: Repo.exists?(from r in Run, where: r.name == ^name)

  @doc "A run by name with its subjects and their images, in order."
  def get_run(name) do
    case Repo.get_by(Run, name: name) do
      nil -> {:error, :not_found}
      run -> {:ok, run |> Repo.preload(subjects: :images) |> put_completed()}
    end
  end

  defp put_completed(%Run{subjects: subjects} = run),
    do: %{run | completed_subjects: Enum.count(subjects, & &1.completed_at)}

  @doc "One subject of a run, with its images."
  def get_subject(run_name, subject_name) do
    query =
      from s in Subject,
        join: r in assoc(s, :run),
        where: r.name == ^run_name and s.name == ^subject_name,
        preload: [:images]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      subject -> {:ok, subject}
    end
  end

  @doc "An image by id."
  def get_image(id) do
    case Repo.get(Image, id) do
      nil -> {:error, :not_found}
      image -> {:ok, image}
    end
  end

  @doc """
  Subjects across all runs that have at least one rendered image, newest run
  first, at most `limit`. Each has its images and run preloaded.
  """
  def list_subjects_with_images(limit) do
    rendered = from i in Image, where: i.status == "ok", select: i.subject_id

    Repo.all(
      from s in Subject,
        join: r in assoc(s, :run),
        where: s.id in subquery(rendered),
        order_by: [desc: r.inserted_at, desc: r.id, asc: s.position],
        limit: ^limit,
        preload: [:images, run: r]
    )
  end

  ## Writing

  @doc """
  Starts a run, or restarts the existing one with the same name (to resume
  it). Returns `{:ok, run}` or `{:error, changeset}`.
  """
  def start_run(attrs) do
    (Repo.get_by(Run, name: attrs.name) || %Run{})
    |> Run.start_changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Marks a run finished, cancelled or failed."
  def finish_run(%Run{} = run, status, error \\ nil) do
    run |> Run.finish_changeset(status, error) |> Repo.update()
  end

  @doc "`finish_run/3` for a run given by name."
  def finish_run_by_name(name, status, error \\ nil) do
    case Repo.get_by(Run, name: name) do
      nil -> {:error, :not_found}
      run -> finish_run(run, status, error)
    end
  end

  @doc """
  Marks runs still `running` as cancelled. Called at startup: nothing can be
  running then, so these were interrupted by a restart and can be resumed.
  """
  def interrupt_running do
    {count, _} =
      Repo.update_all(from(r in Run, where: r.status == "running"),
        set: [status: "cancelled", finished_at: DateTime.utc_now()]
      )

    count
  end

  def put_report(%Run{} = run, report) do
    run |> Ecto.Changeset.change(report: report) |> Repo.update()
  end

  @doc """
  The subject at `position` of `run`, created or updated with `attrs`
  (`:seed`, `:description`, `:attributes`). Its images are preloaded.
  """
  def ensure_subject(%Run{} = run, position, attrs) do
    subject =
      Repo.get_by(Subject, run_id: run.id, position: position) ||
        %Subject{run_id: run.id, position: position, name: Subject.name(position)}

    subject
    |> Ecto.Changeset.change(
      seed: attrs.seed,
      description: attrs.description,
      attributes: attrs.attributes,
      completed_at: nil
    )
    |> Repo.insert_or_update!()
    |> Repo.preload(:images, force: true)
  end

  def complete_subject(%Subject{} = subject) do
    subject |> Ecto.Changeset.change(completed_at: DateTime.utc_now()) |> Repo.update!()
  end

  @doc "Records the result of a shot, replacing an earlier attempt at it."
  def put_image(%Subject{} = subject, attrs) do
    (Repo.get_by(Image, subject_id: subject.id, shot: attrs.shot) ||
       %Image{subject_id: subject.id})
    |> Image.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
