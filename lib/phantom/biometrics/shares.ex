defmodule Phantom.Biometrics.Shares do
  @moduledoc """
  Sharing a subject's export outside the tailnet: the ZIP or NIST download is
  built as usual, uploaded to the S3 bucket (`Phantom.S3`, Cloudflare R2) and
  handed out as a presigned link. See `docs/s3-export-plan.md`.

  `create/3` records a `Share` and queues `Workers.UploadShare`, which calls
  `upload/1`: the export is spooled to a temp file (a ZIP's length isn't known
  until it's built, and a PUT needs one), then uploaded to
  `exports/<date>/<random token>/<filename>`. The token is 128 random bits, so
  a key can't be guessed from the subject or run.

  The bucket is private: a link works for `link_days` (at most 7, SigV4's
  limit) and `renew/1` signs a new one while the file is there. The bucket's
  lifecycle rule deletes files after `keep_days`; `expires_at` records when,
  so it must match that rule. Both are set with
  `config :phantom, #{inspect(__MODULE__)}`.

  `subscribe/1` delivers `{:share_updated, %Share{}}` for a subject's shares.
  """

  import Ecto.Query

  alias Phantom.{Repo, S3}
  alias Phantom.Biometrics.{Export, NistExport, Share, Subject}
  alias Phantom.Biometrics.Workers.UploadShare

  @kinds ~w(zip nist)

  @doc "Whether sharing is set up (a bucket is configured)."
  def enabled?, do: S3.configured?()

  @doc "Subscribes the caller to updates of `subject`'s shares."
  def subscribe(%Subject{id: id}), do: Phoenix.PubSub.subscribe(Phantom.PubSub, topic(id))

  defp broadcast(%Share{} = share) do
    Phoenix.PubSub.broadcast(Phantom.PubSub, topic(share.subject_id), {:share_updated, share})
    share
  end

  defp topic(subject_id), do: "biometrics:shares:#{subject_id}"

  @doc "`subject`'s most recent shares, newest first."
  def list(%Subject{id: id}, limit \\ 10) do
    Repo.all(
      from s in Share, where: s.subject_id == ^id, order_by: [desc: s.inserted_at], limit: ^limit
    )
  end

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Share, id)
      :error -> nil
    end
  end

  @doc """
  Shares `subject` (with `:run` and `:images` loaded) as `kind` (`"zip"` or
  `"nist"`) with the download's `options` (string keys), and queues the
  upload. The export is planned here, so a choice with nothing to export
  fails at once: `{:error, :empty}`, `{:error, :wsq_unavailable}`.
  """
  def create(%Subject{} = subject, kind, options) when kind in @kinds do
    options = options(kind, options)

    with :ok <- check_enabled(),
         {:ok, file} <- plan(subject, kind, options) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :share,
        %Share{subject_id: subject.id}
        |> Share.changeset(%{kind: kind, options: options, filename: file.filename})
      )
      |> Oban.insert(:job, fn %{share: share} -> UploadShare.new(%{share_id: share.id}) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{share: share}} -> {:ok, broadcast(share)}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp check_enabled, do: if(enabled?(), do: :ok, else: {:error, :not_configured})

  defp options("zip", options) do
    include = options["include"]
    %{"include" => if(include in Export.includes(), do: include, else: "all")}
  end

  defp options("nist", options) do
    %{
      "content" => options["content"],
      "compression" => options["compression"],
      "search" => options["search"] |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    }
  end

  # The download a share uploads: file name, content type and a function
  # that makes its lazy stream.
  defp plan(subject, "zip", %{"include" => include}) do
    export = Export.new(subject, include)

    if export.files == [],
      do: {:error, :empty},
      else:
        {:ok,
         %{
           filename: export.filename,
           content_type: "application/zip",
           stream: fn -> Export.stream(export) end
         }}
  end

  defp plan(subject, "nist", options) do
    with {:ok, export} <- NistExport.new(subject, options) do
      {:ok,
       %{
         filename: NistExport.filename(export),
         content_type: NistExport.content_type(export),
         stream: fn -> NistExport.stream(export) end
       }}
    end
  end

  @doc """
  Builds `share`'s export, uploads it and signs its link. Returns
  `{:ok, share}` with the share `:ready`, or `{:error, reason}` (the caller,
  `Workers.UploadShare`, decides whether to retry; see `failed/3`).
  """
  def upload(%Share{} = share) do
    share = put(share, status: :uploading)
    subject = Repo.preload(share, subject: [:images, :run]).subject
    temp = Path.join(System.tmp_dir!(), "phantom-share-#{share.id}")

    try do
      with {:ok, file} <- plan(subject, Atom.to_string(share.kind), share.options),
           {:ok, byte_size, sha256} <- spool(file.stream.(), temp),
           key = key(file.filename),
           :ok <-
             S3.put_file(key, temp,
               content_type: file.content_type,
               content_disposition: ~s(attachment; filename="#{file.filename}")
             ) do
        expires_at = DateTime.add(DateTime.utc_now(), keep_days(), :day)

        {:ok,
         share
         |> put(
           status: :ready,
           filename: file.filename,
           key: key,
           content_type: file.content_type,
           byte_size: byte_size,
           sha256: sha256,
           expires_at: expires_at,
           error: nil
         )
         |> sign()}
      end
    after
      File.rm(temp)
    end
  end

  # Writes the stream to `path`, hashing it on the way.
  defp spool(stream, path) do
    File.open(path, [:write, :binary], fn io ->
      {hash, size} =
        Enum.reduce(stream, {:crypto.hash_init(:sha256), 0}, fn chunk, {hash, size} ->
          :ok = IO.binwrite(io, chunk)
          {:crypto.hash_update(hash, chunk), size + IO.iodata_length(chunk)}
        end)

      {size, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
    end)
    |> case do
      {:ok, {size, sha256}} -> {:ok, size, sha256}
      {:error, reason} -> {:error, "Couldn't write the export: #{:file.format_error(reason)}"}
    end
  end

  defp key(filename) do
    token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "exports/#{Date.utc_today()}/#{token}/#{filename}"
  end

  @doc """
  Signs a new link for a share whose file is still in the bucket, valid for
  `link_days` or until the file is deleted, whichever is sooner.
  """
  def renew(%Share{} = share) do
    if Share.stored?(share), do: {:ok, sign(share)}, else: {:error, :expired}
  end

  defp sign(%Share{} = share) do
    now = DateTime.utc_now()
    seconds = min(link_days() * 86_400, DateTime.diff(share.expires_at, now))

    put(share,
      url: S3.presign(share.key, seconds),
      link_expires_at: DateTime.add(now, seconds, :second)
    )
  end

  @doc """
  Records that an upload failed: `:failed` when `final?` (Oban has given up),
  otherwise back to `:queued` with the error, for the retry.
  """
  def failed(%Share{id: id}, reason, final?) do
    Repo.get!(Share, id)
    |> put(status: if(final?, do: :failed, else: :queued), error: message(reason))
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(:empty), do: "Nothing to export: this person has no images of that kind."
  defp message(:wsq_unavailable), do: "WSQ needs NIST's cwsq on this machine."
  defp message(reason), do: inspect(reason)

  defp put(share, attrs) do
    share |> Share.changeset(Map.new(attrs)) |> Repo.update!() |> broadcast()
  end

  defp link_days, do: config(:link_days, 7) |> min(7) |> max(1)
  defp keep_days, do: config(:keep_days, 14)

  defp config(key, default),
    do: Application.get_env(:phantom, __MODULE__, []) |> Keyword.get(key, default)
end
