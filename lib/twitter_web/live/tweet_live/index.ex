defmodule TwitterWeb.TweetLive.Index do
  use TwitterWeb, :live_view

  @tweet_loads [:text_length, :liked_by_me, :like_count, :user_email]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Listing Tweets
        <:actions>
          <.button variant="primary" navigate={~p"/tweets/new"}>
            <.icon name="hero-plus" /> New Tweet
          </.button>
        </:actions>
      </.header>

      <.table
        id="tweets"
        rows={@streams.tweets}
        row_click={fn {_id, tweet} -> JS.navigate(~p"/tweets/#{tweet}") end}
      >
        <:col :let={{_id, tweet}} label="Id">
          <span class="max-w-24 text-wrap">
            {tweet.id}
          </span>
        </:col>

        <:col :let={{_id, tweet}} label="Text">
          {tweet.text}
        </:col>

        <:col :let={{_id, tweet}} label="Length">
          {tweet.text_length}
        </:col>

        <:col :let={{_id, tweet}} label="Author">
          {tweet.user_email}
        </:col>
        <:action :let={{_id, tweet}}>
          <%= if tweet.liked_by_me do %>
            <button phx-click="unlike" phx-value-id={tweet.id}>
              <.icon name="hero-heart-solid" class="text-red-600" />
            </button>
          <% else %>
            <button phx-click="like" phx-value-id={tweet.id}>
              <.icon name="hero-heart" />
            </button>
          <% end %>
        </:action>
        <:action :let={{_id, tweet}}>
          <div class="sr-only">
            <.link navigate={~p"/tweets/#{tweet}"}>Show</.link>
          </div>
          <.link navigate={~p"/tweets/#{tweet}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, tweet}}>
          <.link
            phx-click={JS.push("delete", value: %{id: tweet.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      TwitterWeb.Endpoint.subscribe("tweet:liked")
      TwitterWeb.Endpoint.subscribe("tweet:unliked")
    end

    {:ok,
     socket
     |> stream(
       :tweets,
       Twitter.Tweets.feed!(actor: socket.assigns.current_user, load: @tweet_loads)
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Tweet")
    |> assign(
      :tweet,
      Twitter.Tweets.get_tweet!(id, load: @tweet_loads, actor: socket.assigns.current_user)
    )
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Tweet")
    |> assign(:tweet, nil)
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Tweets")
    |> assign(:tweet, nil)
  end

  @impl true
  def handle_info({TwitterWeb.TweetLive.FormComponent, {:saved, tweet}}, socket) do
    tweet = Ash.load!(tweet, @tweet_loads, actor: socket.assigns.current_user)

    {:noreply, stream_insert(socket, :tweets, tweet)}
  end

  def handle_info(
        %{
          topic: "tweet:" <> _tenant_updated_or_created
        },
        socket
      ) do
    {:noreply,
     socket
     |> stream(
       :tweets,
       Twitter.Tweets.feed!(actor: socket.assigns.current_user, load: @tweet_loads)
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Twitter.Tweets.Tweet
    |> Ash.get!(id, action: :read, load: @tweet_loads)
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: socket.assigns.current_user)
    |> Ash.destroy!()

    {:noreply, stream_delete(socket, :tweets, %{id: id})}
  end

  @impl true
  def handle_event("like", %{"id" => tweet_id}, socket) do
    Twitter.Tweets.like!(tweet_id, actor: socket.assigns.current_user)

    {:noreply, refetch_tweet(socket, tweet_id)}
  end

  def handle_event("unlike", %{"id" => tweet_id}, socket) do
    Ash.bulk_destroy!(
      Twitter.Tweets.Like,
      :unlike,
      %{tweet_id: tweet_id},
      actor: socket.assigns.current_user
    )

    {:noreply, refetch_tweet(socket, tweet_id)}
  end

  defp refetch_tweet(socket, id) do
    stream_insert(
      socket,
      :tweets,
      Twitter.Tweets.get_tweet!(id, actor: socket.assigns.current_user, load: @tweet_loads)
    )
  end
end
