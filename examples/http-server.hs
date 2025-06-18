{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

{- |
Example HTTP MCP Server

This example demonstrates how to run the MCP server over HTTP transport.
The server will expose the MCP API at POST /mcp

To test:
1. Compile: cabal build mcp-http
2. Run: cabal run mcp-http
3. Send JSON-RPC requests to: http://localhost:<port>/mcp

Example request:
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'

Command line options:
cabal run mcp-http -- --port 8080 --log
-}
module Main where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Options.Applicative

import MCP.Protocol hiding (CompletionResult)
import MCP.Protocol qualified as Protocol
import MCP.Server
import MCP.Server.Auth
import MCP.Server.HTTP
import MCP.Types

-- | Command line options
data Options = Options
    { optPort :: Int
    , optEnableLogging :: Bool
    , optEnableOAuth :: Bool
    }
    deriving (Show)

-- | Parser for command line options
optionsParser :: Parser Options
optionsParser =
    Options
        <$> option
            auto
            ( long "port"
                <> short 'p'
                <> metavar "PORT"
                <> Options.Applicative.value 8080
                <> help "Port to run the HTTP server on (default: 8080)"
            )
        <*> switch
            ( long "log"
                <> short 'l'
                <> help "Enable request/response logging"
            )
        <*> switch
            ( long "oauth"
                <> short 'o'
                <> help "Enable OAuth authentication (demo mode)"
            )

-- | Full parser with help
opts :: ParserInfo Options
opts =
    info
        (optionsParser <**> helper)
        ( fullDesc
            <> progDesc "Run an MCP server over HTTP transport"
            <> header "mcp-http - HTTP MCP Server Example"
        )

-- | Example MCP Server implementation (copied from Main.hs)
instance MCPServer MCPServerM where
    handleListResources _params = do
        return $ ListResourcesResult{resources = [], nextCursor = Nothing, _meta = Nothing}

    handleReadResource _params = do
        let textContent = TextResourceContents{uri = "example://hello", text = "Hello from MCP Haskell HTTP server!", mimeType = Just "text/plain", _meta = Nothing}
        let content = TextResource textContent
        return $ ReadResourceResult{contents = [content], _meta = Nothing}

    handleListResourceTemplates _params = do
        return $ ListResourceTemplatesResult{resourceTemplates = [], nextCursor = Nothing, _meta = Nothing}

    handleListPrompts _params = do
        return $ ListPromptsResult{prompts = [], nextCursor = Nothing, _meta = Nothing}

    handleGetPrompt _params = do
        let textContent = TextContent{text = "Hello HTTP prompt!", textType = "text", annotations = Nothing, _meta = Nothing}
        let content = TextContentType textContent
        let message = PromptMessage{role = User, content = content}
        return $ GetPromptResult{messages = [message], description = Nothing, _meta = Nothing}

    handleListTools _params = do
        let getCurrentDateTool =
                Tool
                    { name = "getCurrentDate"
                    , title = Nothing
                    , description = Just "Get the current date and time via HTTP"
                    , inputSchema = InputSchema "object" Nothing Nothing
                    , outputSchema = Nothing
                    , annotations = Nothing
                    , _meta = Nothing
                    }
        return $ ListToolsResult{tools = [getCurrentDateTool], nextCursor = Nothing, _meta = Nothing}

    handleCallTool CallToolParams{name = toolName} = do
        case toolName of
            "getCurrentDate" -> do
                currentTime <- liftIO getCurrentTime
                let dateStr = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC (via HTTP)" currentTime
                let textContent = TextContent{text = T.pack dateStr, textType = "text", annotations = Nothing, _meta = Nothing}
                let content = TextContentType textContent
                return $ CallToolResult{content = [content], structuredContent = Nothing, isError = Nothing, _meta = Nothing}
            _ -> do
                let textContent = TextContent{text = "Tool not found", textType = "text", annotations = Nothing, _meta = Nothing}
                let content = TextContentType textContent
                return $ CallToolResult{content = [content], structuredContent = Nothing, isError = Just True, _meta = Nothing}

    handleComplete _params = do
        let completionResult = Protocol.CompletionResult{values = [], total = Nothing, hasMore = Just True}
        return $ CompleteResult{completion = completionResult, _meta = Nothing}

    handleSetLevel _params = do
        liftIO $ putStrLn "Log level set via HTTP"

main :: IO ()
main = do
    Options{..} <- execParser opts

    putStrLn "Starting MCP Haskell HTTP Server..."
    putStrLn $ "Port: " ++ show optPort
    when optEnableLogging $ putStrLn "Request/Response logging: enabled"

    let serverInfo =
            Implementation
                { name = "mcp-haskell-http-example"
                , title = Nothing
                , version = "0.1.0"
                }

    let resourcesCap =
            ResourcesCapability
                { subscribe = Just False
                , listChanged = Just False
                }
    let promptsCap =
            PromptsCapability
                { listChanged = Just False
                }
    let toolsCap =
            ToolsCapability
                { listChanged = Just False
                }

    let capabilities =
            ServerCapabilities
                { resources = Just resourcesCap
                , prompts = Just promptsCap
                , tools = Just toolsCap
                , completions = Nothing
                , logging = Nothing
                , experimental = Nothing
                }

    let baseUrl = T.pack $ "http://localhost:" ++ show optPort
        oauthConfig =
            if optEnableOAuth
                then
                    Just $
                        defaultDemoOAuthConfig
                            { oauthProviders =
                                [ OAuthProvider
                                    { providerName = "demo"
                                    , clientId = "demo-client"
                                    , clientSecret = Just "demo-secret"
                                    , authorizationEndpoint = baseUrl <> "/authorize"
                                    , tokenEndpoint = baseUrl <> "/token"
                                    , userInfoEndpoint = Nothing
                                    , scopes = ["mcp:read", "mcp:write"]
                                    , grantTypes = [AuthorizationCode]
                                    , requiresPKCE = True -- MCP requires PKCE
                                    , metadataEndpoint = Nothing
                                    }
                                ]
                            , -- Override demo defaults for example
                              authCodeExpirySeconds = 600 -- 10 minutes
                            , accessTokenExpirySeconds = 3600 -- 1 hour
                            , demoUserIdTemplate = Just "demo-user-{clientId}"
                            , demoEmailDomain = "demo.example.com"
                            , demoUserName = "Demo User"
                            , authorizationSuccessTemplate =
                                Just $
                                    "Demo Authorization Successful!\n\n"
                                        <> "Redirect to: {redirectUri}?code={code}{state}\n\n"
                                        <> "This is a demo server. In production, this would redirect automatically."
                            }
                else Nothing

    let config =
            HTTPServerConfig
                { httpPort = optPort
                , httpBaseUrl = baseUrl -- Configurable base URL
                , httpServerInfo = serverInfo
                , httpCapabilities = capabilities
                , httpEnableLogging = optEnableLogging
                , httpOAuthConfig = oauthConfig
                , httpJWK = Nothing -- Will be auto-generated
                , httpProtocolVersion = mcpProtocolVersion -- Current MCP protocol version
                }

    putStrLn $ "HTTP server configured, starting on port " ++ show optPort ++ "..."
    putStrLn $ "MCP endpoint available at: POST " ++ T.unpack baseUrl ++ "/mcp"

    if optEnableOAuth
        then do
            putStrLn ""
            putStrLn "OAuth Demo Flow:"
            putStrLn "1. Generate PKCE code verifier and challenge"
            putStrLn "2. Open authorization URL in browser:"
            putStrLn $ "   " ++ T.unpack baseUrl ++ "/authorize?response_type=code&client_id=demo-client&redirect_uri=http://localhost:3000/callback&code_challenge=YOUR_CHALLENGE&code_challenge_method=S256&scope=mcp:read%20mcp:write"
            putStrLn "3. Exchange authorization code for token:"
            putStrLn $ "   curl -X POST " ++ T.unpack baseUrl ++ "/token \\"
            putStrLn "     -H \"Content-Type: application/x-www-form-urlencoded\" \\"
            putStrLn "     -d \"grant_type=authorization_code&code=AUTH_CODE&code_verifier=YOUR_VERIFIER\""
            putStrLn "4. Use access token for MCP requests:"
            putStrLn $ "   curl -X POST " ++ T.unpack baseUrl ++ "/mcp \\"
            putStrLn "     -H \"Authorization: Bearer ACCESS_TOKEN\" \\"
            putStrLn "     -H \"Content-Type: application/json\" \\"
            putStrLn "     -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}'"
        else do
            putStrLn ""
            putStrLn "Example test command:"
            putStrLn $ "curl -X POST " ++ T.unpack baseUrl ++ "/mcp \\"
            putStrLn "  -H \"Content-Type: application/json\" \\"
            putStrLn "  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}'"

    putStrLn ""

    runServerHTTP config
