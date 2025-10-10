# Lab 12 - AshAi MCP Servers

## Relevant Documentation

- [AshAi.Mcp Documentation](https://hexdocs.pm/ash_ai/AshAi.Mcp.html)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
- [AshAuthentication Documentation](https://hexdocs.pm/ash_authentication)
- [MCP Transport Specification](https://spec.modelcontextprotocol.io/specification/2025-03-26/basic/transports/)

## Context

The Model Context Protocol (MCP) is a standardized way to expose tools and
context to AI assistants like Claude Code, Cursor, Zed, and Windsurf. AshAi
provides built-in MCP server support to expose your application's capabilities
to these tools.

In this lab, we'll set up two MCP servers:

1. **Development MCP Server** - For use with IDEs and development tools,
   exposing broad read/write access
2. **Production MCP Server** - For end-user AI integrations, with controlled
   access and authentication

## Steps

### 1. Set Up Development MCP Server

The development MCP server is designed to help you and your team work with AI
coding assistants. It provides access to your application's tools without
requiring authentication (since it only runs in development).

Open `lib/twitter_web/endpoint.ex` and add the MCP server plug inside the
`code_reloading?` block:

```elixir
if code_reloading? do
  # ... existing code ...

  # Add this at the end of the code_reloading? block
  plug AshAi.Mcp.Dev,
    domains: [Twitter.Tweets, Twitter.Accounts],
    path: "/ash_ai/mcp"
end
```

This exposes an MCP server at `http://localhost:4000/ash_ai/mcp` that provides:

- All tools defined in your domains
- Read access to your resources
- Ability to call actions on behalf of development work

### 2. Configure Development Tools

The MCP server is available, but your AI coding tools need to know about it. The
configuration varies by tool:

#### For Cursor

Add to your Cursor settings (`.cursor/config.json` or user settings):

```json
{
  "mcpServers": {
    "twitter-dev": {
      "url": "http://localhost:4000/ash_ai/mcp",
      "transport": "http"
    }
  }
}
```

#### For Zed

Add to your Zed settings:

```json
{
  "context_servers": {
    "twitter-dev": {
      "settings": {
        "url": "http://localhost:4000/ash_ai/mcp"
      }
    }
  }
}
```

#### For Windsurf

Similar to Cursor, add the MCP server URL to your Windsurf configuration.

### 3. Test the Development MCP Server

Start your server:

```bash
mix phx.server
```

You can test the MCP server directly using curl:

```bash
curl -X POST http://localhost:4000/ash_ai/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list"
  }'
```

This should return a list of all available tools from your domains.

### 4. Set Up Production MCP Server

The production MCP server is different - it should require authentication and
expose a limited, controlled set of tools. Create a new router specifically for
the MCP server.

Create `lib/twitter_web/mcp_router.ex`:

```elixir
defmodule TwitterWeb.McpRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/",
    to: AshAi.Mcp,
    init_opts: [
      domains: [Twitter.Tweets],
      # Only expose specific tools for production use
      allow_tools: [:read_feed, :get_tweet, :create_tweet],
      # Require authentication
      authenticate: &TwitterWeb.McpRouter.authenticate/1
    ]

  def authenticate(conn) do
    # Extract token from Authorization header
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, user} <- Twitter.Accounts.verify_access_token(token) do
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end
end
```

### 5. Add Production MCP Route

Open `lib/twitter_web/router.ex` and add a route for the production MCP server:

```elixir
scope "/api/mcp", TwitterWeb do
  pipe_through :api

  forward "/", McpRouter
end
```

This makes the production MCP server available at `/api/mcp`.

### 6. Implement Token Verification

We referenced `Twitter.Accounts.verify_access_token/1` above, but it doesn't
exist yet. Let's create it.

Open `lib/twitter/accounts.ex` and add:

```elixir
def verify_access_token(token) do
  require Ash.Query

  Token
  |> Ash.Query.filter(token == ^token)
  |> Ash.Query.filter(expires_at > ^DateTime.utc_now())
  |> Ash.read_one()
  |> case do
    {:ok, %Token{user: user}} when not is_nil(user) ->
      {:ok, user}

    {:ok, token} ->
      # Load the user if not already loaded
      token
      |> Ash.load!(:user)
      |> then(fn %{user: user} -> {:ok, user} end)

    {:error, _} ->
      {:error, :invalid_token}

    _ ->
      {:error, :invalid_token}
  end
end
```

### 7. Configure OAuth (Optional)

For more sophisticated authentication, you can integrate OAuth. AshAi's MCP
implementation supports OAuth integration with AshAuthentication.

Update your MCP router to use OAuth:

```elixir
forward "/",
  to: AshAi.Mcp,
  init_opts: [
    domains: [Twitter.Tweets],
    allow_tools: [:read_feed, :get_tweet, :create_tweet],
    oauth: [
      domain: Twitter.Accounts,
      provider: :oauth2,
      authorize_url: "/oauth/authorize",
      token_url: "/oauth/token"
    ]
  ]
```

### 8. Test Production MCP Server

Test the authenticated endpoint:

```bash
# First, get a token by signing in
# Then use it to call the MCP server
curl -X POST http://localhost:4000/api/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list"
  }'
```

You should see only the allowed tools (read_feed, get_tweet, create_tweet).

### 9. Configure Tool Visibility

You can control which fields are exposed through MCP by using the `public?`
option on attributes and the `allow_tools` configuration.

In `lib/twitter/tweets/tweet.ex`, ensure sensitive fields are not public:

```elixir
# Public field - will be exposed via MCP
attribute :text, :string do
  public? true
end

# Private field - will NOT be exposed via MCP
attribute :internal_notes, :string do
  public? false
end
```

### 10. Monitor MCP Usage

Add logging to track MCP tool usage. Create a custom plug in your MCP router:

```elixir
defmodule TwitterWeb.McpRouter do
  use Plug.Router
  require Logger

  plug :log_request
  plug :match
  plug :dispatch

  def log_request(conn, _opts) do
    Plug.Conn.register_before_send(conn, fn conn ->
      Logger.info("MCP Request: #{inspect(conn.body_params)}")
      conn
    end)

    conn
  end

  # ... rest of the code ...
end
```

## Try on your own

- Add rate limiting to the production MCP server using a library like
  `PlugAttack`

- Create different MCP server configurations for different user roles (admin vs
  regular user)

- Expose additional domains through the dev MCP server and test them with your
  IDE

- Implement session-based authentication instead of token-based for the
  production MCP

- Add telemetry events to track which tools are being called most frequently

- Configure the MCP server to support Server-Sent Events (SSE) for streaming
  responses

- Create a web interface to manage which tools are exposed via the production
  MCP server

## Verification

To verify your setup:

1. **Dev Server**: Check that `http://localhost:4000/ash_ai/mcp` returns a valid
   MCP response
2. **Tool Listing**: Verify that calling `tools/list` returns all expected tools
3. **Authentication**: Confirm that the production MCP server rejects requests
   without valid tokens
4. **Tool Execution**: Test calling a tool through the MCP server and verify it
   executes correctly
5. **IDE Integration**: If using Cursor/Zed, verify that your AI assistant can
   see and call your tools

## Notes on Protocol Version

As of this writing, AshAi implements MCP protocol version `2025-03-26`. Some
tools may not have updated to support this version yet. If you encounter
compatibility issues, you may need to:

1. Check your AI tool's documentation for MCP support
2. Consider implementing a compatibility layer/proxy
3. Contact the tool vendor about MCP protocol support

AshAi's MCP implementation follows the streamable HTTP transport specification,
which means:

- Requests and responses use JSON-RPC 2.0 format
- Sessions are managed with unique session IDs
- Both standard JSON and Server-Sent Events (SSE) responses are supported
- Batch requests are supported for efficiency
