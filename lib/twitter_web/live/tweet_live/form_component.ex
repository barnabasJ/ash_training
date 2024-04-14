defmodule TwitterWeb.TweetLive.FormComponent do
  use TwitterWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage tweet records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={%{}}
        as={:tweet}
        id="tweet-form"
        phx-target={@myself}
        phx-submit="save"
      >
        <:actions>
          <.button phx-disable-with="Saving...">Save Tweet</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)}
  end

  @impl true
  def handle_event("save", params, socket) do
    result =
      if socket.assigns.tweet do
        # we're updating a tweet. Update logic goes here.
        {:error, "Update not implemented"}
      else
        # we're creating a tweet. Create logic goes here.
        {:error, "Create not implemented"}
      end

    case result do
      {:ok, tweet} ->
        notify_parent({:saved, tweet})

        socket =
          socket
          |> put_flash(:info, "Success!")
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}

      {:error, error} ->
        {:noreply,
         put_flash(socket, :error, "Error!: #{Exception.format(:error, error)}")
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
