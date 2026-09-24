defmodule Bilder.Biometrics.Harness do
  @moduledoc """
  Generates batches of synthetic subjects: fictional people with any mix of face
  images (Qwen-Image-2.1, see `Bilder.Biometrics.FacePrompts`) and
  friction-ridge images (fingers, slaps, palms, tenprint card, see
  `Bilder.Biometrics.FrictionRidge`).

  For each subject it samples `Bilder.Biometrics.FaceAttributes` from the
  subject seed. Face shots start with the anchor (frontal mugshot) rendered
  from text, and every other face shot is conditioned on it. Friction-ridge
  shots are all derived from the subject seed, so every image of one subject
  shows the same fingers and palms. Output goes to a plain folder:

      <out>/<run>/run.json
      <out>/<run>/index.html                 contact sheet, one row per subject
      <out>/<run>/subject_001/subject.json   attributes, prompts, seeds, timings
      <out>/<run>/subject_001/<shot>.png
      <out>/<run>/subject_001/<shot>.json    friction-ridge ground truth (minutiae, patterns, verification)
      <out>/<run>/report.json                friction-ridge quality report, see `Bilder.Biometrics.Report`

  Everything is derived from the run seed, so re-running with the same `:run`
  and `:seed` skips images that already exist and regenerates missing ones
  identically. Pass `force: true` to regenerate everything.

  Run it with `mix biometrics.generate`, or from IEx with `run/1`.
  """

  alias Bilder.Biometrics.{FaceAttributes, FacePrompts, FrictionRidge, Report, Runs, Shots}
  alias Bilder.ImageGeneration

  @renderers ~w(diffusion procedural)
  @default_renderer "diffusion"

  @doc """
  Runs the harness. Options:

    * `:subjects` - number of subjects, defaults to 3
    * `:seed` - run seed, defaults to a random one
    * `:shots` - shot ids and group names (see `Bilder.Biometrics.Shots.expand/2`),
      defaults to `["faces"]`; the face anchor is added whenever there are face shots
    * `:captures` - captures per friction-ridge shot, defaults to 1
    * `:renderer` - friction-ridge renderer, `"diffusion"` (realistic, GPU; the
      default) or `"procedural"` (fast CPU draft), see `renderers/0`
    * `:steps` - denoising steps, defaults to 40
    * `:out` - output root, defaults to `Bilder.Biometrics.Runs.root/0`
    * `:run` - run directory name, defaults to `<timestamp>-seed<seed>`
    * `:force` - regenerate images that already exist, defaults to false
    * `:on_progress` - 1-arity function called with `{:subject_started, %{id:, seed:, description:}}`,
      `{:shot, subject_id, shot_record}` and `{:subject_done, subject_record}`

  Returns `{:ok, %{dir: run_dir, index: index_path, subjects: [subject_record], report: report}}`
  or `{:error, message}` for invalid options. `report` is the friction-ridge
  quality report (`Bilder.Biometrics.Report`), nil for runs without verified images.
  """
  def run(opts \\ []) do
    with {:ok, shots} <-
           resolve_shots(Keyword.get(opts, :shots, ["faces"]), Keyword.get(opts, :captures, 1)) do
      seed = Keyword.get_lazy(opts, :seed, &random_seed/0)
      run_name = Keyword.get_lazy(opts, :run, fn -> default_run_name(seed) end)
      run_dir = Path.join(Keyword.get_lazy(opts, :out, &Runs.root/0), run_name)
      File.mkdir_p!(run_dir)

      config = %{
        run: run_name,
        seed: seed,
        shots: shots,
        captures: Keyword.get(opts, :captures, 1),
        renderer: Keyword.get(opts, :renderer, @default_renderer),
        steps: Keyword.get(opts, :steps, 40),
        prompt_version: FacePrompts.version(),
        subjects: Keyword.get(opts, :subjects, 3)
      }

      write_json(Path.join(run_dir, "run.json"), config)

      on_progress = Keyword.get(opts, :on_progress, fn _event -> :ok end)
      force? = Keyword.get(opts, :force, false)

      subjects =
        Enum.reduce(1..config.subjects//1, [], fn index, done ->
          subject = run_subject(index, config, run_dir, force?, on_progress)
          on_progress.({:subject_done, subject})
          done = done ++ [subject]
          write_contact_sheet(run_dir, config, done)
          done
        end)

      report = Report.write(run_dir, subjects)

      {:ok,
       %{
         dir: run_dir,
         index: Path.join(run_dir, "index.html"),
         subjects: subjects,
         report: report
       }}
    end
  end

  @doc "Friction-ridge renderers, the default first."
  def renderers, do: @renderers

  @doc """
  The shot ids a run with `shots` (ids and group names, see
  `Bilder.Biometrics.Shots.expand/2`) and `captures` renders, in order.
  `{:error, message}` for unknown names.
  """
  def resolve_shots(shots, captures \\ 1) do
    case Shots.expand(shots, captures) do
      {:ok, []} -> {:error, "Pick at least one shot."}
      result -> result
    end
  end

  defp run_subject(index, config, run_dir, force?, on_progress) do
    id = "subject_" <> String.pad_leading(Integer.to_string(index), 3, "0")
    subject_seed = derive_seed(config.seed, index)
    attrs = FaceAttributes.sample(subject_seed)
    dir = Path.join(run_dir, id)
    File.mkdir_p!(dir)

    on_progress.(
      {:subject_started,
       %{id: id, seed: subject_seed, description: FaceAttributes.describe(attrs)}}
    )

    {records, _anchor} =
      Enum.map_reduce(config.shots, nil, fn shot, anchor ->
        record = run_shot(shot, attrs, subject_seed, anchor, dir, config, force?)
        on_progress.({:shot, id, record})

        anchor =
          if shot == FacePrompts.anchor_shot() and record.status in ["ok", "existing"],
            do: File.read!(Path.join(dir, record.file)),
            else: anchor

        {record, anchor}
      end)

    subject = %{
      id: id,
      seed: subject_seed,
      description: FaceAttributes.describe(attrs),
      attributes: attrs,
      shots: records
    }

    write_json(Path.join(dir, "subject.json"), subject)
    subject
  end

  defp run_shot(shot, attrs, subject_seed, anchor, dir, config, force?) do
    case Shots.spec(shot) do
      %{modality: :face} ->
        run_face_shot(shot, attrs, subject_seed, anchor, dir, config.steps, force?)

      %{modality: :ridge} = spec ->
        run_ridge_shot(spec, subject_seed, dir, config.renderer, force?)
    end
  end

  defp run_face_shot(shot, attrs, subject_seed, anchor, dir, steps, force?) do
    spec = FacePrompts.spec(shot)
    {width, height} = spec.size
    file = shot <> ".png"
    path = Path.join(dir, file)

    record = %{
      shot: shot,
      pos: spec.pos,
      file: file,
      width: width,
      height: height,
      seed: derive_seed(subject_seed, shot),
      reference: if(spec.anchor?, do: nil, else: FacePrompts.anchor_shot() <> ".png"),
      prompt: FacePrompts.prompt(shot, attrs),
      # Same keys as friction-ridge records, so every shot record has one shape.
      capture: 0,
      meta: nil,
      ground_truth: nil,
      duration_ms: nil,
      error: nil
    }

    cond do
      File.exists?(path) and not force? ->
        Map.put(record, :status, "existing")

      not spec.anchor? and is_nil(anchor) ->
        Map.merge(record, %{status: "skipped", error: "anchor shot failed"})

      true ->
        images =
          if spec.anchor?,
            do: [],
            else: [%{data: anchor, filename: record.reference, content_type: "image/png"}]

        started = System.monotonic_time(:millisecond)

        result =
          ImageGeneration.render(record.prompt,
            width: width,
            height: height,
            steps: steps,
            seed: record.seed,
            images: images
          )

        duration_ms = System.monotonic_time(:millisecond) - started

        case result do
          {:ok, %{image: png}} ->
            File.write!(path, png)
            Map.merge(record, %{status: "ok", duration_ms: duration_ms})

          {:error, message} ->
            Map.merge(record, %{status: "error", duration_ms: duration_ms, error: message})
        end
    end
  end

  # Fingers, slaps, palms and the tenprint card all come from the subject seed,
  # so every image of one subject shows the same fingers and palms.
  defp run_ridge_shot(spec, subject_seed, dir, renderer, force?) do
    {width, height} = spec.size
    file = spec.id <> ".png"
    path = Path.join(dir, file)
    ground_truth = spec.id <> ".json"

    record = %{
      shot: spec.id,
      pos: spec.code,
      file: file,
      width: width,
      height: height,
      seed: subject_seed,
      capture: spec.capture,
      reference: nil,
      prompt: nil,
      meta: nil,
      ground_truth: nil,
      duration_ms: nil,
      error: nil
    }

    if File.exists?(path) and not force? do
      Map.merge(
        record,
        %{status: "existing"} |> Map.merge(existing_ground_truth(dir, ground_truth))
      )
    else
      started = System.monotonic_time(:millisecond)

      result =
        FrictionRidge.render(spec.kind, spec.numeric_code, subject_seed, spec.capture,
          label: Path.basename(dir),
          renderer: renderer
        )

      duration_ms = System.monotonic_time(:millisecond) - started

      case result do
        {:ok, %{image: png, meta: meta, generator: generator}} ->
          File.write!(path, png)
          write_json(Path.join(dir, ground_truth), Map.put(meta, "generator", generator))

          Map.merge(record, %{
            status: "ok",
            duration_ms: duration_ms,
            meta: summarize(meta),
            ground_truth: ground_truth
          })

        {:error, message} ->
          Map.merge(record, %{status: "error", duration_ms: duration_ms, error: message})
      end
    end
  end

  defp existing_ground_truth(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, json} -> %{meta: summarize(Jason.decode!(json)), ground_truth: file}
      {:error, _reason} -> %{}
    end
  end

  # The per-shot record keeps the small facts (pattern classes, counts,
  # verification scores); minutiae and drift point lists stay in the
  # ground-truth JSON next to the image.
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

  @doc "The run directory name used when none is given: `<utc timestamp>-seed<seed>`."
  def default_run_name(seed) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d-%H%M%S")

    "#{timestamp}-seed#{seed}"
  end

  defp write_json(path, data), do: File.write!(path, Jason.encode_to_iodata!(data, pretty: true))

  defp write_contact_sheet(run_dir, config, subjects) do
    rows =
      Enum.map(subjects, fn subject ->
        cells =
          Enum.map(config.shots, fn shot ->
            record = Enum.find(subject.shots, &(&1.shot == shot))
            src = "#{subject.id}/#{record.file}"

            image =
              if record.status in ["ok", "existing"],
                do: ~s(<a href="#{src}"><img src="#{src}" loading="lazy"></a>),
                else: ~s(<div class="missing">#{escape(record.error || record.status)}</div>)

            ~s(<td title="#{escape(record.prompt || Shots.label(shot))}">#{image}</td>)
          end)

        """
        <tr>
          <th><strong>#{subject.id}</strong><br><small>seed #{subject.seed}</small>
            <p>#{escape(subject.description)}</p></th>
          #{cells}
        </tr>
        """
      end)

    headers = Enum.map(config.shots, &"<th>#{&1}</th>")

    html = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Biometrics #{escape(config.run)}</title>
    <style>
      body { font: 13px/1.4 system-ui, sans-serif; margin: 16px; background: #f4f4f5; color: #18181b; }
      table { border-collapse: collapse; }
      th, td { border: 1px solid #d4d4d8; padding: 6px; vertical-align: top; background: #fff; }
      thead th { position: sticky; top: 0; font-weight: 600; }
      tbody th { width: 220px; text-align: left; font-weight: normal; }
      img { width: 220px; display: block; }
      .missing { width: 220px; height: 275px; display: grid; place-items: center; color: #b91c1c;
        background: #fef2f2; text-align: center; padding: 8px; box-sizing: border-box; }
    </style>
    </head>
    <body>
    <h1>Synthetic faces: #{escape(config.run)}</h1>
    <p>Seed #{config.seed} · prompts #{config.prompt_version} · #{config.steps} steps ·
      #{length(subjects)}/#{config.subjects} subjects · hover an image for its prompt.
      <strong>Synthetic test data, not real people.</strong></p>
    <table>
      <thead><tr><th>Subject</th>#{headers}</tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    </body>
    </html>
    """

    File.write!(Path.join(run_dir, "index.html"), html)
  end

  defp escape(text), do: text |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
end
