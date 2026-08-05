# Lab 7 - Code Interface

## Relevant Documentation

- [Code Interface](https://hexdocs.pm/ash/code-interfaces.html)

## Steps

Now, if we look at the places that we're interacting with our application, we're
calling functions on the `Ash` module, and providing our resource. There is nothing wrong
with doing this, but we want to provide an interface to our application, _even for in-code usage_.

1. To start, let's add an interface for our `:feed` action.
   We do this inside the block for the resource we want to call in our domain `Twitter.Tweets`.

```elixir
resource Twitter.Tweets.Tweet do
  define :feed
end
```

2. We can then replace that in our logic to fetch tweets in our `mount/3` function in `index.ex`

```elixir
|> stream(
  :tweets,
  Twitter.Tweets.feed!(actor: socket.assigns.current_user, load: @tweet_loads)
)
```

3. Then, we can add an interface for getting an individual tweet.
   We'll call this `:get_tweet`. Since the action name is not the same as the
   function, we'll need to add the `action` option. We want it to
   filter by `id`, and expect a single result, so we'll use `get_by: [:id]`

```elixir
resource Twitter.Tweets.Tweet do
  ...
  define :get_tweet, action: :read, get_by: [:id]
end
```

4. Now lets use that in our `apply_action` function for `:edit` in `lib/twitter_web/live/tweet_live/form.ex`

```elixir
defp apply_action(socket, :edit, %{"id" => id}) do
  socket
  |> assign(:page_title, "Edit Tweet")
  |> assign(
    :tweet,
    Twitter.Tweets.get_tweet!(id, actor: socket.assigns.current_user)
  )
end
```

5. Lastly, we'll add an interface for removing tweets. Lets call it `:delete_tweet`.
   and have it use the `:destroy` action.

6. And then we can use that in our `handle_event/3` function for `"delete"`

Notice that the code interface can take just the id of the record to delete, simplifying this operation greatly.

```elixir
def handle_event("delete", %{"id" => id}, socket) do
  Twitter.Tweets.delete_tweet!(id, actor: socket.assigns.current_user)

  {:noreply, stream_delete(socket, :tweets, %{id: id})}
end
```

7. We can also clean up and simplify our `like/unlike` calls. We'll start with `like`:

```elixir
resource Twitter.Tweets.Like do
  define :like, args: [:tweet_id]
end
```

8. Now, we can replace our code for liking in our `handle_event/3` function for `"like"` with
   this simple snippet:

```elixir
Twitter.Tweets.like!(tweet_id, actor: socket.assigns.current_user)
```

9. Now lets do the same with unlike.

Update and destroy interfaces accept the record or a reference to a record as
the first argument. Because we don't want to look up the individual like that is
being deleted, we just want to supply the `tweet_id`, we'll need to use the
`require_reference?` option to skip requiring providing the record or id.

This way, the code interface will use a bulk destroy under the hood.

```elixir
resource Twitter.Tweets.Like do
  define :like, args: [:tweet_id]
  define :unlike, args: [:tweet_id], require_reference?: false
end
```

10. See if you can work out replacing the `unlike` code with our new interface!

## Try on your own

- In `iex -S mix` read the generated docs for these functions. `h Twitter.Tweets.like`
- Add a `:get_user_by_email` interface
- Add a `:popular_tweets` action and interface, that shows the top 10 most popular tweets.
