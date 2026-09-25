defmodule PhantomWeb.NistExportLive do
  @moduledoc """
  `/biometrics/:run/:subject/nist`: export one subject as ANSI/NIST-ITL
  transactions (`Phantom.Biometrics.NistExport`). Choose what the enrolment
  holds (prints and face, prints only, face only), which face probes to add
  as search transactions, and PNG or WSQ for the prints. The page lists the
  files and records the download will have; the download itself is
  `PhantomWeb.DownloadController.nist/2`. With a bucket configured, the same
  export can be shared as a link (`Phantom.Biometrics.Shares`).
  """

  use PhantomWeb, :live_view

  import PhantomWeb.BiometricsComponents

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{Gallery, NistExport, NistImages, Shots}

  @contents [
    {"prints_faces", "Prints and face", "Mugshots with the rolled fingers, slaps and palms"},
    {"prints", "Prints only", "Rolled fingers, slaps and palms"},
    {"faces", "Face only", "The mugshot set: frontal, profiles and ¾ views"}
  ]

  @probe_hints %{
    "probe_aged" => "The same person 15 years older",
    "probe_appearance" => "A different look: hair, facial hair or weight",
    "probe_rebooking" => "Booked again: other clothes and expression",
    "probe_uncooperative" => "Booked drunk and disorderly, turned away and pulling a face",
    "probe_glasses" => "A casual photo wearing glasses",
    "probe_low_res" => "A small snapshot, about 40 px between the eyes",
    "icao_portrait" => "A passport-style portrait"
  }

  @impl true
  def mount(%{"run" => run, "subject" => name}, _session, socket) do
    case Biometrics.get_subject(run, name) do
      {:ok, subject} ->
        sharing? = Biometrics.sharing_enabled?()
        if sharing? and connected?(socket), do: Biometrics.subscribe_shares(subject)

        {:ok,
         socket
         |> assign(:sharing?, sharing?)
         |> assign(:shares, if(sharing?, do: Biometrics.list_shares(subject), else: []))
         |> assign(:page_title, "NIST export · #{Gallery.code(subject.seed)}")
         |> assign(:subject, subject)
         |> assign(:run, subject.run)
         |> assign(:code, Gallery.code(subject.seed))
         |> assign(:choices, NistExport.choices(subject))
         |> assign(:wsq?, NistImages.wsq_available?())
         |> assign(:contents, @contents)
         |> assign(:probe_hints, @probe_hints)
         |> assign_options(%{})}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Subject #{name} not found in #{run}.")
         |> push_navigate(to: ~p"/biometrics/#{run}")}
    end
  end

  @impl true
  def handle_event("change", %{"nist" => params}, socket) do
    {:noreply, assign_options(socket, params)}
  end

  def handle_event("share", _params, socket) do
    %{options: options, subject: subject} = socket.assigns

    params = %{
      "content" => options.content,
      "compression" => options.compression,
      "search" => options.search
    }

    case Biometrics.share_subject(subject, "nist", params) do
      {:ok, _share} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't share this export: #{inspect(reason)}.")}
    end
  end

  def handle_event("renew-share", %{"id" => id}, socket) do
    case Biometrics.renew_share(id) do
      {:ok, _share} -> {:noreply, socket}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "That file has been deleted.")}
    end
  end

  @impl true
  def handle_info({:share_updated, share}, socket) do
    shares = socket.assigns.shares

    shares =
      if Enum.any?(shares, &(&1.id == share.id)),
        do: Enum.map(shares, &if(&1.id == share.id, do: share, else: &1)),
        else: [share | shares]

    {:noreply, assign(socket, :shares, shares)}
  end

  # The chosen options, and the export they give (or why there's none).
  defp assign_options(socket, params) do
    content =
      if params["content"] in NistExport.contents(), do: params["content"], else: "prints_faces"

    compression =
      if params["compression"] == "wsq" and socket.assigns.wsq?, do: "wsq", else: "png"

    search = params |> Map.get("search", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    options = %{content: content, compression: compression, search: search}

    export =
      case NistExport.new(socket.assigns.subject, options) do
        {:ok, export} -> export
        {:error, _reason} -> nil
      end

    socket
    |> assign(:options, options)
    |> assign(:form, to_form(%{"content" => content, "compression" => compression}, as: :nist))
    |> assign(:export, export)
  end

  defp download_path(run, subject, options) do
    query = [content: options.content, compression: options.compression, search: options.search]
    ~p"/biometrics/#{run.name}/#{subject.name}/nist/download?#{query}"
  end

  # Estimated size of a transaction: stored PNGs, or WSQ at 0.75 bits per pixel for prints.
  defp estimate(transaction, compression) do
    Enum.sum_by(transaction.images, fn image ->
      if compression == "wsq" and image.modality == :ridge,
        do: div((image.width || 0) * (image.height || 0) * 3, 32),
        else: image.byte_size || 0
    end)
  end

  defp record_counts(transaction) do
    transaction.images
    |> NistExport.records()
    |> Enum.frequencies_by(& &1.type)
    |> Enum.sort()
  end

  defp record_name(10), do: "face"
  defp record_name(14), do: "fingerprint"
  defp record_name(15), do: "palm"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
      <div class="space-y-6">
        <nav class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-base-content/60">
          <.link
            navigate={~p"/biometrics/#{@run.name}"}
            id="back-to-run"
            class="font-mono transition hover:text-base-content"
          >
            {@run.name}
          </.link>
          <span class="text-base-content/30">/</span>
          <.link
            navigate={~p"/biometrics/#{@run.name}/#{@subject.name}"}
            id="back-to-subject"
            class="font-mono transition hover:text-base-content"
          >
            {@code}
          </.link>
        </nav>

        <header class="space-y-1">
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="text-2xl font-semibold tracking-tight">NIST export</h1>
            <span class="font-mono text-lg text-base-content/60">{@code}</span>
            <span class="rounded bg-base-content px-1.5 py-0.5 text-[10px] font-bold tracking-[0.15em] text-base-100">
              SYNTHETIC
            </span>
          </div>
          <p class="max-w-2xl text-sm text-base-content/65">
            ANSI/NIST-ITL 1-2011 Update:2015 transactions (<span class="font-mono">.an2</span>, Traditional encoding)
            to enrol this person in an ABIS, and optionally face probes to search for them with.
          </p>
        </header>

        <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
          <.form for={@form} id="nist-form" phx-change="change" class="space-y-6">
            <section id="enrolment" class="space-y-3">
              <div>
                <h2 class="text-sm font-semibold">Enrolment</h2>
                <p class="text-xs text-base-content/60">What the enrolment transaction holds.</p>
              </div>
              <div class="grid gap-2 sm:grid-cols-3">
                <label
                  :for={{value, title, hint} <- @contents}
                  for={"nist_content_#{value}"}
                  class={[
                    "flex cursor-pointer flex-col gap-1 rounded-xl border border-base-300 p-3 transition hover:border-primary/40",
                    "has-[:checked]:border-primary/60 has-[:checked]:bg-primary/5 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary"
                  ]}
                >
                  <span class="flex items-center gap-2">
                    <input
                      type="radio"
                      id={"nist_content_#{value}"}
                      name="nist[content]"
                      value={value}
                      checked={@options.content == value}
                      class="size-4 shrink-0 accent-[var(--color-primary)]"
                    />
                    <span class="text-sm font-medium">{title}</span>
                  </span>
                  <span class="text-xs text-base-content/60">{hint}</span>
                  <span class={[
                    "text-xs tabular-nums",
                    if(@choices.enrol[value] == "", do: "text-warning", else: "text-base-content/50")
                  ]}>
                    {if @choices.enrol[value] == "",
                      do: "Nothing rendered yet",
                      else: @choices.enrol[value]}
                  </span>
                </label>
              </div>
              <p
                :if={@export && @export.missing != []}
                id="missing"
                class="flex gap-1.5 text-xs text-warning"
              >
                <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
                Not in the enrolment, not rendered yet: {Enum.map_join(
                  @export.missing,
                  ", ",
                  &Shots.label/1
                )}.
              </p>
            </section>

            <section id="search" class="space-y-3">
              <div>
                <h2 class="text-sm font-semibold">Search</h2>
                <p class="text-xs text-base-content/60">
                  Each face probe you pick becomes its own search transaction for the same person.
                </p>
              </div>
              <input type="hidden" name="nist[search][]" value="" />
              <div :if={@choices.search != []} class="grid gap-2 sm:grid-cols-2">
                <label
                  :for={image <- @choices.search}
                  for={"nist_search_#{image.shot}"}
                  class={[
                    "flex cursor-pointer items-center gap-3 rounded-xl border border-base-300 p-2 pr-3 transition hover:border-primary/40",
                    "has-[:checked]:border-primary/60 has-[:checked]:bg-primary/5 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary"
                  ]}
                >
                  <img
                    src={preview_url(image)}
                    alt={Shots.label(image.shot)}
                    loading="lazy"
                    class="h-16 w-13 shrink-0 rounded-lg bg-base-200 object-cover"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block text-sm font-medium">{Shots.label(image.shot)}</span>
                    <span class="block text-xs text-base-content/60">{@probe_hints[image.shot]}</span>
                  </span>
                  <input
                    type="checkbox"
                    id={"nist_search_#{image.shot}"}
                    name="nist[search][]"
                    value={image.shot}
                    checked={image.shot in @options.search}
                    class="size-4 shrink-0 rounded border-base-300 accent-[var(--color-primary)]"
                  />
                </label>
              </div>
              <p :if={@choices.search == []} class="text-xs text-base-content/50">
                This person has no face probes. Add probe shots to the run to search with them.
              </p>
            </section>

            <section id="compression" class="space-y-3">
              <div>
                <h2 class="text-sm font-semibold">Compression</h2>
                <p class="text-xs text-base-content/60">
                  For fingerprints and palms. Faces are PNG either way: the standard doesn't allow WSQ for faces.
                </p>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <label
                  :for={
                    {value, title, hint, enabled?} <- [
                      {"png", "PNG", "Lossless: the stored images byte for byte", true},
                      {"wsq", "WSQ", "About 15:1, what most AFIS expect at 500 ppi", @wsq?}
                    ]
                  }
                  for={"nist_compression_#{value}"}
                  class={[
                    "flex flex-col gap-1 rounded-xl border border-base-300 p-3 transition",
                    "has-[:checked]:border-primary/60 has-[:checked]:bg-primary/5 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary",
                    if(enabled?,
                      do: "cursor-pointer hover:border-primary/40",
                      else: "cursor-not-allowed opacity-60"
                    )
                  ]}
                >
                  <span class="flex items-center gap-2">
                    <input
                      type="radio"
                      id={"nist_compression_#{value}"}
                      name="nist[compression]"
                      value={value}
                      checked={@options.compression == value}
                      disabled={!enabled?}
                      class="size-4 shrink-0 accent-[var(--color-primary)]"
                    />
                    <span class="text-sm font-medium">{title}</span>
                  </span>
                  <span class="text-xs text-base-content/60">{hint}</span>
                  <span :if={!enabled?} id="wsq-unavailable" class="text-xs text-warning">
                    Needs NIST's cwsq: run <span class="font-mono">python_biometrics/setup.sh</span>
                  </span>
                </label>
              </div>
            </section>
          </.form>

          <div class="space-y-4 lg:sticky lg:top-6">
            <aside
              id="nist-files"
              class="space-y-3 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
            >
              <h2 class="text-sm font-semibold">Files</h2>
              <%= if @export do %>
                <ul class="space-y-2">
                  <li
                    :for={transaction <- @export.transactions}
                    id={"file-#{transaction.name}"}
                    class="rounded-lg bg-base-200/60 px-3 py-2"
                  >
                    <div class="flex items-baseline justify-between gap-2">
                      <span class="truncate font-mono text-xs font-medium">{transaction.filename}</span>
                      <span class="shrink-0 text-[11px] tabular-nums text-base-content/50">
                        ≈ {format_bytes(estimate(transaction, @export.compression))}
                      </span>
                    </div>
                    <p class="mt-0.5 text-xs text-base-content/65">
                      {if transaction.kind == :enrol,
                        do: "Enrolment",
                        else: "Search: #{Shots.label(transaction.probe)}"}
                    </p>
                    <p class="mt-1 text-[11px] text-base-content/50">
                      Type-1, Type-2<span :for={{type, n} <- record_counts(transaction)}>, {n} × Type-{type} {record_name(
                        type
                      )}</span>
                    </p>
                  </li>
                </ul>
                <.link
                  href={download_path(@run, @subject, @options)}
                  id="nist-download"
                  class="flex w-full items-center justify-center gap-1.5 rounded-lg bg-primary px-3 py-2 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110"
                >
                  <.icon name="hero-arrow-down-tray-mini" class="size-4" />
                  Download {if length(@export.transactions) == 1, do: ".an2", else: "ZIP"}
                </.link>
                <button
                  :if={@sharing?}
                  type="button"
                  id="nist-share"
                  phx-click="share"
                  class="flex w-full items-center justify-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium transition hover:bg-base-200 active:scale-[0.98]"
                >
                  <.icon name="hero-link-mini" class="size-4" /> Share as a link
                </button>
                <p class="text-[11px] leading-relaxed text-base-content/50">
                  Every file is marked as synthetic in its Type-2 record, with the subject code in 2.003. {if length(
                                                                                                                @export.transactions
                                                                                                              ) >
                                                                                                                1,
                                                                                                              do:
                                                                                                                "The ZIP adds a README."}
                </p>
              <% else %>
                <p id="nothing" class="text-sm text-base-content/60">
                  Nothing to export with these choices: this person has no images of that kind yet.
                </p>
              <% end %>
            </aside>
            <.share_links :if={@shares != []} shares={@shares} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
