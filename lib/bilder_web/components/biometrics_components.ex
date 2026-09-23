defmodule BilderWeb.BiometricsComponents do
  @moduledoc "UI pieces shared by the synthetic-face LiveViews."

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: BilderWeb.Endpoint,
    router: BilderWeb.Router,
    statics: BilderWeb.static_paths()

  alias Bilder.Biometrics.{FacePrompts, Shots}

  @face_descriptions %{
    "mugshot_frontal" => "Anchor. Generated from the text description.",
    "mugshot_left_profile" => "90°, left side of the face.",
    "mugshot_right_profile" => "90°, right side of the face.",
    "mugshot_three_quarter_left" => "About 45°, towards the left.",
    "mugshot_three_quarter_right" => "About 45°, towards the right.",
    "icao_portrait" => "Passport photo, light background.",
    "probe_rebooking" => "Head turned, harsh light, other clothes.",
    "probe_aged" => "The same person 15 years later.",
    "probe_glasses" => "Glasses, window light, slight smile.",
    "probe_appearance" => "Beard or hairstyle changed."
  }

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

  def image_url(run, subject_id, file), do: ~p"/biometrics-files/#{run}/#{subject_id}/#{file}"

  @doc "The first shot of `shots` without a record in `subject`, i.e. the one rendering next."
  def next_shot(_shots, nil), do: nil

  def next_shot(shots, subject) do
    done = MapSet.new(subject.shots, & &1.shot)
    Enum.find(shots, &(not MapSet.member?(done, &1)))
  end

  @doc "Fraction of a run's images that are done, from a `Runner` progress snapshot."
  def run_fraction(%{total: total, shots: shots, done: done, subject: subject}) do
    per_subject = max(length(shots), 1)
    in_subject = if subject, do: length(subject.shots), else: 0
    min((done * per_subject + in_subject) / max(total * per_subject, 1), 1.0)
  end

  def format_time(unix) when is_integer(unix) and unix > 0 do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  def format_time(_unix), do: "–"

  def format_duration(nil), do: "–"
  def format_duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  def anchor?(shot), do: shot == FacePrompts.anchor_shot()

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
          "border border-error/40 bg-base-100 text-error hover:bg-error/10"
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

  def shot_tile(assigns) do
    spec = Shots.spec(assigns.shot) || %{size: {4, 5}, modality: :face, group: "face"}
    {w, h} = spec.size

    assigns =
      assigns
      |> assign(:record, Enum.find(assigns.subject.shots, &(&1.shot == assigns.shot)))
      |> assign(:aspect, "aspect-ratio: #{w} / #{h}")
      |> assign(:ridge?, spec.modality == :ridge)
      |> assign(:width, tile_width(spec.group, w, h))

    assigns = assign(assigns, :pattern, assigns.record && pattern_code(assigns.record))

    ~H"""
    <figure id={"tile-#{@subject.id}-#{@shot}"} class={["shrink-0", @width]}>
      <%= cond do %>
        <% @record && @record.status in ["ok", "existing"] -> %>
          <.link
            patch={~p"/biometrics/#{@run}?#{[subject: @subject.id, shot: @shot]}"}
            class={[
              "group relative block overflow-hidden rounded-xl ring-1 ring-base-300 transition hover:ring-2 hover:ring-primary focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none",
              if(@ridge?, do: "bg-white", else: "bg-base-200")
            ]}
            style={@aspect}
          >
            <img
              src={image_url(@run, @subject.id, @record.file)}
              alt={"#{shot_label(@shot)} of #{@subject.id}"}
              loading="lazy"
              class={[
                "size-full transition duration-300 group-hover:scale-[1.03]",
                if(@ridge?, do: "object-contain", else: "object-cover")
              ]}
            />
          </.link>
        <% @record -> %>
          <div
            class="flex flex-col items-center justify-center gap-1 rounded-xl bg-error/10 p-2 text-center text-xs text-error ring-1 ring-error/30"
            style={@aspect}
            title={@record.error}
          >
            <span class="font-medium">
              {if @record.status == "skipped", do: "Skipped", else: "Failed"}
            </span>
            <span class="line-clamp-3 text-error/80">{@record.error}</span>
          </div>
        <% @rendering? -> %>
          <div
            class="flex flex-col items-center justify-center gap-2 rounded-xl bg-base-200 text-xs text-base-content/60 ring-1 ring-primary/40"
            style={@aspect}
          >
            <.spinner class="size-5 text-primary" /> Rendering…
          </div>
        <% @active? -> %>
          <div
            class="flex items-center justify-center rounded-xl border border-dashed border-base-300 text-xs text-base-content/40"
            style={@aspect}
          >
            Queued
          </div>
        <% true -> %>
          <div
            class="flex items-center justify-center rounded-xl border border-dashed border-base-300 text-xs text-base-content/40"
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

  # Face shots and full palms are tall, slaps and cards wide: size tiles so rows
  # read well at a glance.
  defp tile_width("face", _w, _h), do: "w-32 sm:w-36"
  defp tile_width("rolled", _w, _h), do: "w-28"
  defp tile_width("slaps", _w, _h), do: "w-48"
  defp tile_width("card", _w, _h), do: "w-48"
  defp tile_width("palms", w, h) when w / h < 0.5, do: "w-16"
  defp tile_width(_group, _w, _h), do: "w-32"

  @pattern_codes %{
    "whorl" => "W",
    "left_loop" => "LL",
    "right_loop" => "RL",
    "arch" => "A",
    "tented_arch" => "TA"
  }

  @doc "Short pattern class of a rolled finger record (W, LL, RL, A, TA), or nil."
  def pattern_code(%{meta: %{"pattern" => pattern}}), do: Map.get(@pattern_codes, pattern)
  def pattern_code(_record), do: nil

  def pattern_name(pattern), do: pattern && String.replace(pattern, "_", " ")

  defp pos(%{pos: pos}, _shot) when is_binary(pos), do: pos
  defp pos(_record, shot), do: (Shots.spec(shot) || %{code: nil}).code
end
