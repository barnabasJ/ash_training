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

      <.form for={%{}} id="tweet-form" phx-change="validate" phx-submit="save">
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

  defp apply_action(socket, :edit, %{"id" => _id}) do
    socket
    |> assign(:page_title, "Edit Tweet")
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Tweet")
    |> assign(:tweet, nil)
  end

  @impl true
  def handle_event("save", params, socket) do
    result =
      if socket.assigns.tweet do
        # we're updating a tweet
        {:error, "Not implemented"}
      else
        Twitter.Tweets.Tweet
        |> Ash.Changeset.for_create(:create, params["tweet"] || %{}, actor: socket.assigns.current_user)
        |> Ash.create()
      end

    case result do
      {:ok, tweet} ->
        notify_parent({:saved, tweet})

        socket =
          socket
          |> put_flash(:info, "Success!")
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}

      {:error, _error} ->
        {:noreply, socket}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp return_path("index", _tweet), do: ~p"/"
  defp return_path("show", tweet), do: ~p"/tweets/#{tweet}"
end
