defmodule TwitterWeb.TweetLive.Form do
  use TwitterWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage tweet records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="tweet-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:text]} type="text" label="Text" />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Tweet</.button>
          <.button navigate={return_path(@return_to, @tweet)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    tweet = Ash.get!(Twitter.Tweets.Tweet, id, actor: socket.assigns.current_user)

    socket
    |> assign(:page_title, "Edit Tweet")
    |> assign(:tweet, tweet)
    |> assign_form()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Tweet")
    |> assign(:tweet, nil)
    |> assign_form()
  end

  @impl true
  def handle_event("save", %{"tweet" => tweet_params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: tweet_params) do
      {:ok, tweet} ->
        notify_parent({:saved, tweet})

        socket =
          socket
          |> put_flash(:info, "Tweet #{socket.assigns.form.source.type}d successfully")
          |> push_navigate(to: return_path(socket.assigns.return_to, tweet))

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("validate", %{"tweet" => tweet_params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, tweet_params))}
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp assign_form(%{assigns: %{tweet: tweet}} = socket) do
    form =
      if tweet do
        AshPhoenix.Form.for_update(tweet, :update,
          as: "tweet",
          actor: socket.assigns.current_user
        )
      else
        AshPhoenix.Form.for_create(Twitter.Tweets.Tweet, :create,
          as: "tweet",
          actor: socket.assigns.current_user
        )
      end

    assign(socket, form: to_form(form))
  end

  defp return_path("index", _tweet), do: ~p"/"
  defp return_path("show", tweet), do: ~p"/tweets/#{tweet}"
end
