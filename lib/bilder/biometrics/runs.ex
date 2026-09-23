defmodule Bilder.Biometrics.Runs do
  @moduledoc """
  Reads `Bilder.Biometrics.Harness` runs back from the output folder.

  The folder is the source of truth, so runs started from `mix biometrics.generate`
  and from the web UI show up alike. Subjects and shots come back as maps with
  the same keys as the harness's in-memory records (`:id`, `:seed`,
  `:description`, `:shots`; each shot `:shot`, `:pos`, `:file`, `:status`, ...),
  so callers can treat live progress and finished runs the same way.
  """

  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

  @doc "The output root, `config :bilder, :biometrics_output_dir`."
  def root, do: Application.get_env(:bilder, :biometrics_output_dir, "data/synthetic/biometrics")

  @doc "True for names that are safe as a single path segment (run, subject or file names)."
  def valid_name?(name) when is_binary(name), do: name =~ @name_format
  def valid_name?(_name), do: false

  def exists?(name, root \\ root()),
    do: valid_name?(name) and File.exists?(Path.join([root, name, "run.json"]))

  @doc "Summaries of all runs, most recently updated first."
  def list_runs(root \\ root()) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          case summary(name, root) do
            {:ok, summary} -> [summary]
            {:error, :not_found} -> []
          end
        end)
        |> Enum.sort_by(& &1.updated_at, :desc)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Summary of one run: `:id`/`:name`, `:seed`, `:shots`, `:steps`, `:prompt_version`,
  `:subjects` (planned), `:completed` (subjects written), `:cover` (the first
  subject's anchor file, as `{subject_id, file}`, or `nil`) and `:updated_at` (unix seconds).
  """
  def summary(name, root \\ root()) do
    with true <- valid_name?(name),
         dir = Path.join(root, name),
         {:ok, json} <- File.read(Path.join(dir, "run.json")),
         {:ok, config} <- Jason.decode(json) do
      subject_ids = subject_ids(dir)

      {:ok,
       %{
         id: name,
         name: name,
         seed: config["seed"],
         shots: config["shots"] || [],
         steps: config["steps"],
         captures: config["captures"] || 1,
         prompt_version: config["prompt_version"],
         subjects: config["subjects"] || 0,
         completed: length(subject_ids),
         cover: cover(dir, subject_ids),
         updated_at: updated_at(dir)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "A run summary plus its finished subjects (those with a `subject.json`), in order."
  def get_run(name, root \\ root()) do
    with {:ok, summary} <- summary(name, root) do
      dir = Path.join(root, name)

      subjects =
        dir
        |> subject_ids()
        |> Enum.flat_map(fn id ->
          case read_subject(Path.join(dir, id)) do
            {:ok, subject} -> [subject]
            :error -> []
          end
        end)

      {:ok, Map.put(summary, :subjects_list, subjects)}
    end
  end

  @doc "One finished subject of a run."
  def get_subject(run, subject_id, root \\ root()) do
    if valid_name?(run) and valid_name?(subject_id) do
      case read_subject(Path.join([root, run, subject_id])) do
        {:ok, subject} -> {:ok, subject}
        :error -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Absolute path of an image or JSON file inside a run, if every segment is a
  valid name and the file exists. Used to serve files over HTTP.
  """
  def file_path(run, subject_id, file, root \\ root()) do
    path = Path.join([root, run, subject_id, file])

    if Enum.all?([run, subject_id, file], &valid_name?/1) and
         Path.extname(file) in [".png", ".json"] and File.regular?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  defp subject_ids(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(valid_name?(&1) and File.exists?(Path.join([dir, &1, "subject.json"]))))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp read_subject(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "subject.json")),
         {:ok, data} <- Jason.decode(json) do
      {:ok,
       %{
         id: data["id"],
         seed: data["seed"],
         description: data["description"],
         shots: Enum.map(data["shots"] || [], &shot_from_json/1)
       }}
    else
      _ -> :error
    end
  end

  defp shot_from_json(shot) do
    %{
      shot: shot["shot"],
      pos: shot["pos"],
      file: shot["file"],
      width: shot["width"],
      height: shot["height"],
      seed: shot["seed"],
      reference: shot["reference"],
      prompt: shot["prompt"],
      capture: shot["capture"] || 0,
      meta: shot["meta"],
      ground_truth: shot["ground_truth"],
      status: shot["status"],
      duration_ms: shot["duration_ms"],
      error: shot["error"]
    }
  end

  defp cover(_dir, []), do: nil

  defp cover(dir, [first | _]) do
    Enum.find_value(
      ["mugshot_frontal.png", "rolled_02.png", "rolled_01.png", "slap_13.png"],
      fn file ->
        if File.exists?(Path.join([dir, first, file])), do: {first, file}
      end
    )
  end

  # index.html is rewritten after every subject, so it tracks the last activity.
  defp updated_at(dir) do
    ["index.html", "run.json"]
    |> Enum.map(&File.stat(Path.join(dir, &1), time: :posix))
    |> Enum.find_value(0, fn
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> nil
    end)
  end
end
