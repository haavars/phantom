defmodule Phantom.Biometrics.Harness do
  @moduledoc """
  Generates batches of synthetic subjects: fictional people with any mix of face
  images (Qwen-Image-2.1, see `Phantom.Biometrics.FacePrompts`) and
  friction-ridge images (fingers, slaps, palms, tenprint card, see
  `Phantom.Biometrics.FrictionRidge`).

  For each subject it samples `Phantom.Biometrics.FaceAttributes` from the
  subject seed. Face shots start with the anchor (frontal mugshot) rendered
  from text, and every other face shot is conditioned on it. Friction-ridge
  shots are all derived from the subject seed, so every image of one subject
  shows the same fingers and palms.

  The run, its subjects and every image are recorded in the database as they
  are rendered (see `Phantom.Biometrics.Runs`), and the files go to
  `Phantom.Biometrics.Storage` under `<run>/<subject>/<shot>.png`.

  Everything is derived from the run seed, so running again with the same
  `:run` and `:seed` keeps the images already rendered and renders the missing
  ones identically. Pass `force: true` to render everything again.

  Run it with `mix biometrics.generate`, from IEx with `run/1`, or in the
  background with `Phantom.Biometrics.Runner`.
  """

  alias Phantom.Biometrics.{
    FaceAttributes,
    FacePrompts,
    FrictionRidge,
    Image,
    Report,
    Run,
    Runs,
    Shots,
    Storage
  }

  alias Phantom.ImageGeneration

  @renderers ~w(diffusion procedural)
  @default_renderer "diffusion"

  @doc """
  Runs the harness: `start/1`, then `execute/2`. Options:

    * `:subjects` - number of subjects, defaults to 3
    * `:seed` - run seed, defaults to a random one
    * `:shots` - shot ids and group names (see `Phantom.Biometrics.Shots.expand/2`),
      defaults to `["faces"]`; the face anchor is added whenever there are face shots
    * `:captures` - captures per friction-ridge shot, defaults to 1
    * `:renderer` - friction-ridge renderer, `"diffusion"` (realistic, GPU; the
      default) or `"procedural"` (fast CPU draft), see `renderers/0`
    * `:steps` - denoising steps, defaults to 40
    * `:run` - run name, defaults to `<timestamp>-seed<seed>`
    * `:force` - render images again even if they exist, defaults to false
    * `:on_progress` - 1-arity function called with `{:subject_started, subject}`,
      `{:shot, subject_name, image}` and `{:subject_done, subject}`

  Returns `{:ok, %{run: run, subjects: [subject], report: report}}` or
  `{:error, message}` for invalid options. `report` is the friction-ridge
  quality report (`Phantom.Biometrics.Report`), nil for runs without verified images.
  """
  def run(opts \\ []) do
    with {:ok, run} <- start(opts), do: execute(run, opts)
  end

  @doc """
  Validates the options and records the run as running, creating it or
  restarting the existing run with the same name. Returns `{:ok, run}` or
  `{:error, message}`.
  """
  def start(opts) do
    captures = Keyword.get(opts, :captures, 1)

    with {:ok, shots} <- resolve_shots(Keyword.get(opts, :shots, ["faces"]), captures) do
      seed = Keyword.get_lazy(opts, :seed, &random_seed/0)

      attrs = %{
        name: Keyword.get_lazy(opts, :run, fn -> default_run_name(seed) end),
        seed: seed,
        shots: shots,
        captures: captures,
        renderer: Keyword.get(opts, :renderer, @default_renderer),
        steps: Keyword.get(opts, :steps, 40),
        prompt_version: FacePrompts.version(),
        subject_count: Keyword.get(opts, :subjects, 3)
      }

      case Runs.start_run(attrs) do
        {:ok, run} -> {:ok, run}
        {:error, changeset} -> {:error, "Couldn't start the run: #{inspect(changeset.errors)}"}
      end
    end
  end

  @doc "Renders every subject of a started run, then stores its report and marks it finished."
  def execute(%Run{} = run, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _event -> :ok end)
    force? = Keyword.get(opts, :force, false)

    subjects =
      for position <- 1..run.subject_count//1 do
        subject = run_subject(run, position, force?, on_progress)
        on_progress.({:subject_done, subject})
        subject
      end

    report = Report.build(subjects)
    {:ok, run} = Runs.put_report(run, report)
    {:ok, run} = Runs.finish_run(run, "finished")

    {:ok, %{run: run, subjects: subjects, report: report}}
  end

  @doc "Friction-ridge renderers, the default first."
  def renderers, do: @renderers

  @doc """
  The shot ids a run with `shots` (ids and group names, see
  `Phantom.Biometrics.Shots.expand/2`) and `captures` renders, in order.
  `{:error, message}` for unknown names.
  """
  def resolve_shots(shots, captures \\ 1) do
    case Shots.expand(shots, captures) do
      {:ok, []} -> {:error, "Pick at least one shot."}
      result -> result
    end
  end

  defp run_subject(run, position, force?, on_progress) do
    subject_seed = derive_seed(run.seed, position)
    attrs = FaceAttributes.sample(subject_seed)

    subject =
      Runs.ensure_subject(run, position, %{
        seed: subject_seed,
        description: FaceAttributes.describe(attrs),
        # Stored as JSON: string keys, like it reads back.
        attributes: attrs |> Jason.encode!() |> Jason.decode!()
      })

    stored = Map.new(subject.images, &{&1.shot, &1})
    on_progress.({:subject_started, %{subject | images: []}})

    {images, _anchor} =
      Enum.map_reduce(run.shots, nil, fn shot, anchor ->
        image = run_shot(shot, run, subject, attrs, anchor, stored[shot], force?)
        on_progress.({:shot, subject.name, image})

        anchor =
          if shot == FacePrompts.anchor_shot() and Image.rendered?(image), do: image, else: anchor

        {image, anchor}
      end)

    %{Runs.complete_subject(subject) | images: images}
  end

  defp run_shot(shot, run, subject, attrs, anchor, stored, force?) do
    if not force? and Image.rendered?(stored) and Storage.exists?(stored.storage_key) do
      stored
    else
      spec = Shots.spec(shot)

      attrs =
        case spec do
          %{modality: :face} -> render_face(spec, run, subject, attrs, anchor)
          %{modality: :ridge} -> render_ridge(spec, run, subject)
        end

      {:ok, image} = Runs.put_image(subject, attrs)
      image
    end
  end

  defp render_face(spec, run, subject, attrs, anchor) do
    {width, height} = spec.size

    base = %{
      shot: spec.id,
      modality: "face",
      pos: spec.code,
      width: width,
      height: height,
      seed: derive_seed(subject.seed, spec.id),
      prompt: FacePrompts.prompt(spec.id, attrs),
      reference_id: anchor && anchor.id,
      capture: 0,
      meta: nil,
      ground_truth: nil,
      error: nil
    }

    references =
      cond do
        spec.anchor? -> {:ok, []}
        is_nil(anchor) -> :no_anchor
        true -> anchor_reference(anchor)
      end

    case references do
      :no_anchor ->
        failed(base, "skipped", "anchor shot failed", nil)

      {:error, message} ->
        failed(base, "error", message, nil)

      {:ok, images} ->
        started = System.monotonic_time(:millisecond)

        result =
          ImageGeneration.render(base.prompt,
            width: width,
            height: height,
            steps: run.steps,
            seed: base.seed,
            images: images
          )

        duration_ms = System.monotonic_time(:millisecond) - started

        case result do
          {:ok, %{image: png}} -> stored(base, run, subject, png, duration_ms)
          {:error, message} -> failed(base, "error", message, duration_ms)
        end
    end
  end

  defp anchor_reference(anchor) do
    case Storage.read(anchor.storage_key) do
      {:ok, data} ->
        {:ok, [%{data: data, filename: anchor.shot <> ".png", content_type: "image/png"}]}

      {:error, reason} ->
        {:error, "couldn't read the anchor image: #{inspect(reason)}"}
    end
  end

  # Fingers, slaps, palms and the tenprint card all come from the subject seed,
  # so every image of one subject shows the same fingers and palms.
  defp render_ridge(spec, run, subject) do
    {width, height} = spec.size

    base = %{
      shot: spec.id,
      modality: "ridge",
      pos: spec.code,
      width: width,
      height: height,
      seed: subject.seed,
      capture: spec.capture,
      prompt: nil,
      reference_id: nil,
      meta: nil,
      ground_truth: nil,
      error: nil
    }

    started = System.monotonic_time(:millisecond)

    result =
      FrictionRidge.render(spec.kind, spec.numeric_code, subject.seed, spec.capture,
        label: subject.name,
        renderer: run.renderer
      )

    duration_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{image: png, meta: meta, generator: generator}} ->
        base
        |> Map.merge(%{
          meta: summarize(meta),
          ground_truth: Map.put(meta, "generator", generator)
        })
        |> stored(run, subject, png, duration_ms)

      {:error, message} ->
        failed(base, "error", message, duration_ms)
    end
  end

  defp stored(base, run, subject, png, duration_ms) do
    key = Storage.key(run.name, subject.name, base.shot)

    case Storage.put(key, png) do
      {:ok, file} ->
        base
        |> Map.merge(file)
        |> Map.merge(%{status: "ok", content_type: "image/png", duration_ms: duration_ms})

      {:error, reason} ->
        failed(base, "error", "couldn't store the image: #{inspect(reason)}", duration_ms)
    end
  end

  defp failed(base, status, message, duration_ms) do
    Map.merge(base, %{
      status: status,
      error: message,
      duration_ms: duration_ms,
      storage_key: nil,
      byte_size: nil,
      sha256: nil
    })
  end

  # `meta` keeps the small facts (pattern classes, counts, verification
  # scores) for pages and reports; minutiae and drift point lists stay in the
  # full ground truth.
  defp summarize(meta) do
    meta
    |> Map.drop(["minutiae", "generator"])
    |> Map.update("fingers", nil, fn fingers ->
      Enum.map(fingers, &Map.take(&1, ["fgp", "pattern"]))
    end)
    |> Map.update("verification", nil, fn check ->
      check
      |> Map.drop(["missed", "spurious", "detected"])
      |> Map.update("fingers", nil, fn fingers ->
        Enum.map(fingers, &Map.take(&1, ["fgp", "nfiq2", "minutiae_recall", "minutiae_spurious"]))
      end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Deterministic 31-bit seed derived from a parent seed and a key.
  defp derive_seed(parent, key), do: :erlang.phash2({parent, key}, 2_147_483_647)

  @doc "A random run seed."
  def random_seed, do: :rand.uniform(2_147_483_646)

  @doc "The run name used when none is given: `<utc timestamp>-seed<seed>`."
  def default_run_name(seed) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d-%H%M%S")

    "#{timestamp}-seed#{seed}"
  end
end
