defmodule PhantomWeb.BiometricsComponents do
  @moduledoc "UI pieces shared by the synthetic-face LiveViews."

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: PhantomWeb.Endpoint,
    router: PhantomWeb.Router,
    statics: PhantomWeb.static_paths()

  import PhantomWeb.CoreComponents, only: [icon: 1]

  alias Phantom.Biometrics.{FacePrompts, Share, Shots}
  alias Phoenix.LiveView.JS

  @face_descriptions %{
    "mugshot_frontal" => "Anchor. Generated from the text description.",
    "mugshot_left_profile" => "90°, left side of the face.",
    "mugshot_right_profile" => "90°, right side of the face.",
    "mugshot_three_quarter_left" => "About 45°, towards the left.",
    "mugshot_three_quarter_right" => "About 45°, towards the right.",
    "icao_portrait" => "Passport photo, light background.",
    "probe_rebooking" => "Booked again: other clothes, expression.",
    "probe_uncooperative" => "Drunk and disorderly: turned away, bleary.",
    "probe_aged" => "The same person 15 years later.",
    "probe_glasses" => "Glasses, window light.",
    "probe_appearance" => "Beard or hairstyle changed.",
    "probe_low_res" => "A small phone snapshot, 240×320."
  }

  # Probes also get a slight head angle and expression of their own (see
  # FacePrompts.variation/2), shown once on the face section.
  @group_descriptions %{
    "rolled" => "10 rolled fingers, FGP 1–10, 800×750",
    "slaps" => "Right four, left four and two thumbs, FGP 13–15",
    "palms" => "Full and writer's palm of both hands, PLP 21–24",
    "card" => "FD-249 style composite of the rolled prints and slaps"
  }

  # Rough seconds per image, for the estimate on the form. Faces: Qwen on the
  # reference RTX 4090 at 40 steps. Ridges: the CPU service on 24 cores; the
  # first image of each finger or palm also builds its master pattern.
  @seconds_per_image %{"face" => 44, "rolled" => 3, "slaps" => 4, "palms" => 14, "card" => 3}

  def shot_label(shot), do: Shots.label(shot)
  def shot_description(shot), do: Map.get(@face_descriptions, shot, "")
  def group_description(group), do: Map.get(@group_descriptions, group, "")

  @doc "Estimated seconds to render one image of `group`."
  def seconds_per_image(group), do: Map.get(@seconds_per_image, group, 5)

  @doc "URL of an image's file."
  def image_url(%{id: id}), do: ~p"/images/#{id}"

  @doc """
  URL of a small WebP copy of an image (at most 640 px), for thumbnails. Full
  images are up to 9 MB (a full palm), too much for a page of tiles.
  """
  def preview_url(%{id: id}), do: ~p"/images/#{id}/preview"

  @doc "URL of an image's ground truth (friction-ridge shots)."
  def ground_truth_url(%{id: id}), do: ~p"/images/#{id}/ground-truth"

  @doc "The first shot of `shots` without a record in `subject`, i.e. the one rendering next."
  def next_shot(_shots, nil), do: nil

  def next_shot(shots, subject) do
    done = MapSet.new(subject.images, & &1.shot)
    Enum.find(shots, &(not MapSet.member?(done, &1)))
  end

  attr :id, :string, default: nil
  attr :status, :atom, required: true
  attr :class, :string, default: "mt-2"

  @doc "A run's status, as a small pill: running (with a spinner), queued, cancelled or failed."
  def run_status(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-medium",
        @class,
        @status == :running && "bg-primary/10 text-primary",
        @status == :failed && "bg-error/10 text-error",
        @status in [:queued, :cancelled] && "bg-base-200 text-base-content/60"
      ]}
    >
      <.spinner :if={@status == :running} class="size-2.5" />
      <.icon :if={@status == :queued} name="hero-clock-mini" class="size-3" />
      {@status}
    </span>
    """
  end

  @doc "Fraction of a run's images that are done, from `Phantom.Biometrics.progress/1`."
  def run_fraction(%{total: total, shots: shots, done: done, subject: subject}) do
    per_subject = max(length(shots), 1)
    in_subject = if subject, do: length(subject.images), else: 0
    min((done * per_subject + in_subject) / max(total * per_subject, 1), 1.0)
  end

  def format_time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")
  def format_time(_time), do: "–"

  @doc "A file size for people: `\"840 KB\"`, `\"37 MB\"`."
  def format_bytes(bytes) when bytes < 1_000_000, do: "#{max(round(bytes / 1000), 1)} KB"
  def format_bytes(bytes) when bytes < 10_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  def format_bytes(bytes), do: "#{round(bytes / 1_000_000)} MB"

  def format_duration(nil), do: "–"
  def format_duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  def anchor?(shot), do: shot == FacePrompts.anchor_shot()

  attr :shares, :list, required: true

  @doc """
  A subject's shared links (`Phantom.Biometrics.Shares`), newest first: each
  upload's progress, then its link with a copy button, when it expires, and
  **New link** while the file is still in the bucket. The LiveView handles
  `renew-share` (`phx-value-id`).
  """
  def share_links(assigns) do
    ~H"""
    <section
      id="share-links"
      class="space-y-2 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
    >
      <div>
        <h2 class="text-sm font-semibold">Shared links</h2>
        <p class="text-xs text-base-content/60">
          Anyone with a link can download that file, without Tailscale, until the link expires.
        </p>
      </div>
      <ul class="divide-y divide-base-300">
        <li :for={share <- @shares} id={"share-#{share.id}"} class="space-y-1.5 py-2.5 last:pb-0">
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
            <span class="min-w-0 truncate font-mono text-xs font-medium">{share.filename}</span>
            <span class="shrink-0 text-[11px] tabular-nums text-base-content/50">
              {if share.byte_size, do: format_bytes(share.byte_size) <> " · "}{format_time(
                share.inserted_at
              )}
            </span>
          </div>
          <.share_state share={share} />
        </li>
      </ul>
    </section>
    """
  end

  attr :share, Share, required: true

  defp share_state(%{share: %Share{status: status}} = assigns)
       when status in [:queued, :uploading] do
    ~H"""
    <p class="flex items-center gap-1.5 text-xs text-base-content/65">
      <.spinner :if={@share.status == :uploading} class="size-3 text-primary" />
      <.icon :if={@share.status == :queued} name="hero-clock-micro" class="size-3.5" />
      {if @share.status == :uploading, do: "Uploading…", else: "Waiting to upload"}
      <span :if={@share.error} class="text-warning">· retrying: {@share.error}</span>
    </p>
    """
  end

  defp share_state(%{share: %Share{status: :failed}} = assigns) do
    ~H"""
    <p class="flex gap-1.5 text-xs text-error">
      <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
      Upload failed: {@share.error}
    </p>
    """
  end

  defp share_state(assigns) do
    assigns =
      assigns
      |> assign(:stored?, Share.stored?(assigns.share))
      |> assign(:valid?, Share.link_valid?(assigns.share))

    ~H"""
    <div :if={@valid?} class="flex gap-1.5">
      <input
        type="text"
        id={"share-url-#{@share.id}"}
        value={@share.url}
        readonly
        aria-label={"Link to #{@share.filename}"}
        class="min-w-0 flex-1 truncate rounded-lg border border-base-300 bg-base-200/60 px-2 py-1 font-mono text-[11px] text-base-content/70 focus:outline-none focus:ring-2 focus:ring-primary/40"
        phx-click={JS.dispatch("phantom:select")}
      />
      <button
        type="button"
        id={"share-copy-#{@share.id}"}
        data-copy-for={"share-url-#{@share.id}"}
        phx-click={JS.dispatch("phantom:copy", to: "#share-url-#{@share.id}")}
        class="group inline-flex shrink-0 items-center gap-1 rounded-lg bg-primary px-2.5 py-1 text-xs font-medium text-primary-content shadow-sm transition hover:brightness-110 active:scale-[0.97]"
      >
        <.icon name="hero-clipboard-document-mini" class="size-3.5 group-data-copied:hidden" />
        <.icon name="hero-check-mini" class="hidden size-3.5 group-data-copied:inline-block" />
        <span class="group-data-copied:hidden">Copy</span>
        <span class="hidden group-data-copied:inline">Copied</span>
      </button>
    </div>
    <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-[11px] text-base-content/55">
      <span :if={@valid?}>
        Link works until {format_date(@share.link_expires_at)} · file deleted {format_date(
          @share.expires_at
        )}
      </span>
      <span :if={@stored? and not @valid?} class="text-warning">
        Link expired · file deleted {format_date(@share.expires_at)}
      </span>
      <span :if={not @stored?}>Deleted from the bucket {format_date(@share.expires_at)}</span>
      <button
        :if={@stored?}
        type="button"
        id={"share-renew-#{@share.id}"}
        phx-click="renew-share"
        phx-value-id={@share.id}
        class="inline-flex items-center gap-1 font-medium text-primary transition hover:underline"
      >
        <.icon name="hero-arrow-path-micro" class="size-3" /> New link
      </button>
    </div>
    """
  end

  defp format_date(%DateTime{} = time), do: Calendar.strftime(time, "%-d %b %H:%M UTC")

  attr :class, :string, default: "size-4"

  def spinner(assigns) do
    ~H"""
    <span
      class={[
        "inline-block shrink-0 animate-spin rounded-full border-2 border-current border-r-transparent",
        @class
      ]}
      aria-hidden="true"
    ></span>
    """
  end

  attr :pos, :string, required: true
  attr :shot, :string, default: nil

  def pos_badge(assigns) do
    ~H"""
    <span
      class="inline-flex h-5 min-w-5 items-center justify-center rounded bg-base-200 px-1 font-mono text-[10px] font-semibold text-base-content/70"
      title={code_title(@shot)}
    >
      {@pos}
    </span>
    """
  end

  defp code_title(shot) do
    case Shots.spec(shot || "") do
      %{group: "palms"} -> "ANSI/NIST-ITL Type-15 palm position (PLP)"
      %{modality: :ridge} -> "ANSI/NIST-ITL Type-14 finger position (FGP)"
      _ -> "ANSI/NIST-ITL Type-10 subject pose"
    end
  end

  attr :value, :float, required: true
  attr :id, :string, default: nil

  def progress_bar(assigns) do
    ~H"""
    <div
      id={@id}
      class="h-1.5 w-full overflow-hidden rounded-full bg-base-200"
      role="progressbar"
      aria-valuenow={round(@value * 100)}
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <div
        class="h-full rounded-full bg-primary transition-[width] duration-700 ease-out"
        style={"width: #{Float.round(@value * 100, 1)}%"}
      >
      </div>
    </div>
    """
  end

  attr :variant, :string, default: "secondary", values: ~w(primary secondary danger)
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(type disabled form name value)
  slot :inner_block, required: true

  def action_button(assigns) do
    ~H"""
    <button
      class={[
        "inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium shadow-sm transition",
        "active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100",
        @variant == "primary" && "bg-primary text-primary-content hover:brightness-110",
        @variant == "secondary" &&
          "border border-base-300 bg-base-100 text-base-content hover:bg-base-200",
        @variant == "danger" &&
          "border border-error/40 bg-base-100 text-error hover:bg-error/10",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  One shot of a subject: the thumbnail when rendered, otherwise its state
  (rendering, queued, failed).
  """
  attr :run, :string, required: true
  attr :subject, :map, required: true
  attr :shot, :string, required: true
  attr :rendering?, :boolean, default: false
  attr :active?, :boolean, default: false, doc: "whether this subject is still being rendered"
  attr :focused?, :boolean, default: false, doc: "whether the page shows this subject only"

  def shot_tile(assigns) do
    spec = Shots.spec(assigns.shot) || %{size: {4, 5}, modality: :face, group: "face"}
    {w, h} = spec.size

    assigns =
      assigns
      |> assign(:record, Enum.find(assigns.subject.images, &(&1.shot == assigns.shot)))
      |> assign(:aspect, "aspect-ratio: #{w} / #{h}")
      |> assign(:ridge?, spec.modality == :ridge)
      |> assign(:width, tile_width(spec.group, w, h))
      |> assign(:box, image_width(spec.group, w, h))

    assigns =
      assigns
      |> assign(:pattern, assigns.record && pattern_code(assigns.record))
      |> assign(:check, assigns.record && verification(assigns.record))

    ~H"""
    <figure id={"tile-#{@subject.name}-#{@shot}"} class={["shrink-0", @width]}>
      <%= cond do %>
        <% @record && @record.status == :ok -> %>
          <.link
            patch={shot_path(@run, @subject.name, @shot, @focused?)}
            class={[
              "group relative block overflow-hidden rounded-xl ring-1 transition hover:ring-2 hover:ring-primary focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
              @box,
              if(@check && @check["accepted"] == false, do: "ring-error/60", else: "ring-base-300"),
              if(@ridge?, do: "bg-white", else: "bg-base-200")
            ]}
            style={@aspect}
          >
            <img
              src={preview_url(@record)}
              alt={"#{shot_label(@shot)} of #{@subject.name}"}
              loading="lazy"
              class={[
                "size-full text-transparent transition duration-300 group-hover:scale-[1.03]",
                if(@ridge?, do: "object-contain", else: "object-cover")
              ]}
            />
            <.verification_chip :if={@check} check={@check} />
          </.link>
        <% @record -> %>
          <div
            class={[
              "flex flex-col items-center justify-center gap-1 rounded-xl bg-error/10 p-2 text-center text-xs text-error ring-1 ring-error/30",
              @box
            ]}
            style={@aspect}
            title={@record.error}
          >
            <span class="font-medium">
              {if @record.status == :skipped, do: "Skipped", else: "Failed"}
            </span>
            <span class="line-clamp-3 text-error/80">{@record.error}</span>
          </div>
        <% @rendering? -> %>
          <div
            class={[
              "flex flex-col items-center justify-center gap-2 rounded-xl bg-base-200 text-xs text-base-content/60 ring-1 ring-primary/40",
              @box
            ]}
            style={@aspect}
          >
            <.spinner class="size-5 text-primary" /> Rendering…
          </div>
        <% @active? -> %>
          <div
            class={[
              "flex items-center justify-center rounded-xl border border-dashed border-base-300 text-xs text-base-content/40",
              @box
            ]}
            style={@aspect}
          >
            Queued
          </div>
        <% true -> %>
          <div
            class={[
              "flex items-center justify-center rounded-xl border border-dashed border-base-300 text-xs text-base-content/40",
              @box
            ]}
            style={@aspect}
          >
            Not rendered
          </div>
      <% end %>
      <figcaption class="mt-1.5 flex items-center gap-1.5 text-xs text-base-content/70">
        <.pos_badge :if={pos(@record, @shot)} pos={pos(@record, @shot)} shot={@shot} />
        <span class="truncate">{shot_label(@shot)}</span>
        <span
          :if={@pattern}
          class="ml-auto font-mono text-[10px] text-base-content/50"
          title="Pattern class"
        >
          {@pattern}
        </span>
      </figcaption>
    </figure>
    """
  end

  @doc """
  The detail view of one shot: on the run page, or on the subject's own page
  (`/biometrics/:run/:subject`) when `focused?`.
  """
  def shot_path(run, subject_id, shot, focused? \\ false)

  def shot_path(run, subject_id, shot, true),
    do: ~p"/biometrics/#{run}/#{subject_id}?#{[shot: shot]}"

  def shot_path(run, subject_id, shot, false),
    do: ~p"/biometrics/#{run}?#{[subject: subject_id, shot: shot]}"

  # Face shots and full palms are tall, slaps and cards wide: size tiles so rows
  # read well at a glance.
  defp tile_width("face", _w, _h), do: "w-32 sm:w-36"
  defp tile_width("rolled", _w, _h), do: "w-28"
  defp tile_width("slaps", _w, _h), do: "w-48"
  defp tile_width("card", _w, _h), do: "w-48"
  defp tile_width(_group, _w, _h), do: "w-32"

  # Writer's palms are narrow: their image is half a full palm's width, so it's
  # as tall, in a tile as wide, so the label ("R writer's palm") fits.
  defp image_width("palms", w, h) when w / h < 0.5, do: "w-16"
  defp image_width(_group, _w, _h), do: nil

  @pattern_codes %{
    "whorl" => "W",
    "left_loop" => "LL",
    "right_loop" => "RL",
    "arch" => "A",
    "tented_arch" => "TA"
  }

  @doc "Short pattern class of a rolled finger record (W, LL, RL, A, TA), or nil."
  def pattern_code(%{meta: %{"pattern" => pattern}}), do: pattern_abbrev(pattern)
  def pattern_code(_record), do: nil

  @doc "Short form of a pattern class (`\"whorl\"` -> `\"W\"`), or nil."
  def pattern_abbrev(pattern), do: Map.get(@pattern_codes, pattern)

  def pattern_name(pattern), do: pattern && String.replace(pattern, "_", " ")

  defp pos(%{pos: pos}, _shot) when is_binary(pos), do: pos
  defp pos(_record, shot), do: (Shots.spec(shot) || %{code: nil}).code

  @doc "A friction-ridge record's verification summary (NFIQ 2, minutiae recall, ...), or nil."
  def verification(%{meta: %{"verification" => %{} = check}}), do: check
  def verification(_record), do: nil

  @doc "`:accepted`, `:retried` (accepted after re-rendering) or `:rejected`."
  def verification_status(%{"accepted" => false}), do: :rejected
  def verification_status(%{"attempts" => attempts}) when attempts > 1, do: :retried
  def verification_status(_check), do: :accepted

  def percent(nil), do: "–"
  def percent(ratio), do: "#{round(ratio * 100)}%"

  def number(nil), do: "–"
  def number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  def number(value), do: to_string(value)

  attr :check, :map, required: true

  @doc "NFIQ 2 and verification state, overlaid on a friction-ridge thumbnail."
  def verification_chip(assigns) do
    assigns = assign(assigns, :status, verification_status(assigns.check))

    ~H"""
    <span
      class={[
        "absolute left-1.5 top-1.5 inline-flex items-center gap-0.5 rounded-md px-1.5 py-0.5 font-mono text-[10px] font-semibold shadow-sm ring-1 backdrop-blur-sm",
        @status == :rejected && "bg-error text-error-content ring-error",
        @status == :retried && "bg-base-100/90 text-base-content ring-warning/60",
        @status == :accepted && "bg-base-100/90 text-base-content/70 ring-base-300"
      ]}
      title={chip_title(@check, @status)}
    >
      <.icon :if={@status == :rejected} name="hero-x-circle-mini" class="size-3" />
      <.icon :if={@status == :retried} name="hero-arrow-path-mini" class="size-3 text-warning" />
      {@check["nfiq2"] || "–"}
    </span>
    """
  end

  defp chip_title(check, status) do
    state =
      case status do
        :rejected -> "Rejected after #{check["attempts"]} attempts"
        :retried -> "Accepted on attempt #{check["attempts"]}"
        :accepted -> "Accepted"
      end

    "#{state} · NFIQ 2 #{check["nfiq2"] || "–"} · minutiae recall #{percent(check["minutiae_recall"])}"
  end

  attr :check, :map, required: true
  attr :ground_truth_url, :string, default: nil

  @doc "The verification section of the shot detail view."
  def verification_details(assigns) do
    assigns = assign(assigns, :status, verification_status(assigns.check))

    ~H"""
    <div id="verification" class="space-y-2 text-xs">
      <div class="flex items-center justify-between gap-2">
        <h3 class="font-medium text-base-content/50">Verification</h3>
        <span
          id="verification-status"
          class={[
            "inline-flex items-center gap-1 rounded-full px-2 py-0.5 font-medium",
            @status == :accepted && "bg-success/15 text-base-content",
            @status == :retried && "bg-warning/15 text-base-content",
            @status == :rejected && "bg-error/15 text-base-content"
          ]}
        >
          <.icon
            name={
              case @status do
                :accepted -> "hero-check-circle-mini"
                :retried -> "hero-arrow-path-mini"
                :rejected -> "hero-x-circle-mini"
              end
            }
            class={[
              "size-3.5",
              @status == :accepted && "text-success",
              @status == :retried && "text-warning",
              @status == :rejected && "text-error"
            ]}
          />
          {case @status do
            :accepted -> "Accepted"
            :retried -> "Accepted on attempt #{@check["attempts"]}"
            :rejected -> "Rejected"
          end}
        </span>
      </div>
      <dl class="grid grid-cols-2 gap-x-4 gap-y-2">
        <dt class="text-base-content/50">NFIQ 2</dt>
        <dd class="font-mono">{@check["nfiq2"] || "–"}</dd>
        <dt class="text-base-content/50" title="Share of the clean map's minutiae found in the image">
          Minutiae recall
        </dt>
        <dd class="font-mono">{percent(@check["minutiae_recall"])}</dd>
        <dt class="text-base-content/50" title="Share of the image's minutiae not in the clean map">
          Spurious minutiae
        </dt>
        <dd class="font-mono">{percent(@check["minutiae_spurious"])}</dd>
        <dt class="text-base-content/50">Mean displacement</dt>
        <dd class="font-mono">{number(@check["mean_displacement_px"])} px</dd>
        <dt class="text-base-content/50">Renderer</dt>
        <dd>{@check["renderer"]}</dd>
        <dt class="text-base-content/50">Attempts</dt>
        <dd>{@check["attempts"] || 1}</dd>
      </dl>
      <table :if={@check["fingers"]} class="w-full text-left">
        <thead class="text-base-content/50">
          <tr>
            <th class="py-1 font-normal">Finger</th>
            <th class="py-1 text-right font-normal">NFIQ 2</th>
            <th class="py-1 text-right font-normal">Recall</th>
            <th class="py-1 text-right font-normal">Spurious</th>
          </tr>
        </thead>
        <tbody class="font-mono">
          <tr :for={finger <- @check["fingers"]} class="border-t border-base-200">
            <td class="py-1 font-sans">{finger_label(finger["fgp"])}</td>
            <td class="py-1 text-right">{finger["nfiq2"] || "–"}</td>
            <td class="py-1 text-right">{percent(finger["minutiae_recall"])}</td>
            <td class="py-1 text-right">{percent(finger["minutiae_spurious"])}</td>
          </tr>
        </tbody>
      </table>
      <p class="text-base-content/50">
        Minutiae found by NIST mindtct in the image, compared with the clean ridge map it was
        rendered from. The ground-truth JSON lists the missed and spurious points.
      </p>
    </div>
    """
  end

  defp finger_label(fgp) when is_integer(fgp),
    do: Shots.label("rolled_" <> String.pad_leading(Integer.to_string(fgp), 2, "0"))

  defp finger_label(_fgp), do: "–"

  attr :report, :map, required: true

  @doc """
  A run's friction-ridge quality report (see `Phantom.Biometrics.Report`):
  verification outcomes, NFIQ 2 and recall per impression type, and bozorth3
  mated against non-mated scores.
  """
  def quality_report(assigns) do
    report = assigns.report
    verification = report["verification"] || %{}

    assigns =
      assigns
      |> assign(:verification, verification)
      |> assign(:impressions, Enum.sort(verification["by_impression"] || %{}))
      |> assign(:matching, report["matching"])
      |> assign(:threshold, report["threshold"] || 40)

    ~H"""
    <section
      id="quality-report"
      class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
      aria-labelledby="quality-report-title"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 id="quality-report-title" class="text-sm font-semibold">Friction-ridge quality</h2>
        <p class="text-xs text-base-content/50">
          NFIQ 2 · minutiae checked against the clean ridge map · bozorth3 match threshold {@threshold}
        </p>
      </div>

      <div class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <.stat_tile id="report-verified" label="Verified" value={@verification["verified"]} />
        <.stat_tile
          id="report-accepted"
          label="Accepted"
          value={@verification["accepted"]}
          icon="hero-check-circle-mini"
          tone="text-success"
        />
        <.stat_tile
          id="report-retried"
          label="Accepted after retry"
          value={@verification["retried"]}
          icon="hero-arrow-path-mini"
          tone="text-warning"
        />
        <.stat_tile
          id="report-rejected"
          label="Rejected"
          value={@verification["rejected"]}
          icon="hero-x-circle-mini"
          tone="text-error"
        />
      </div>

      <div class="mt-4 grid gap-6 lg:grid-cols-2">
        <div class="overflow-x-auto">
          <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-base-content/50">
            Per impression
          </h3>
          <table id="report-impressions" class="w-full text-left text-xs">
            <thead class="text-base-content/50">
              <tr>
                <th class="py-1 pr-3 font-normal">Impression</th>
                <th class="py-1 pr-3 text-right font-normal">Images</th>
                <th class="py-1 pr-3 text-right font-normal">NFIQ 2 mean</th>
                <th class="py-1 pr-3 text-right font-normal">range</th>
                <th class="py-1 pr-3 text-right font-normal">Recall</th>
                <th class="py-1 text-right font-normal">Spurious</th>
              </tr>
            </thead>
            <tbody class="font-mono">
              <tr :for={{impression, row} <- @impressions} class="border-t border-base-200">
                <td class="py-1.5 pr-3 font-sans capitalize">{impression}</td>
                <td class="py-1.5 pr-3 text-right">{row["count"]}</td>
                <td class="py-1.5 pr-3 text-right">{number(row["nfiq2"]["mean"])}</td>
                <td class="py-1.5 pr-3 text-right text-base-content/60">
                  {row["nfiq2"]["min"] || "–"}–{row["nfiq2"]["max"] || "–"}
                </td>
                <td class="py-1.5 pr-3 text-right">{percent(row["minutiae_recall"]["mean"])}</td>
                <td class="py-1.5 text-right">{percent(row["minutiae_spurious"]["mean"])}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div id="report-matching">
          <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-base-content/50">
            Mated vs non-mated (rolled)
          </h3>
          <%= cond do %>
            <% is_nil(@matching) -> %>
              <p class="text-xs text-base-content/60">
                Needs rolled fingers from two or more captures (mated) or subjects (non-mated).
              </p>
            <% @matching["error"] -> %>
              <p class="text-xs text-error">{@matching["error"]}</p>
            <% true -> %>
              <.score_strip
                matching={@matching}
                threshold={@threshold}
                scale={score_scale(@matching, @threshold)}
              />
              <p class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-base-content/70">
                <span id="report-false-non-matches">
                  <.icon
                    name={
                      if(@matching["false_non_matches"] > 0,
                        do: "hero-exclamation-triangle-mini",
                        else: "hero-check-circle-mini"
                      )
                    }
                    class={[
                      "size-3.5 align-[-2px]",
                      if(@matching["false_non_matches"] > 0,
                        do: "text-warning",
                        else: "text-success"
                      )
                    ]}
                  />
                  {@matching["false_non_matches"]} mated below {@threshold}
                </span>
                <span id="report-false-matches">
                  <.icon
                    name={
                      if(@matching["false_matches"] > 0,
                        do: "hero-exclamation-triangle-mini",
                        else: "hero-check-circle-mini"
                      )
                    }
                    class={[
                      "size-3.5 align-[-2px]",
                      if(@matching["false_matches"] > 0, do: "text-warning", else: "text-success")
                    ]}
                  />
                  {@matching["false_matches"]} non-mated at or above {@threshold}
                </span>
              </p>
              <details
                :if={@matching["collisions"] != [] or @matching["weak_mates"] != []}
                class="mt-2 text-xs"
              >
                <summary class="cursor-pointer text-base-content/60 transition hover:text-base-content">
                  Pairs on the wrong side of the threshold
                </summary>
                <ul class="mt-1 space-y-0.5 font-mono text-base-content/70">
                  <li :for={pair <- @matching["collisions"] || []}>
                    non-mated {pair["a"]} × {pair["b"]}: {pair["score"]}
                  </li>
                  <li :for={pair <- @matching["weak_mates"] || []}>
                    mated {pair["a"]} × {pair["b"]}: {pair["score"]}
                  </li>
                </ul>
              </details>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :icon, :string, default: nil
  attr :tone, :string, default: nil

  defp stat_tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl bg-base-200/60 px-3 py-2">
      <p class="flex items-center gap-1 text-xs text-base-content/60">
        <.icon :if={@icon} name={@icon} class={["size-3.5", @tone]} />
        {@label}
      </p>
      <p class="mt-0.5 font-mono text-xl font-semibold tabular-nums">{@value || 0}</p>
    </div>
    """
  end

  attr :matching, :map, required: true
  attr :threshold, :integer, required: true
  attr :scale, :integer, required: true

  # Two range bars (min to max, with the median marked) on one score axis, and
  # the match threshold as a dashed line across both.
  defp score_strip(assigns) do
    ~H"""
    <div class="relative space-y-2" role="img" aria-label={strip_label(@matching)}>
      <.score_range
        :for={
          {key, label, tone} <- [
            {"mated", "Mated", "bg-primary"},
            {"non_mated", "Non-mated", "bg-base-content/40"}
          ]
        }
        label={label}
        stats={@matching[key]}
        scale={@scale}
        tone={tone}
      />
      <div
        class="pointer-events-none absolute inset-y-0 border-l border-dashed border-base-content/50"
        style={"left: calc(6.5rem + (100% - 12.5rem) * #{Float.round(@threshold / @scale, 4)})"}
        title={"Threshold #{@threshold}"}
      >
      </div>
      <div class="flex justify-between pl-[6.5rem] pr-24 font-mono text-[10px] text-base-content/40">
        <span>0</span><span>{@scale}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :stats, :map, required: true
  attr :scale, :integer, required: true
  attr :tone, :string, required: true

  defp score_range(assigns) do
    ~H"""
    <div
      class="flex items-center text-xs"
      title={"#{@label}: #{@stats["count"]} pairs, min #{@stats["min"]}, median #{@stats["median"]}, max #{@stats["max"]}"}
    >
      <span class="w-[6.5rem] shrink-0 text-base-content/70">
        {@label} <span class="text-base-content/40">({@stats["count"]})</span>
      </span>
      <div class="relative h-4 flex-1 rounded bg-base-200">
        <%= if @stats["count"] > 0 do %>
          <div
            class={["absolute inset-y-1 rounded", @tone]}
            style={"left: #{pct(@stats["min"], @scale)}; width: max(3px, #{pct(@stats["max"] - @stats["min"], @scale)})"}
          >
          </div>
          <div
            class="absolute inset-y-0 w-0.5 rounded bg-base-content"
            style={"left: #{pct(@stats["median"], @scale)}"}
          >
          </div>
        <% end %>
      </div>
      <span class="w-24 shrink-0 text-right font-mono text-base-content/70">
        <%= if @stats["count"] > 0 do %>
          {@stats["min"]}–{@stats["max"]}
        <% else %>
          –
        <% end %>
      </span>
    </div>
    """
  end

  defp pct(value, scale), do: "#{Float.round(min(value / scale, 1.0) * 100, 2)}%"

  defp score_scale(matching, threshold) do
    top =
      Enum.max([threshold * 2 | Enum.map(["mated", "non_mated"], &(matching[&1]["max"] || 0))])

    # Round up to a tidy number for the axis end label.
    step = if top > 200, do: 100, else: 20
    div(top + step - 1, step) * step
  end

  defp strip_label(matching) do
    "Mated scores #{matching["mated"]["min"]} to #{matching["mated"]["max"]}, " <>
      "non-mated #{matching["non_mated"]["min"]} to #{matching["non_mated"]["max"]}"
  end
end
