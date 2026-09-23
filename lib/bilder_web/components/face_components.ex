defmodule BilderWeb.FaceComponents do
  @moduledoc "UI pieces shared by the synthetic-face LiveViews."

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: BilderWeb.Endpoint,
    router: BilderWeb.Router,
    statics: BilderWeb.static_paths()

  alias Bilder.Biometrics.FacePrompts

  @shot_info %{
    "mugshot_frontal" => {"Frontal", "Anchor. Generated from the text description."},
    "mugshot_left_profile" => {"Left profile", "90°, left side of the face."},
    "mugshot_right_profile" => {"Right profile", "90°, right side of the face."},
    "mugshot_three_quarter_left" => {"¾ left", "About 45°, towards the left."},
    "mugshot_three_quarter_right" => {"¾ right", "About 45°, towards the right."},
    "icao_portrait" => {"ICAO portrait", "Passport photo, light background."},
    "probe_rebooking" => {"Re-booking", "Head turned, harsh light, other clothes."},
    "probe_aged" => {"Aged +15", "The same person 15 years later."},
    "probe_glasses" => {"Glasses", "Glasses, window light, slight smile."},
    "probe_appearance" => {"Appearance", "Beard or hairstyle changed."}
  }

  def shot_label(shot), do: @shot_info |> Map.get(shot, {shot, ""}) |> elem(0)
  def shot_description(shot), do: @shot_info |> Map.get(shot, {"", ""}) |> elem(1)

  def image_url(run, subject_id, file), do: ~p"/face-files/#{run}/#{subject_id}/#{file}"

  @doc "Seconds per image on the reference 4090 at 40 steps, for rough estimates."
  def seconds_per_image, do: 44

  @doc "The first shot of `shots` without a record in `subject`, i.e. the one rendering next."
  def next_shot(_shots, nil), do: nil

  def next_shot(shots, subject) do
    done = MapSet.new(subject.shots, & &1.shot)
    Enum.find(shots, &(not MapSet.member?(done, &1)))
  end

  @doc "Fraction of a run's images that are done, from a `FaceRunner` progress snapshot."
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

  def pos_badge(assigns) do
    ~H"""
    <span
      class="inline-flex size-5 items-center justify-center rounded bg-base-200 font-mono text-[10px] font-semibold text-base-content/70"
      title="ANSI/NIST-ITL Type-10 pose code"
    >
      {@pos}
    </span>
    """
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
    assigns =
      assign(assigns, :record, Enum.find(assigns.subject.shots, &(&1.shot == assigns.shot)))

    ~H"""
    <figure id={"tile-#{@subject.id}-#{@shot}"} class="w-32 shrink-0 sm:w-36">
      <%= cond do %>
        <% @record && @record.status in ["ok", "existing"] -> %>
          <.link
            patch={~p"/faces/#{@run}?#{[subject: @subject.id, shot: @shot]}"}
            class="group relative block aspect-[4/5] overflow-hidden rounded-xl bg-base-200 ring-1 ring-base-300 transition hover:ring-2 hover:ring-primary focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none"
          >
            <img
              src={image_url(@run, @subject.id, @record.file)}
              alt={"#{shot_label(@shot)} of #{@subject.id}"}
              loading="lazy"
              class="size-full object-cover transition duration-300 group-hover:scale-[1.03]"
            />
          </.link>
        <% @record -> %>
          <div
            class="flex aspect-[4/5] flex-col items-center justify-center gap-1 rounded-xl bg-error/10 p-2 text-center text-xs text-error ring-1 ring-error/30"
            title={@record.error}
          >
            <span class="font-medium">{if @record.status == "skipped", do: "Skipped", else: "Failed"}</span>
            <span class="line-clamp-3 text-error/80">{@record.error}</span>
          </div>
        <% @rendering? -> %>
          <div class="flex aspect-[4/5] flex-col items-center justify-center gap-2 rounded-xl bg-base-200 text-xs text-base-content/60 ring-1 ring-primary/40">
            <.spinner class="size-5 text-primary" /> Rendering…
          </div>
        <% @active? -> %>
          <div class="flex aspect-[4/5] items-center justify-center rounded-xl border border-dashed border-base-300 text-xs text-base-content/40">
            Queued
          </div>
        <% true -> %>
          <div class="flex aspect-[4/5] items-center justify-center rounded-xl border border-dashed border-base-300 text-xs text-base-content/40">
            Not rendered
          </div>
      <% end %>
      <figcaption class="mt-1.5 flex items-center gap-1.5 text-xs text-base-content/70">
        <.pos_badge pos={pos(@record, @shot)} />
        <span class="truncate">{shot_label(@shot)}</span>
      </figcaption>
    </figure>
    """
  end

  defp pos(%{pos: pos}, _shot) when is_binary(pos), do: pos
  defp pos(_record, shot), do: (FacePrompts.spec(shot) || %{pos: "?"}).pos
end
