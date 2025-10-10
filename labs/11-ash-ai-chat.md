# Lab 11 - AshAi Chat Setup & Tools

## Relevant Documentation

- [AshAi Documentation](https://hexdocs.pm/ash_ai)
- [AshAi GitHub](https://github.com/ash-project/ash_ai)
- [Getting Started with AshAi](https://alembic.com.au/blog/ash-ai-comprehensive-llm-toolbox-for-ash-framework)
- [AshOban Documentation](https://hexdocs.pm/ash_oban)
- [Tool Definition Guide](https://hexdocs.pm/ash_ai/AshAi.html#module-tools)

## Context

In this lab, we'll integrate AshAi into our Twitter application to create an
AI-powered chat interface. AshAi provides a declarative approach to AI
integration with the Ash Framework, including chat generation, tool calling,
vectorization, and more.

We'll use `mix ash_ai.gen.chat` to generate a complete chat feature with:

- Streaming responses backed by Phoenix PubSub
- Durable agent responses backed by Oban
- Tool calling to interact with our Tweet resources
- Conversation persistence

## Prerequisites

Before starting, you'll need:

- An OpenAI API key (sign up at https://platform.openai.com)
- Tailwind CSS and DaisyUI installed (already included in this project)

## Steps

### 1. Install AshAi Dependencies

Install AshAi using igniter `mix igniter.install ash_ai`. Or do it manually by
adding the following dependency to your `mix.exs` file in the `deps` function:

```elixir
{:ash_ai, "~> 0.2"},
```

Then run:

```bash
mix deps.get
```

and add the extension to your formatter configuration in `.formatter.exs`:

```elixir
[
  import_deps: [
    :ash_ai
    ...
  ],
  ...
]
```

### 2. Configure OpenAI API Key

Add your OpenAI API key to your configuration. In `config/dev.exs` and
`config/runtime.exs`, add:

```elixir
# In config/dev.exs (for development)
config :langchain, :openai_key, System.get_env("OPENAI_API_KEY")

# In config/runtime.exs (for production)
if config_env() == :prod do
  config :langchain, :openai_key, System.get_env("OPENAI_API_KEY")
end
```

Set the environment variable in your terminal:

```bash
export OPENAI_API_KEY="your-api-key-here"
```

### 3. Generate Chat Resources

Run the chat generator:

```bash
mix ash_ai.gen.chat --live
```

This command will prompt you to select:

- Your user resource: Select `Twitter.Accounts.User`
- Whether to generate with LiveView: Choose `yes`

The generator will create:

- `Twitter.Ai` domain module
- `Twitter.Ai.Conversation` resource (for storing chat conversations)
- `Twitter.Ai.Message` resource (for storing individual messages)
- LiveView components for the chat interface
- Routes for accessing the chat

### 4. Run Migrations

The generator creates new resources, so we need to create and run migrations:

```bash
mix ash.codegen add_ai_chat
mix ash.migrate
```

### 5. Configure AshOban

AshAi uses Oban to handle asynchronous message processing. We need to set up
Oban in our application.

Add Oban configuration to `config/config.exs`:

```elixir
config :twitter, Oban,
  repo: Twitter.Repo,
  queues: [default: 10, ai: 5],
  plugins: [Oban.Plugins.Pruner]
```

Then update your `Twitter.Application` module in `lib/twitter/application.ex` to
include Oban in the supervision tree:

```elixir
# Add this to the children list in the start/2 function
{Oban, Application.fetch_env!(:twitter, Oban)}
```

### 6. Define Tweet Tools

Now we'll expose Tweet actions as tools that the AI can call. Open
`lib/twitter/tweets.ex` and add a `tools` block to the domain:

```elixir
defmodule Twitter.Tweets do
  use Ash.Domain,
    extensions: [AshAi.Domain]

  # ... existing code ...

  tools do
    tool :read_feed, Twitter.Tweets.Tweet, :feed do
      description "Retrieve the feed of tweets, sorted by most recent first"
    end

    tool :get_tweet, Twitter.Tweets.Tweet, :read do
      description "Get a specific tweet by ID"
      argument :id, :uuid, allow_nil?: false
    end

    tool :create_tweet, Twitter.Tweets.Tweet, :create do
      description "Create a new tweet with text content"
      argument :text, :string, allow_nil?: false
    end
  end
end
```

### 7. Make Tweet Attributes Public

For the AI to read tweet data through tools, we need to make relevant attributes
public. In `lib/twitter/tweets/tweet.ex`, update the attributes:

```elixir
attribute :text, :string do
  allow_nil? false
  public? true
end

attribute :id, :uuid do
  primary_key? true
  default &Ash.UUID.generate/0
  public? true
end
```

Also make the `user_email` calculation public:

```elixir
calculate :user_email, :string, expr(user.email) do
  public? true
end
```

### 8. Test the Chat Interface

Start your Phoenix server:

```bash
mix phx.server
```

Navigate to the chat interface (the generator will output the route, typically
`http://localhost:4000/chat`).

Try asking the AI:

- "Show me the latest tweets"
- "Create a tweet that says 'Hello from AI!'"
- "What tweets are in the feed?"

Watch the console to see the AI making tool calls to your Tweet actions.

### 9. Configure Tool Calling Behavior

You can customize how tools behave by adding metadata. Update a tool in
`lib/twitter/tweets.ex`:

```elixir
tool :read_feed, Twitter.Tweets.Tweet, :feed do
  description "Retrieve the feed of tweets, sorted by most recent first. Returns a list of tweets with their text, user email, and like count."

  # Only expose specific fields to the AI
  public_fields [:id, :text, :user_email, :like_count, :inserted_at]

  # Require authentication (actor must be present)
  require_actor? true
end
```

### 10. Add a Like Tool

Let's add the ability for the AI to like tweets on behalf of the user. Add this
to the `tools` block:

```elixir
tool :like_tweet, Twitter.Tweets.Like, :like do
  description "Like a tweet. The current user will be marked as liking the tweet."
  argument :tweet_id, :uuid, allow_nil?: false
end
```

Now you can ask the AI: "Like the tweet with ID [some-uuid]"

## Try on your own

- Add a tool for unliking tweets using the `:unlike` action

- Create a tool that allows the AI to search for tweets containing specific text
  (you'll need to add a custom read action with a filter)

- Add descriptions to your tools to help the AI understand when to use them

- Experiment with different AI models by configuring the LLM provider in your
  conversation resource

- Add a tool that exposes the `:like_count` aggregate, so the AI can tell you
  which tweets are most popular

- Configure the chat to use different system prompts by modifying the generated
  `Conversation` resource

## Verification

To verify your setup is working:

1. Check that the chat interface loads without errors
2. Send a message and confirm you receive a response
3. Ask the AI to "show me the tweets" and verify it makes a tool call
4. Check the database to see that conversations and messages are being persisted
5. Look at the Oban dashboard (if configured) to see background jobs processing
