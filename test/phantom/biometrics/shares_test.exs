defmodule Phantom.Biometrics.SharesTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{Export, Gallery, Share, Shares}
  alias Phantom.Biometrics.Workers.UploadShare

  setup do
    run = create_run(subjects: 1, shots: ["mugshot_left_profile", "rolled_02"])
    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    %{run: run, subject: subject, code: Gallery.code(subject.seed)}
  end

  # Keeps what was uploaded in the test process's mailbox.
  defp stub_bucket(status \\ 200) do
    test = self()

    Req.Test.stub(Phantom.S3, fn conn ->
      {:ok, body, conn} = read_all(conn)
      send(test, {:uploaded, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, status, if(status == 200, do: "", else: "<Code>Nope</Code>"))
    end)
  end

  defp read_all(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary([acc, body]), conn}
      {:more, body, conn} -> read_all(conn, [acc, body])
    end
  end

  test "queues an upload, which puts the ZIP in the bucket and signs a link", %{
    subject: subject,
    code: code
  } do
    Biometrics.subscribe_shares(subject)
    {:ok, share} = Biometrics.share_subject(subject, "zip", %{"include" => "all"})

    assert %Share{status: :queued, filename: filename} = share
    assert filename == "#{code}_synthetic.zip"
    assert_enqueued(worker: UploadShare, args: %{share_id: share.id})
    assert_receive {:share_updated, %Share{status: :queued}}

    stub_bucket()
    assert :ok = perform_job(UploadShare, %{share_id: share.id})

    assert_receive {:uploaded, path, headers, body}
    assert path =~ ~r"^/phantom-test/exports/\d{4}-\d{2}-\d{2}/[0-9a-f]{32}/#{filename}$"
    assert {"content-disposition", ~s(attachment; filename="#{filename}")} in headers
    assert {"content-type", "application/zip"} in headers

    {:ok, files} = :zip.unzip(body, [:memory])
    assert length(files) == length(Export.entries(Export.new(subject, "all")))

    share = Repo.get!(Share, share.id)
    assert share.status == :ready
    assert share.byte_size == byte_size(body)
    assert share.sha256 == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    assert "/phantom-test/" <> key = path
    assert share.key == key
    assert share.url =~ "X-Amz-Signature="
    assert_in_delta DateTime.diff(share.link_expires_at, DateTime.utc_now(), :day), 7, 1
    assert_in_delta DateTime.diff(share.expires_at, DateTime.utc_now(), :day), 14, 1
    assert Share.link_valid?(share)
    assert_receive {:share_updated, %Share{status: :ready}}
  end

  test "shares NIST exports with their options", %{subject: subject, code: code} do
    {:ok, share} =
      Biometrics.share_subject(subject, "nist", %{"content" => "prints", "compression" => "png"})

    assert share.filename == "#{code}_enrol.an2"

    assert share.options == %{
             "content" => "prints",
             "compression" => "png",
             "target" => "ansi_nist",
             "search" => []
           }

    stub_bucket()
    assert :ok = perform_job(UploadShare, %{share_id: share.id})
    assert_receive {:uploaded, _path, headers, "1.001:" <> _}
    assert {"content-type", "application/octet-stream"} in headers
  end

  test "refuses a choice with nothing to export", %{run: run} do
    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    prints_only = %{subject | images: Enum.filter(subject.images, &(&1.modality == :ridge))}

    assert {:error, :empty} =
             Biometrics.share_subject(prints_only, "zip", %{"include" => "faces"})

    assert Repo.aggregate(Share, :count) == 0
  end

  test "retries a failed upload, then marks it failed", %{subject: subject} do
    {:ok, share} = Biometrics.share_subject(subject, "zip", %{"include" => "faces"})
    stub_bucket(403)

    assert {:error, "S3 answered 403: Nope"} =
             perform_job(UploadShare, %{share_id: share.id}, attempt: 1)

    assert %{status: :queued, error: "S3 answered 403: Nope"} = Repo.get!(Share, share.id)

    assert {:error, _reason} = perform_job(UploadShare, %{share_id: share.id}, attempt: 3)
    assert %{status: :failed} = Repo.get!(Share, share.id)
  end

  test "renews a link while the file is in the bucket", %{subject: subject} do
    {:ok, share} = Biometrics.share_subject(subject, "zip", %{"include" => "faces"})
    stub_bucket()
    :ok = perform_job(UploadShare, %{share_id: share.id})

    # A link signed 7 days ago with the file still there for 2 more days.
    share =
      Repo.get!(Share, share.id)
      |> Ecto.Changeset.change(
        link_expires_at: DateTime.add(DateTime.utc_now(), -60),
        expires_at: DateTime.add(DateTime.utc_now(), 2, :day)
      )
      |> Repo.update!()

    refute Share.link_valid?(share)
    assert {:ok, renewed} = Biometrics.renew_share(share.id)
    assert Share.link_valid?(renewed)
    assert renewed.url != share.url
    # Never outlives the file.
    assert DateTime.compare(renewed.link_expires_at, renewed.expires_at) != :gt

    renewed
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60))
    |> Repo.update!()

    assert {:error, :expired} = Biometrics.renew_share(share.id)
    assert {:error, :not_found} = Biometrics.renew_share(Ecto.UUID.generate())
  end

  test "lists a subject's shares, newest first", %{subject: subject} do
    {:ok, first} = Biometrics.share_subject(subject, "zip", %{"include" => "faces"})
    {:ok, second} = Biometrics.share_subject(subject, "zip", %{"include" => "prints"})

    assert Enum.map(Shares.list(subject), & &1.id) == [second.id, first.id]
  end

  test "cancels the job of a deleted share" do
    assert {:cancel, :share_deleted} = perform_job(UploadShare, %{share_id: Ecto.UUID.generate()})
  end
end
