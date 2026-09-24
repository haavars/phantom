defmodule PhantomWeb.BiometricsRunLive do
  @moduledoc """
  One synthetic-biometrics run: every subject with its face and friction-ridge
  shots, filled in live while the run is active, plus a detail view
  (`?subject=...&shot=...`) with the full image and its prompt or ground truth.
  Incomplete or partly failed runs can be resumed.

  `/biometrics/:run/:subject` shows one subject (one synthetic identity) on its
  own, with every image of it; the detail view there is `?shot=...`.
  """

  use PhantomWeb, :live_view

  import PhantomWeb.BiometricsComponents

  alias Phantom.Biometrics.{FrictionRidge, Gallery, Runner, Runs, Shots}
  alias Phantom.ImageGeneration

  @terminal [:finished, :cancelled, :failed]

  @impl true
  def mount(%{"run" => name} = params, _session, socket) do
    if connected?(socket), do: Runner.subscribe()

    progress = Runner.current()
    active = if match?(%{run: ^name}, progress), do: progress
    focus = if socket.assigns.live_action == :subject, do: params["subject"]

    case load_run(name, active) do
      {:ok, run, subjects} ->
        focused = focus && Enum.find(subjects, &(&1.name == focus))

        if focus && is_nil(focused) do
          {:ok,
           socket
           |> put_flash(:error, "Subject #{focus} not found in #{name}.")
           |> push_navigate(to: ~p"/biometrics/#{name}")}
        else
          socket =
            socket
            |> assign(:page_title, if(focused, do: Gallery.code(focused.seed), else: name))
            |> assign(:run, run)
            |> assign(:focus, focus)
            |> assign(:focused, focused)
            |> assign(:progress, active)
            |> assign(:busy?, not is_nil(progress) and is_nil(active))
            |> assign(:has_failures?, failures?(subjects))
            |> assign(:selected, nil)
            |> stream_configure(:subjects, dom_id: &"subjects-#{&1.name}")
            |> stream(:subjects, in_focus(subjects, focus))

          {:ok, socket}
        end

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Run #{name} not found.")
         |> push_navigate(to: ~p"/biometrics")}
    end
  end

  # The run and its subjects from the database. The subject that's rendering
  # right now comes from the runner's snapshot instead, which is ahead of it.
  defp load_run(name, active) do
    with {:ok, run} <- Runs.get_run(name) do
      live = active && active.subject

      subjects =
        Enum.map(run.subjects, fn subject ->
          if live && live.name == subject.name, do: live, else: subject
        end)

      {:ok, %{run | subjects: []}, subjects}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected, select(socket, params))}
  end

  defp select(socket, %{"subject" => subject_name, "shot" => shot}) do
    with {:ok, subject} <- find_subject(socket, subject_name),
         %{status: "ok"} = record <- Enum.find(subject.images, &(&1.shot == shot)) do
      rendered =
        subject.images |> Enum.filter(&(&1.status == "ok")) |> Enum.map(& &1.shot)

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

  defp find_subject(socket, subject_name) do
    case socket.assigns.progress do
      %{subject: %{name: ^subject_name} = subject} -> {:ok, subject}
      _ -> Runs.get_subject(socket.assigns.run.name, subject_name)
    end
  end

  @impl true
  def handle_event("resume", _params, socket) do
    run = socket.assigns.run

    opts =
      [
        run: run.name,
        seed: run.seed,
        shots: run.shots,
        steps: run.steps,
        subjects: run.subject_count,
        renderer: run.renderer
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with :ok <- services_ready(run.shots),
         {:ok, _run} <- Runner.start_run(opts) do
      {:noreply, socket}
    else
      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Another run is in progress.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel", _params, socket) do
    :ok = Runner.cancel()
    {:noreply, socket}
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
  def handle_info(
        {:biometrics_run, event, %{run: name} = progress},
        %{assigns: %{run: %{name: name}}} = socket
      ) do
    socket =
      cond do
        event in @terminal ->
          socket
          |> assign(:progress, nil)
          |> reload()
          |> flash_outcome(event, progress)

        event == :started ->
          socket |> assign(:progress, progress) |> assign(:busy?, false)

        event == :subject_done ->
          socket
          |> assign(:progress, progress)
          |> update(:run, &%{&1 | completed_subjects: &1.completed_subjects + 1})
          |> insert_subject(progress.subject)

        progress.subject ->
          socket |> assign(:progress, progress) |> insert_subject(progress.subject)

        true ->
          assign(socket, :progress, progress)
      end

    {:noreply, socket}
  end

  # Another run started or stopped: only matters for whether Resume is possible.
  def handle_info({:biometrics_run, event, _progress}, socket) do
    {:noreply, assign(socket, :busy?, event not in @terminal)}
  end

  # Re-read the run from disk, dropping a half-rendered subject after a cancel.
  defp reload(socket) do
    case load_run(socket.assigns.run.name, nil) do
      {:ok, run, subjects} ->
        socket
        |> assign(:run, run)
        |> assign(:has_failures?, failures?(subjects))
        |> stream(:subjects, in_focus(subjects, socket.assigns.focus), reset: true)

      {:error, :not_found} ->
        socket
    end
  end

  defp flash_outcome(socket, :finished, _progress), do: put_flash(socket, :info, "Run finished.")

  defp flash_outcome(socket, :cancelled, _progress),
    do: put_flash(socket, :info, "Run cancelled. Resume to render the rest.")

  defp flash_outcome(socket, :failed, progress),
    do: put_flash(socket, :error, "Run failed: #{progress.error}")

  defp failures?(subjects) do
    Enum.any?(subjects, fn subject ->
      Enum.any?(subject.images, &(&1.status in ["error", "skipped"]))
    end)
  end

  defp resumable?(run, has_failures?),
    do: run.status != "running" and (run.completed_subjects < run.subject_count or has_failures?)

  defp active_subject_id(%{subject: %{name: name}}), do: name
  defp active_subject_id(_progress), do: nil

  defp services_ready(shots) do
    cond do
      Enum.any?(shots, &Shots.face?/1) and ImageGeneration.health() != :ready ->
        {:error, "The Qwen-Image-2.1 service isn't ready."}

      Enum.any?(shots, &Shots.ridge?/1) and FrictionRidge.health() != :ready ->
        {:error, "The friction-ridge service isn't ready."}

      true ->
        :ok
    end
  end

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

  # The focused page's header: who this synthetic person is, and where they came from.
  defp identity_header(assigns) do
    assigns =
      assigns
      |> assign(:attributes, Map.get(assigns.subject, :attributes) || %{})
      |> assign(
        :images,
        Enum.count(assigns.subject.images, &(&1.status == "ok"))
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
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
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
          <h1 class="mt-2 truncate font-mono text-xl font-semibold">{@run.name}</h1>
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
            :if={@progress}
            variant="danger"
            id="cancel-run"
            phx-click="cancel"
          >
            Cancel run
          </.action_button>
          <.action_button
            :if={is_nil(@progress) and resumable?(@run, @has_failures?)}
            variant="primary"
            id="resume-run"
            phx-click="resume"
            disabled={@busy?}
            title={if(@busy?, do: "Another run is in progress")}
          >
            Resume
          </.action_button>
        </div>
      </div>

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
              <a
                href={image_url(@selected.record)}
                target="_blank"
                rel="noopener"
                class="text-xs text-primary underline-offset-4 hover:underline"
              >
                Full size
              </a>
            </div>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
