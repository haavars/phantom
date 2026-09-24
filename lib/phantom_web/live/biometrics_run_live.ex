defmodule PhantomWeb.BiometricsRunLive do
  @moduledoc """
  One synthetic-biometrics run: every subject with its face and friction-ridge
  shots, filled in live while the run is active, plus a detail view
  (`?subject=...&shot=...`) with the full image and its prompt or ground truth.
  A run that isn't rendering can be resumed when a subject is missing an
  image (not rendered, failed, or its file deleted), and can get more shots.
  Each subject downloads as a ZIP (`PhantomWeb.DownloadController`), and each
  image on its own from the detail view.

  `/biometrics/:run/:subject` shows one subject (one synthetic identity) on its
  own, with every image of it; the detail view there is `?shot=...`.
  """

  use PhantomWeb, :live_view

  import PhantomWeb.BiometricsComponents

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{FacePrompts, Gallery, Run, Shots, Traits}

  @impl true
  def mount(%{"run" => name} = params, _session, socket) do
    if connected?(socket), do: Biometrics.subscribe()
    focus = if socket.assigns.live_action == :subject, do: params["subject"]

    with {:ok, run} <- Biometrics.get_run(name),
         focused = focus && Enum.find(run.subjects, &(&1.name == focus)),
         {:subject, true} <- {:subject, is_nil(focus) or not is_nil(focused)} do
      socket =
        socket
        |> assign(:page_title, if(focused, do: Gallery.code(focused.seed), else: name))
        |> assign(:focus, focus)
        |> assign(:focused, focused)
        |> assign(:selected, nil)
        |> assign(:adding?, false)
        |> assign(:add_form, to_form(%{}, as: :add))
        |> assign(:add_error, nil)
        |> assign_run(run)
        |> stream_configure(:subjects, dom_id: &"subjects-#{&1.name}")
        |> stream(:subjects, in_focus(run.subjects, focus))

      {:ok, socket}
    else
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Run #{name} not found.")
         |> push_navigate(to: ~p"/biometrics")}

      {:subject, false} ->
        {:ok,
         socket
         |> put_flash(:error, "Subject #{focus} not found in #{name}.")
         |> push_navigate(to: ~p"/biometrics/#{name}")}
    end
  end

  # The run without its subjects (they're streamed), where it is if it's
  # rendering, and otherwise which subjects are missing images (which looks
  # for every image's file) and which shots it could still get.
  defp assign_run(socket, %Run{} = run) do
    active? = Run.active?(run)

    socket
    |> assign(:run, %{run | subjects: []})
    |> assign(:progress, if(run.status == :running, do: Biometrics.progress(run)))
    |> assign(:incomplete, if(active?, do: [], else: Biometrics.incomplete_positions(run)))
    |> assign(:addable, addable(run))
    |> then(&if(active?, do: assign(&1, :adding?, false), else: &1))
  end

  # Face shots the run doesn't have, and friction-ridge groups it doesn't have
  # every shot of.
  defp addable(run) do
    groups =
      for {group, name} <- Shots.ridge_groups(),
          {:ok, ids} = Shots.expand([group], run.captures),
          not Enum.all?(ids, &(&1 in run.shots)),
          do: {group, name}

    %{faces: FacePrompts.shots() -- run.shots, groups: groups}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected, select(socket, params))}
  end

  defp select(socket, %{"subject" => subject_name, "shot" => shot}) do
    with {:ok, subject} <- Biometrics.get_subject(socket.assigns.run.name, subject_name),
         %{status: :ok} = record <- Enum.find(subject.images, &(&1.shot == shot)) do
      rendered = for %{status: :ok, shot: shot} <- subject.images, do: shot
      index = Enum.find_index(rendered, &(&1 == shot))

      %{
        subject: subject,
        record: record,
        prev: if(index > 0, do: Enum.at(rendered, index - 1)),
        next: Enum.at(rendered, index + 1)
      }
    else
      _ -> nil
    end
  end

  defp select(_socket, _params), do: nil

  @impl true
  def handle_event("resume", _params, socket) do
    {:ok, run} = Biometrics.resume_run(socket.assigns.run)
    {:noreply, assign_run(socket, run)}
  end

  def handle_event("toggle-add-shots", _params, socket) do
    {:noreply, socket |> update(:adding?, &(not &1)) |> assign(:add_error, nil)}
  end

  def handle_event("add-shots", params, socket) do
    shots = params |> get_in(["add", "shots"]) |> List.wrap() |> Enum.reject(&(&1 == ""))

    case Biometrics.add_shots(socket.assigns.run, shots) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(adding?: false, add_error: nil)
         |> assign_run(run)
         |> reload()
         |> put_flash(:info, "Added #{Enum.map_join(shots, ", ", &shot_or_group_name/1)}.")}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :add_error, message)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :add_error, "Couldn't queue the run.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:ok, run} = Biometrics.cancel_run(socket.assigns.run)
    {:noreply, assign_run(socket, run)}
  end

  def handle_event(
        "lightbox-key",
        %{"key" => key},
        %{assigns: %{selected: %{} = selected}} = socket
      ) do
    target =
      case key do
        "Escape" -> :close
        "ArrowLeft" -> selected.prev
        "ArrowRight" -> selected.next
        _ -> nil
      end

    case target do
      nil ->
        {:noreply, socket}

      :close ->
        {:noreply, push_patch(socket, to: page_path(socket.assigns.run, socket.assigns.focus))}

      shot ->
        {:noreply,
         push_patch(socket,
           to:
             shot_path(
               socket.assigns.run.name,
               selected.subject.name,
               shot,
               !!socket.assigns.focus
             )
         )}
    end
  end

  def handle_event("lightbox-key", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:run_updated, %Run{id: id} = run}, %{assigns: %{run: %{id: id}}} = socket) do
    previous = socket.assigns.run.status
    socket = assign_run(socket, run)

    socket =
      if run.status != previous and run.status in [:finished, :cancelled, :failed],
        do: socket |> reload() |> flash_outcome(run),
        else: socket

    {:noreply, socket}
  end

  def handle_info(
        {:subject_updated, %{run_id: id} = subject},
        %{assigns: %{run: %{id: id}}} = socket
      ) do
    socket =
      socket
      |> insert_subject(subject)
      |> assign_run(socket.assigns.run)
      |> then(&if(&1.assigns.focus == subject.name, do: assign(&1, :focused, subject), else: &1))

    {:noreply, socket}
  end

  # Another run's events.
  def handle_info({event, _record}, socket) when event in [:run_updated, :subject_updated],
    do: {:noreply, socket}

  # Re-read the run's subjects, e.g. to drop a half-rendered subject's state after a cancel.
  defp reload(socket) do
    case Biometrics.get_run(socket.assigns.run.name) do
      {:ok, run} ->
        socket
        |> stream(:subjects, in_focus(run.subjects, socket.assigns.focus), reset: true)

      {:error, :not_found} ->
        socket
    end
  end

  defp flash_outcome(socket, %Run{status: :finished}),
    do: put_flash(socket, :info, "Run finished.")

  defp flash_outcome(socket, %Run{status: :cancelled}),
    do: put_flash(socket, :info, "Run cancelled. Resume to render the rest.")

  defp flash_outcome(socket, %Run{status: :failed, error: error}),
    do: put_flash(socket, :error, "Run failed: #{error}")

  defp resumable?(run, incomplete), do: not Run.active?(run) and incomplete != []

  defp can_add_shots?(run, addable),
    do: not Run.active?(run) and (addable.faces != [] or addable.groups != [])

  defp shot_or_group_name(shot) do
    case List.keyfind(Shots.ridge_groups(), shot, 0) do
      {_group, name} -> String.downcase(name)
      nil -> shot_label(shot)
    end
  end

  defp subjects_count(1), do: "1 subject"
  defp subjects_count(n), do: "#{n} subjects"

  defp active_subject_id(%{subject: %{name: name}}), do: name
  defp active_subject_id(_progress), do: nil

  # Tiles are grouped into sections: Face, Rolled fingers, Slaps, ... with a
  # section per extra capture.
  defp sections(shots) do
    shots
    |> Enum.chunk_by(fn shot ->
      spec = Shots.spec(shot) || %{group: "other", capture: 0}
      {spec.group, spec.capture}
    end)
    |> Enum.map(fn [first | _] = group_shots ->
      spec = Shots.spec(first) || %{group: "other", capture: 0}
      title = Shots.group_name(spec.group)
      title = if spec.capture > 0, do: "#{title} · capture #{spec.capture + 1}", else: title
      {"#{spec.group}-#{spec.capture}", title, group_shots}
    end)
  end

  defp singular_points(meta) do
    cores = length(meta["cores"] || [])
    deltas = length(meta["deltas"] || [])
    "#{cores} core#{if cores != 1, do: "s"}, #{deltas} delta#{if deltas != 1, do: "s"}"
  end

  defp in_focus(subjects, nil), do: subjects
  defp in_focus(subjects, focus), do: Enum.filter(subjects, &(&1.name == focus))

  defp insert_subject(socket, subject) do
    if socket.assigns.focus in [nil, subject.name],
      do: stream_insert(socket, :subjects, subject),
      else: socket
  end

  # Where the detail view closes to: the run, or the focused subject.
  defp page_path(run, nil), do: ~p"/biometrics/#{run.name}"
  defp page_path(run, focus), do: ~p"/biometrics/#{run.name}/#{focus}"

  defp sex_age(attributes) do
    sex =
      case attributes["sex"] do
        "female" -> "Female"
        "male" -> "Male"
        other -> other
      end

    [sex, attributes["age"] && "#{attributes["age"]} years"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp sentence(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  attr :run, :map, required: true
  attr :subject, :map, required: true

  # Download this person as a ZIP: everything, faces only, or prints only,
  # with what each holds.
  defp download_menu(assigns) do
    summary = Biometrics.download_summary(assigns.subject)

    assigns =
      assigns
      |> assign(:partial?, is_nil(assigns.subject.completed_at))
      |> assign(:options, [
        {"all", "Everything", "Faces, prints, palms, card and ground truth", summary["all"]},
        {"faces", "Faces", "Mugshots, ICAO portrait and probes", summary["faces"]},
        {"prints", "Fingerprints and palms", "With the tenprint card and ground truth",
         summary["prints"]}
      ])

    ~H"""
    <div id="download" class="relative">
      <button
        type="button"
        id="download-toggle"
        phx-click={
          JS.toggle(to: "#download-menu") |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
        aria-expanded="false"
        aria-controls="download-menu"
        aria-haspopup="true"
        class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110"
      >
        <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Download
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-70" />
      </button>
      <div
        id="download-menu"
        class="absolute left-0 z-20 mt-2 hidden w-80 max-w-[calc(100vw-3rem)] rounded-xl border border-base-300 bg-base-100 p-1.5 shadow-lg sm:right-0 sm:left-auto"
        phx-click-away={
          JS.hide(to: "#download-menu")
          |> JS.set_attribute({"aria-expanded", "false"}, to: "#download-toggle")
        }
        phx-window-keydown={
          JS.hide(to: "#download-menu")
          |> JS.set_attribute({"aria-expanded", "false"}, to: "#download-toggle")
        }
        phx-key="Escape"
      >
        <%= for {include, title, hint, %{files: files, bytes: bytes}} <- @options, files > 0 do %>
          <a
            id={"download-#{include}"}
            href={~p"/biometrics/#{@run.name}/#{@subject.name}/download?#{[include: include]}"}
            class="flex items-start justify-between gap-3 rounded-lg px-3 py-2 transition hover:bg-base-200"
          >
            <span class="min-w-0">
              <span class="block text-sm font-medium">{title}</span>
              <span class="block text-xs text-base-content/60">{hint}</span>
            </span>
            <span class="shrink-0 pt-0.5 text-right text-xs tabular-nums text-base-content/55">
              {files} {if files == 1, do: "image", else: "images"}<br />{format_bytes(bytes)}
            </span>
          </a>
        <% end %>
        <p
          :if={@partial?}
          class="mx-1 mt-1 flex gap-1.5 border-t border-base-300 px-2 pt-2 text-xs text-warning"
        >
          <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
          Still rendering: the download has the images so far.
        </p>
        <p class="mx-1 mt-1 border-t border-base-300 px-2 pt-2 pb-1 text-[11px] text-base-content/50">
          ZIP with PNG images, a subject.json manifest (seeds, prompts, SHA-256) and a README.
        </p>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :subject, :map, required: true

  # The focused page's header: who this synthetic person is, and where they came from.
  defp identity_header(assigns) do
    assigns =
      assigns
      |> assign(:attributes, Map.get(assigns.subject, :attributes) || %{})
      |> assign(
        :images,
        Enum.count(assigns.subject.images, &(&1.status == :ok))
      )

    ~H"""
    <div id="identity-header" class="space-y-4">
      <nav class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-base-content/60">
        <.link
          navigate={~p"/#gallery"}
          id="back-to-gallery"
          class="transition hover:text-base-content"
        >
          ← Gallery
        </.link>
        <span class="text-base-content/30">/</span>
        <.link
          navigate={~p"/biometrics/#{@run.name}"}
          id="back-to-run"
          class="font-mono transition hover:text-base-content"
        >
          {@run.name}
        </.link>
      </nav>
      <div class="flex flex-wrap items-start justify-between gap-4 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
        <div class="min-w-0 max-w-3xl">
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="font-mono text-2xl font-semibold tracking-wide">
              {Gallery.code(@subject.seed)}
            </h1>
            <span class="rounded bg-base-content px-1.5 py-0.5 text-[10px] font-bold tracking-[0.15em] text-base-100">
              SYNTHETIC
            </span>
            <span :if={sex_age(@attributes) != ""} class="text-sm text-base-content/60">
              {sex_age(@attributes)}
            </span>
          </div>
          <p :if={@subject.description} class="mt-2 text-sm leading-relaxed text-base-content/75">
            {sentence(@subject.description)}
          </p>
        </div>
        <div class="flex flex-col items-start gap-4 sm:items-end">
          <dl class="grid grid-cols-3 gap-x-6 gap-y-1 text-sm">
            <div>
              <dt class="text-xs text-base-content/50">Images</dt>
              <dd class="font-mono font-semibold">{@images}</dd>
            </div>
            <div>
              <dt class="text-xs text-base-content/50">Subject</dt>
              <dd class="font-mono">{@subject.name}</dd>
            </div>
            <div>
              <dt class="text-xs text-base-content/50">Seed</dt>
              <dd class="font-mono">{@subject.seed}</dd>
            </div>
          </dl>
          <.download_menu :if={@images > 0} run={@run} subject={@subject} />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide active={:runs}>
      <.identity_header :if={@focused} run={@run} subject={@focused} />

      <div :if={!@focused} class="flex flex-wrap items-end justify-between gap-4">
        <div class="min-w-0">
          <.link
            navigate={~p"/biometrics"}
            id="back-to-runs"
            class="text-sm text-base-content/60 transition hover:text-base-content"
          >
            ← All runs
          </.link>
          <div class="mt-2 flex flex-wrap items-center gap-x-3">
            <h1 class="truncate font-mono text-xl font-semibold">{@run.name}</h1>
            <.run_status
              :if={@run.status != :finished}
              id="run-status"
              status={@run.status}
              class="mt-0"
            />
          </div>
          <dl id="run-meta" class="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-sm text-base-content/60">
            <div>
              <dt class="inline">seed</dt>

              <dd class="inline font-mono text-base-content">{@run.seed}</dd>
            </div>
            <div :if={@run.prompt_version}>
              <dt class="inline">prompts</dt>

              <dd class="inline text-base-content">{@run.prompt_version}</dd>
            </div>
            <div :if={@run.renderer && Enum.any?(@run.shots, &Shots.ridge?/1)}>
              <dt class="inline">ridges</dt>
              <dd class="inline text-base-content">{@run.renderer}</dd>
            </div>
            <div :if={@run.traits != %{}} id="run-traits">
              <dt class="inline">everyone</dt>
              <dd class="inline text-base-content">
                {Enum.join(Traits.describe(@run.traits), " · ")}
              </dd>
            </div>
            <div :if={@run.steps}>
              <dt class="inline">steps</dt>

              <dd class="inline text-base-content">{@run.steps}</dd>
            </div>
            <div>
              <dt class="inline">subjects</dt>
              <dd class="inline text-base-content">{@run.completed_subjects}/{@run.subject_count}</dd>
            </div>
            <div>
              <dt class="inline">updated</dt>
              <dd class="inline text-base-content">{format_time(@run.updated_at)}</dd>
            </div>
          </dl>
        </div>
        <div class="flex items-center gap-2">
          <.action_button
            :if={Run.active?(@run)}
            variant="danger"
            id="cancel-run"
            phx-click="cancel"
          >
            Cancel run
          </.action_button>
          <.action_button
            :if={can_add_shots?(@run, @addable)}
            variant="secondary"
            id="add-shots"
            phx-click="toggle-add-shots"
            aria-expanded={to_string(@adding?)}
            aria-controls="add-shots-form"
          >
            <.icon name="hero-plus-mini" class="size-4" /> Add shots
          </.action_button>
          <.action_button
            :if={resumable?(@run, @incomplete)}
            variant="primary"
            id="resume-run"
            phx-click="resume"
            title={"#{subjects_count(length(@incomplete))} missing images"}
          >
            Resume
          </.action_button>
        </div>
      </div>

      <p
        :if={!@focused and resumable?(@run, @incomplete) and @run.status == :finished}
        id="missing-images"
        class="flex items-center gap-2 rounded-xl border border-warning/40 bg-warning/10 px-4 py-2.5 text-sm"
      >
        <.icon name="hero-exclamation-triangle-mini" class="size-4 shrink-0 text-warning" />
        {subjects_count(length(@incomplete))} {if length(@incomplete) == 1, do: "is", else: "are"} missing images (failed or deleted). Resume renders them again from their stored seeds and prompts.
      </p>

      <.form
        :if={!@focused and @adding? and can_add_shots?(@run, @addable)}
        for={@add_form}
        id="add-shots-form"
        phx-submit="add-shots"
        class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <h2 class="text-sm font-semibold">Add shots</h2>
          <p class="text-xs text-base-content/60">
            Every subject gets them, with the seeds they would have had in the first run.
            Images already rendered are kept.
          </p>
        </div>

        <input type="hidden" name="add[shots][]" value="" />

        <div class="mt-4 grid gap-6 md:grid-cols-2">
          <fieldset :if={@addable.faces != []}>
            <legend class="mb-2 flex w-full items-center justify-between text-sm font-medium">
              <span>Face</span>
              <span class="text-xs font-normal text-base-content/50">
                Qwen-Image-2.1 · {@run.steps} steps
              </span>
            </legend>
            <div class="space-y-0.5">
              <label
                :for={shot <- @addable.faces}
                for={"add-#{shot}"}
                class="flex cursor-pointer items-start gap-3 rounded-lg px-2 py-1.5 transition hover:bg-base-200"
              >
                <input
                  type="checkbox"
                  id={"add-#{shot}"}
                  name="add[shots][]"
                  value={shot}
                  class="mt-0.5 size-4 rounded border-base-300 accent-[var(--color-primary)]"
                />
                <span class="min-w-0">
                  <span class="flex items-center gap-2 text-sm">
                    {shot_label(shot)} <.pos_badge pos={FacePrompts.spec(shot).pos} shot={shot} />
                    <span :if={anchor?(shot)} class="text-xs text-base-content/50">
                      added with any face shot
                    </span>
                  </span>
                  <span class="block text-xs text-base-content/60">{shot_description(shot)}</span>
                </span>
              </label>
            </div>
          </fieldset>

          <fieldset :if={@addable.groups != []}>
            <legend class="mb-2 flex w-full items-center justify-between text-sm font-medium">
              <span>Friction ridge</span>
              <span class="text-xs font-normal text-base-content/50">
                {@run.renderer} · {@run.captures} {if @run.captures == 1,
                  do: "capture",
                  else: "captures"}
              </span>
            </legend>
            <div class="space-y-0.5">
              <label
                :for={{group, name} <- @addable.groups}
                for={"add-#{group}"}
                class="flex cursor-pointer items-start gap-3 rounded-lg px-2 py-1.5 transition hover:bg-base-200"
              >
                <input
                  type="checkbox"
                  id={"add-#{group}"}
                  name="add[shots][]"
                  value={group}
                  class="mt-0.5 size-4 rounded border-base-300 accent-[var(--color-primary)]"
                />
                <span class="min-w-0">
                  <span class="block text-sm">{name}</span>
                  <span class="block text-xs text-base-content/60">{group_description(group)}</span>
                </span>
              </label>
            </div>
          </fieldset>
        </div>

        <p :if={@add_error} id="add-shots-error" class="mt-3 text-sm text-error">{@add_error}</p>

        <div class="mt-4 flex justify-end gap-2 border-t border-base-300 pt-4">
          <.action_button type="button" variant="secondary" phx-click="toggle-add-shots">
            Cancel
          </.action_button>
          <.action_button type="submit" variant="primary" id="submit-add-shots">
            Add and render
          </.action_button>
        </div>
      </.form>

      <div
        :if={@progress}
        id="run-progress"
        class="space-y-2 rounded-2xl border border-primary/30 bg-primary/5 p-4"
      >
        <div class="flex items-center gap-2 text-sm">
          <.spinner class="size-4 text-primary" />
          Subject {min(@progress.done + 1, @progress.total)} of {@progress.total}
          <span :if={next_shot(@progress.shots, @progress.subject)} class="text-base-content/60">
            · rendering {shot_label(next_shot(@progress.shots, @progress.subject))}
          </span>
        </div>
        <.progress_bar value={run_fraction(@progress)} />
      </div>

      <.quality_report :if={@run.report && !@focus} report={@run.report} />

      <div id="subjects" phx-update="stream" class="space-y-4">
        <div
          class="hidden rounded-2xl border border-dashed border-base-300 p-10 text-center text-sm text-base-content/60 only:block"
          id="subjects-empty"
        >
          No subjects yet.
        </div>
        <article
          :for={{dom_id, subject} <- @streams.subjects}
          id={dom_id}
          class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
        >
          <header :if={!@focus} class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="font-mono text-sm font-semibold">{subject.name}</h2>
            <span class="font-mono text-xs text-base-content/50">seed {subject.seed}</span>
            <p class="w-full text-sm text-base-content/70 lg:w-auto lg:flex-1">
              {subject.description}
            </p>
            <a
              :if={Enum.any?(subject.images, &(&1.status == :ok))}
              href={~p"/biometrics/#{@run.name}/#{subject.name}/download"}
              id={"download-#{subject.name}"}
              class="inline-flex items-center gap-1 text-xs font-medium text-base-content/60 transition hover:text-primary"
              title="Everything of this person as a ZIP"
            >
              <.icon name="hero-arrow-down-tray-mini" class="size-3.5" /> Download
            </a>
            <.link
              navigate={~p"/biometrics/#{@run.name}/#{subject.name}"}
              id={"open-#{subject.name}"}
              class="inline-flex items-center gap-1 text-xs font-medium text-base-content/60 transition hover:text-primary"
            >
              Open identity <.icon name="hero-arrow-right-mini" class="size-3.5" />
            </.link>
          </header>
          <section
            :for={{key, title, shots} <- sections(@run.shots)}
            class="mt-4"
            id={"#{subject.name}-#{key}"}
          >
            <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-base-content/50">
              {title}
            </h3>
            <div class="-mx-1 flex items-end gap-3 overflow-x-auto px-1 pb-1">
              <.shot_tile
                :for={shot <- shots}
                run={@run.name}
                subject={subject}
                shot={shot}
                active?={subject.name == active_subject_id(@progress)}
                focused?={!!@focus}
                rendering?={
                  subject.name == active_subject_id(@progress) and
                    shot == next_shot(@run.shots, subject)
                }
              />
            </div>
          </section>
        </article>
      </div>

      <div
        :if={@selected}
        id="shot-detail"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-3 backdrop-blur-sm sm:p-6"
        phx-window-keydown="lightbox-key"
        role="dialog"
        aria-modal="true"
        aria-label={"#{shot_label(@selected.record.shot)} of #{@selected.subject.name}"}
      >
        <.link patch={page_path(@run, @focus)} class="absolute inset-0" aria-label="Close"></.link>
        <div class="relative grid max-h-full w-full max-w-6xl overflow-hidden rounded-2xl bg-base-100 shadow-2xl lg:grid-cols-[minmax(0,1fr)_360px]">
          <div class="flex min-h-0 items-center justify-center bg-neutral-950">
            <img
              src={image_url(@selected.record)}
              alt={"#{shot_label(@selected.record.shot)} of #{@selected.subject.name}"}
              class="max-h-[60vh] w-auto object-contain lg:max-h-[88vh]"
            />
          </div>
          <aside class="flex max-h-[40vh] flex-col gap-4 overflow-y-auto p-5 text-sm lg:max-h-[88vh]">
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="font-mono text-xs text-base-content/50">{@selected.subject.name}</p>
                <h2 class="mt-0.5 flex items-center gap-2 text-lg font-semibold">
                  {shot_label(@selected.record.shot)}
                  <.pos_badge
                    :if={@selected.record.pos}
                    pos={@selected.record.pos}
                    shot={@selected.record.shot}
                  />
                </h2>
              </div>
              <.link
                patch={page_path(@run, @focus)}
                id="close-detail"
                class="rounded-lg p-1.5 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                aria-label="Close"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </.link>
            </div>

            <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-xs">
              <dt class="text-base-content/50">Size</dt>
              <dd class="font-mono">{@selected.record.width}×{@selected.record.height}</dd>
              <dt class="text-base-content/50">Seed</dt>
              <dd class="font-mono">{@selected.record.seed}</dd>
              <dt class="text-base-content/50">Render time</dt>
              <dd>{format_duration(@selected.record.duration_ms)}</dd>
              <%= if @selected.record.prompt do %>
                <dt class="text-base-content/50">Reference</dt>
                <dd>
                  {if @selected.record.reference_id, do: "frontal mugshot", else: "none (text only)"}
                </dd>
              <% else %>
                <dt class="text-base-content/50">Resolution</dt>
                <dd>500 ppi, 8-bit grey</dd>
                <dt class="text-base-content/50">Capture</dt>
                <dd>{(@selected.record.capture || 0) + 1}</dd>
              <% end %>
            </dl>

            <div :if={@selected.record.meta} id="ridge-meta" class="space-y-2 text-xs">
              <h3 class="font-medium text-base-content/50">Ground truth</h3>
              <dl class="grid grid-cols-2 gap-x-4 gap-y-2">
                <%= if pattern = @selected.record.meta["pattern"] do %>
                  <dt class="text-base-content/50">Pattern</dt>
                  <dd class="capitalize">{pattern_name(pattern)}</dd>
                  <dt class="text-base-content/50">Singular points</dt>
                  <dd>{singular_points(@selected.record.meta)}</dd>
                <% end %>
                <%= if fingers = @selected.record.meta["fingers"] do %>
                  <dt class="text-base-content/50">Fingers</dt>
                  <dd>
                    <span :for={finger <- fingers} class="block">
                      {shot_label("rolled_" <> String.pad_leading(to_string(finger["fgp"]), 2, "0"))}: {pattern_name(
                        finger["pattern"]
                      )}
                    </span>
                  </dd>
                <% end %>
                <%= if count = @selected.record.meta["minutiae_count"] do %>
                  <dt class="text-base-content/50">Minutiae</dt>
                  <dd>{count}</dd>
                <% end %>
                <%= if triradii = @selected.record.meta["triradii"] do %>
                  <dt class="text-base-content/50">Triradii in view</dt>
                  <dd>{triradii |> Map.keys() |> Enum.sort() |> Enum.join(", ")}</dd>
                  <dt class="text-base-content/50">Patterns</dt>
                  <dd>
                    {Enum.map_join(@selected.record.meta["patterns"] || [], ", ", &pattern_name/1)
                    |> then(&if(&1 == "", do: "none", else: &1))}
                  </dd>
                <% end %>
              </dl>
              <a
                :if={@selected.record.ground_truth}
                id="ground-truth-link"
                href={ground_truth_url(@selected.record)}
                target="_blank"
                rel="noopener"
                class="inline-block text-primary underline-offset-4 hover:underline"
              >
                Ground-truth JSON (minutiae, singular points)
              </a>
            </div>

            <.verification_details
              :if={verification(@selected.record)}
              check={verification(@selected.record)}
            />

            <div>
              <h3 class="mb-1 text-xs font-medium text-base-content/50">Person</h3>
              <p class="text-base-content/80">{@selected.subject.description}</p>
            </div>

            <div :if={@selected.record.prompt}>
              <h3 class="mb-1 text-xs font-medium text-base-content/50">Prompt</h3>
              <p
                id="shot-prompt"
                class="whitespace-pre-wrap rounded-lg bg-base-200 p-3 text-xs leading-relaxed text-base-content/80"
              >
                {@selected.record.prompt}
              </p>
            </div>

            <div class="mt-auto flex items-center justify-between gap-2 border-t border-base-300 pt-4">
              <div class="flex gap-1">
                <.link
                  :if={@selected.prev}
                  patch={shot_path(@run.name, @selected.subject.name, @selected.prev, !!@focus)}
                  id="prev-shot"
                  class="rounded-lg border border-base-300 px-3 py-1.5 text-xs transition hover:bg-base-200"
                >
                  ← {shot_label(@selected.prev)}
                </.link>
                <.link
                  :if={@selected.next}
                  patch={shot_path(@run.name, @selected.subject.name, @selected.next, !!@focus)}
                  id="next-shot"
                  class="rounded-lg border border-base-300 px-3 py-1.5 text-xs transition hover:bg-base-200"
                >
                  {shot_label(@selected.next)} →
                </.link>
              </div>
              <div class="flex items-center gap-3 text-xs">
                <a
                  href={image_url(@selected.record)}
                  target="_blank"
                  rel="noopener"
                  class="text-primary underline-offset-4 hover:underline"
                >
                  Full size
                </a>
                <a
                  id="download-shot"
                  href={image_url(@selected.record) <> "?download=1"}
                  class="inline-flex items-center gap-1 text-primary underline-offset-4 hover:underline"
                >
                  <.icon name="hero-arrow-down-tray-micro" class="size-3.5" /> Download
                </a>
              </div>
            </div>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
