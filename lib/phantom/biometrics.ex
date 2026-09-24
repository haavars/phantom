defmodule Phantom.Biometrics do
  @moduledoc """
  Synthetic biometric subjects: fictional people with a consistent face,
  fingerprints and palmprints, generated in runs.

  This is the context the rest of the app goes through. A run (`Run`) is a
  batch of subjects (`Subject`), each with one image (`Image`) per shot (see
  `Phantom.Biometrics.Shots`). Creating a run queues one
  `Phantom.Biometrics.Workers.GenerateSubject` Oban job per subject; the
  `generation` queue renders one subject at a time (`Generator`) and records
  every image here as it goes.

  ## Events

  `subscribe/0` delivers:

    * `{:run_updated, %Run{}}` - a run was queued, started, got a subject
      done, or finished, failed or was cancelled (with its summary fields set,
      see `list_runs/0`)
    * `{:subject_updated, %Subject{}}` - a subject started or got an image,
      with its images preloaded
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Phantom.Repo

  alias Phantom.Biometrics.{
    Export,
    FacePrompts,
    Gallery,
    Image,
    Report,
    Run,
    RunRequest,
    Shots,
    Storage,
    Subject,
    Traits
  }

  alias Phantom.Biometrics.Workers.GenerateSubject
  alias Phantom.Services.{Qwen, Ridgegen}

  @topic "biometrics"

  ## Events

  @doc "Subscribes the caller to run and subject events (see the module docs)."
  def subscribe, do: Phoenix.PubSub.subscribe(Phantom.PubSub, @topic)

  defp broadcast(event), do: Phoenix.PubSub.broadcast(Phantom.PubSub, @topic, event)

  defp broadcast_run(%Run{} = run), do: broadcast({:run_updated, summarize(run)})

  defp broadcast_subject(%Subject{} = subject),
    do: broadcast({:subject_updated, Repo.preload(subject, :images, force: true)})

  ## Runs

  @doc """
  All runs, newest first, each with `:completed_subjects` (subjects with every
  shot attempted) and `:cover` (an image to show for it, or nil) set.
  """
  def list_runs do
    Repo.all(from r in Run, order_by: [desc: r.inserted_at, desc: r.id]) |> with_summary()
  end

  @doc "A run by name, with its subjects and their images in order."
  def get_run(name) do
    case Repo.get_by(Run, name: name) do
      nil -> {:error, :not_found}
      run -> {:ok, run |> Repo.preload(subjects: :images) |> summarize()}
    end
  end

  @doc "A run by id, without its subjects, or nil."
  def get_run_by_id(id), do: Repo.get(Run, id)

  def run_exists?(name), do: Repo.exists?(from r in Run, where: r.name == ^name)

  @doc """
  Where the run that is rendering right now is, or nil: `%{run:, total:,
  done:, shots:, subject:}`, with the subject being rendered and its images
  so far.
  """
  def current_progress do
    query = from r in Run, where: r.status == :running, order_by: [desc: r.started_at], limit: 1

    case Repo.one(query) do
      nil -> nil
      run -> progress(run)
    end
  end

  @doc "`current_progress/0` for a given run."
  def progress(%Run{} = run) do
    subjects =
      Repo.all(
        from s in Subject,
          where: s.run_id == ^run.id,
          order_by: s.position,
          preload: [:images]
      )

    %{
      run: run.name,
      total: run.subject_count,
      done: Enum.count(subjects, & &1.completed_at),
      shots: run.shots,
      subject: Enum.find(subjects, &is_nil(&1.completed_at))
    }
  end

  defp summarize(run), do: run |> List.wrap() |> with_summary() |> hd()

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
      where: s.run_id in ^run_ids and i.shot in ^shots and i.status == :ok,
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

  ## Creating, resuming and cancelling runs

  @doc "A changeset for the new-run form."
  def change_run_request(params \\ %{}), do: RunRequest.changeset(params)

  @doc """
  Validates `params` (see `Phantom.Biometrics.RunRequest`) and queues a run
  with one job per subject. Works the same from the web form and from IEx:

      Phantom.Biometrics.create_run(%{subjects: 5, shots: ["rolled", "card"], captures: 2})

      Phantom.Biometrics.create_run(%{
        subjects: 10,
        traits: %{ancestry: "Northern European", sex: "female"}
      })

  Returns `{:ok, run}` or `{:error, changeset}`.
  """
  def create_run(params) do
    with {:ok, request} <-
           params |> RunRequest.changeset() |> Ecto.Changeset.apply_action(:insert) do
      {:ok, shots} = Shots.expand(request.shots, request.captures)
      seed = request.seed || random_seed()

      attrs = %{
        name: request.run || default_run_name(seed),
        seed: seed,
        shots: shots,
        captures: request.captures,
        renderer: request.renderer,
        steps: request.steps,
        prompt_version: FacePrompts.version(),
        traits: Traits.to_map(request.traits),
        subject_count: request.subjects
      }

      queue(%Run{}, attrs, 1..request.subjects)
    end
  end

  @doc """
  Queues the subjects of a run that are missing an image (see
  `incomplete_positions/1`): the rest of a cancelled, failed or grown run,
  shots that failed, and images whose files were deleted. Images already
  stored are kept, and the rest are rendered again from the seeds and prompts
  they were first rendered with.
  """
  def resume_run(%Run{} = run) do
    case incomplete_positions(run) do
      [] -> finish_run(run)
      positions -> queue(run, %{}, positions)
    end
  end

  @doc """
  Adds `shots` (shot ids and group names, as `create_run/1` takes them) to a
  run that isn't rendering, and queues its subjects to render them.
  Friction-ridge shots get the run's captures, and face shots bring the anchor
  when the run has none. Seeds are derived per shot, so a shot added later
  comes out as it would have in the first run:

      Phantom.Biometrics.add_shots(run, ["probe_glasses"])

  Returns `{:ok, run}` or `{:error, message}`.
  """
  def add_shots(%Run{} = run, shots) do
    with :ok <- if(Run.active?(run), do: {:error, "The run is still rendering."}, else: :ok),
         :ok <- if(shots == [], do: {:error, "Pick at least one shot."}, else: :ok),
         {:ok, new} <- Shots.expand(shots, run.captures),
         {:ok, shots} <- Shots.expand(run.shots ++ new) do
      case incomplete_positions(%{run | shots: shots}) do
        [] -> {:ok, run}
        positions -> queue(run, %{shots: shots}, positions)
      end
    end
  end

  @doc """
  Positions of the subjects of `run` without a stored image of every one of
  its shots, including subjects not rendered yet.
  """
  def incomplete_positions(%Run{} = run) do
    subjects = Repo.all(from s in Subject, where: s.run_id == ^run.id, preload: :images)
    done = for subject <- subjects, complete?(subject, run.shots), do: subject.position
    Enum.reject(1..run.subject_count//1, &(&1 in done))
  end

  defp complete?(subject, shots) do
    images = Map.new(subject.images, &{&1.shot, &1})
    not is_nil(subject.completed_at) and Enum.all?(shots, &stored?(images[&1]))
  end

  defp stored?(image), do: Image.rendered?(image) and Storage.exists?(image.storage_key)

  # Queued subjects count as incomplete until they're rendered again, so the
  # run finishes when the last of them is done, not the first.
  defp queue(run, attrs, positions) do
    positions = Enum.to_list(positions)

    Multi.new()
    |> Multi.insert_or_update(:run, Run.queue_changeset(run, attrs))
    |> Multi.update_all(
      :reopened,
      fn %{run: run} ->
        from s in Subject, where: s.run_id == ^run.id and s.position in ^positions
      end,
      set: [completed_at: nil]
    )
    |> then(fn multi -> Enum.reduce(positions, multi, &queue_subject/2) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} ->
        broadcast_run(run)
        {:ok, run}

      {:error, :run, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp queue_subject(position, multi) do
    Oban.insert(
      Oban,
      multi,
      {:job, position},
      fn %{run: run} -> GenerateSubject.new(%{run_id: run.id, position: position}) end,
      []
    )
  end

  @doc "Cancels a run's queued and running subject jobs. Images already rendered are kept."
  def cancel_run(%Run{} = run) do
    Oban.cancel_all_jobs(
      from(j in Oban.Job,
        where:
          j.worker == ^Oban.Worker.to_string(GenerateSubject) and
            fragment("? @> ?", j.args, ^%{run_id: run.id})
      )
    )

    update_status(run, :cancelled)
  end

  @doc "Marks a run failed, e.g. when a subject job ran out of attempts."
  def fail_run(run_id, message) do
    case get_run_by_id(run_id) do
      nil -> {:error, :not_found}
      run -> update_status(run, :failed, message)
    end
  end

  defp update_status(run, status, error \\ nil) do
    with {:ok, run} <- run |> Run.status_changeset(status, error) |> Repo.update() do
      broadcast_run(run)
      {:ok, run}
    end
  end

  ## Rendering (used by `Phantom.Biometrics.Generator`)

  @doc """
  Records that the subject at `position` of `run` is being rendered, with
  `attrs` (`:seed`, `:description`, `:attributes`), and marks the run running.
  A subject rendered before keeps the values it has, so it stays the same
  person even if the code deriving them has changed since. Returns the
  subject with the images it already has.
  """
  def start_subject(%Run{} = run, position, attrs) do
    if run.status == :queued, do: update_status(run, :running)

    subject =
      Repo.get_by(Subject, run_id: run.id, position: position) ||
        %Subject{run_id: run.id, position: position, name: Subject.name(position)}

    attrs = Map.filter(attrs, fn {key, _value} -> Map.get(subject, key) in [nil, %{}] end)

    subject =
      subject
      |> Ecto.Changeset.change(Map.put(attrs, :completed_at, nil))
      |> Repo.insert_or_update!()
      |> Repo.preload(:images, force: true)

    broadcast_subject(subject)
    subject
  end

  @doc "Records the result of rendering a shot, replacing an earlier attempt at it."
  def save_image(%Subject{} = subject, attrs) do
    result =
      (Repo.get_by(Image, subject_id: subject.id, shot: attrs.shot) ||
         %Image{subject_id: subject.id})
      |> Image.changeset(attrs)
      |> Repo.insert_or_update()

    with {:ok, _image} <- result, do: broadcast_subject(subject)
    result
  end

  @doc """
  Records that every shot of `subject` was attempted. When that completes the
  run, its report is built and it is marked finished.
  """
  def complete_subject(%Subject{} = subject) do
    subject =
      subject |> Ecto.Changeset.change(completed_at: DateTime.utc_now()) |> Repo.update!()

    broadcast_subject(subject)
    run = subject.run_id |> get_run_by_id() |> summarize()

    if run.status == :running and run.completed_subjects >= run.subject_count,
      do: finish_run(run),
      else: broadcast_run(run)
  end

  defp finish_run(run) do
    subjects = Repo.all(from s in Subject, where: s.run_id == ^run.id, preload: :images)

    with {:ok, run} <-
           run |> Ecto.Changeset.change(report: Report.build(subjects)) |> Repo.update() do
      update_status(run, :finished)
    end
  end

  ## Subjects, images and identities

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

  def get_image(id) do
    case Repo.get(Image, id) do
      nil -> {:error, :not_found}
      image -> {:ok, image}
    end
  end

  ## Downloads

  @doc """
  Plans the download of one subject as a ZIP (see `Phantom.Biometrics.Export`):
  `include` is `"all"`, `"faces"` or `"prints"`. Returns `{:ok, export}` or
  `{:error, :not_found}`; `export_stream/1` then produces the archive.
  """
  def export_subject(run_name, subject_name, include \\ "all") do
    with {:ok, subject} <- get_subject(run_name, subject_name) do
      {:ok, subject |> Repo.preload(:run) |> Export.new(include)}
    end
  end

  defdelegate export_stream(export), to: Export, as: :stream

  @doc "What each download of `subject` (with its images) holds: files and bytes per include."
  defdelegate download_summary(subject), to: Export, as: :summary

  @doc "The file name to save one image under: `PH-5167-ED5B_fgp02_R_index.png`."
  def download_name(%Image{} = image) do
    image = Repo.preload(image, :subject)
    Export.download_name(image, image.subject)
  end

  @doc "A local path to an image's file, to send it."
  def image_path(%Image{storage_key: key}) when is_binary(key), do: Storage.local_path(key)
  def image_path(_image), do: :error

  defdelegate identities(limit \\ 48), to: Gallery
  defdelegate identity_stats(identities), to: Gallery, as: :stats

  ## Services

  @doc "Health of the services that render faces and friction ridges."
  def service_status, do: %{face: Qwen.health(), ridge: Ridgegen.health()}

  @doc "`:ok` when the services `shots` need are ready, else `{:error, message}`."
  def check_services(shots) do
    cond do
      Enum.any?(shots, &Shots.face?/1) and Qwen.health() != :ready ->
        {:error, "The Qwen-Image-2.1 service isn't ready."}

      Enum.any?(shots, &Shots.ridge?/1) and Ridgegen.health() != :ready ->
        {:error, "The friction-ridge service isn't ready."}

      true ->
        :ok
    end
  end

  ## Names and seeds

  defp random_seed, do: :rand.uniform(2_147_483_646)

  # `<utc timestamp>-seed<seed>`
  defp default_run_name(seed),
    do: "#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}-seed#{seed}"
end
