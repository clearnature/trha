{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 元信息类命令：帮助、退出、停止确认、关于、状态、自检、供应商探测、更新。
--
-- 领域模块之一（约定见 "UI.Commands.Env"）：认领自己的分支返回 @Just@，
-- 其余返回 @Nothing@；@UI.Commands.executeCommand@ 用 'dispatch' 串起各域。
module UI.Commands.Meta
  ( runMeta
  ) where

import Control.Exception (IOException, try)
import Data.IORef (readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (getCurrentDirectory, getHomeDirectory)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode, readProcessWithExitCode)
import System.Timeout (timeout)

import Bridge.Scheduler (fetchServiceStatus, listProviders, listSessions, probeProvider)
import Config.Settings (resolveConfig)
import Core.Types (CLIConfig(..), ProviderInfo(..), defaultCLIConfig)
import UI.Commands.Env (CmdEnv(..))
import UI.Commands.Registry (Command(..), registryHelp)
import UI.Commands.Tools (gitCount, readProviderKey)
import UI.I18n (Lang(..), langName, tr)

-- | 认领「界面自身信息」与「本地环境自检」相关的分支。
runMeta :: CmdEnv -> Command -> Maybe (IO (Maybe Text))
runMeta env = go
  where
    lang       = ceLang env
    bridge     = ceBridge env
    sessionRef = ceSession env
    modelRef   = ceModel env

    go Help = Just (pure (Just (registryHelp lang)))
    go Quit = Just (pure Nothing)
    go StopRequest =
      Just . pure . Just $
        tr lang "This stops the kernel and scheduler and exits. Type /stop confirm to proceed."
    go StopConfirmed = Just (pure Nothing)
    go About = Just $ do
      cwd <- getCurrentDirectory
      home <- getHomeDirectory
      (lspLines, mcpLines) <- fetchServiceStatus bridge
      pure . Just . T.unlines $
        [ "trha \183 " <> tr lang "agent harness"
        , tr lang "Working directory: " <> T.pack cwd
        , tr lang "Config: " <> T.pack (home </> ".trha")
        , tr lang "LSP: " <> T.intercalate ", " lspLines
        , tr lang "MCP: " <> T.intercalate ", " mcpLines
        ]

    go Status = Just $ do
      session <- readIORef sessionRef
      model <- readIORef modelRef
      return $ Just $ T.unlines
        [ tr lang "Status:"
        , tr lang "  Current session: " <> maybe (tr lang "none") T.pack session
        , tr lang "  Current model: " <> model
        ]

    go Doctor = Just $ do
      sessions <- listSessions bridge
      providers <- listProviders bridge
      cfg <- resolveConfig defaultCLIConfig
      font <- try (readProcessWithExitCode "fc-match" ["-f", "%{file}", ":lang=zh-Hans"] "")
                :: IO (Either IOException (ExitCode, String, String))
      let fontLine = case font of
            Right (_, out, _) -> T.strip (T.pack out)
            Left _ -> tr lang "fontconfig unavailable"
      return $ Just $ T.unlines
        [ tr lang "Doctor:"
        , tr lang "  scheduler: " <> either (const (tr lang "unreachable")) (const (tr lang "ok")) sessions
        , tr lang "  providers: " <> either (const (tr lang "unreachable")) (T.pack . show . length) providers
        , tr lang "  language: " <> langName lang
        , tr lang "  context: " <> maybe (tr lang "model default") (T.pack . show) (configCtxSize cfg)
        , tr lang "  font: " <> fontLine
        ]

    go (Auth arg) = Just $ do
      ps <- listProviders bridge
      case ps of
        Left e -> return $ Just (tr lang "Error: " <> T.pack (show e))
        Right infos -> case T.words arg of
          [] -> return $ Just $ T.unlines
            (tr lang "Providers:"
             : [ "  - " <> piName p <> " (" <> piKind p <> ")"
                 <> (if piHasKey p then " \183 key saved" else " \183 no key")
                 <> (if piInUse p then " \183 in use" else "")
               | p <- infos ])
          ("check" : name : _) -> case [ p | p <- infos, piName p == name ] of
            [] -> return $ Just (tr lang "Unknown provider: " <> name)
            (p : _) -> do
              mkey <- readProviderKey (piName p)
              case mkey of
                Nothing -> return $ Just $ tr lang "No key saved for " <> name
                Just key -> do
                  r <- probeProvider bridge (piBaseUrl p) key
                  return $ Just $ case r of
                    Left e -> tr lang "Probe failed: " <> T.pack (show e)
                    Right probed -> tr lang "Probe ok: " <> T.pack (show probed)
          _ -> return $ Just (tr lang "Usage: /auth [check <name>]")

    -- | @/update@：本地源码部署下和 origin/main 比对；@/update pull@ 快进。
    go (Update arg) = Just $ do
      cwd <- getCurrentDirectory
      let git xs = readCreateProcessWithExitCode (proc "git" ("-C" : cwd : xs)) ""
      top <- git ["rev-parse", "--show-toplevel"]
      case top of
        (ExitFailure _, _, _) -> return $ Just $ tr lang "Not a git checkout: " <> T.pack cwd
        _ -> do
          fetched <- timeout 60000000 (git ["fetch", "--quiet", "origin"])
          case fetched of
            Nothing -> return $ Just (tr lang "git fetch timed out.")
            Just (ExitFailure _, _, err) ->
              return $ Just $ tr lang "git fetch failed: " <> T.pack (take 300 err)
            Just _ -> case T.strip arg of
              "pull" -> do
                pulled <- git ["pull", "--ff-only", "origin", "main"]
                return $ Just $ case pulled of
                  (ExitSuccess, out, _) -> tr lang "Updated:\n" <> T.pack out
                  (ExitFailure _, _, err) -> tr lang "Pull failed: " <> T.pack err
              _ -> do
                behind <- git ["rev-list", "--count", "HEAD..origin/main"]
                ahead  <- git ["rev-list", "--count", "origin/main..HEAD"]
                return $ Just $ T.unlines
                  [ tr lang "Behind origin/main: " <> gitCount behind
                  , tr lang "Ahead of origin/main: " <> gitCount ahead
                  , tr lang "Run /update pull to fast-forward." ]

    go _ = Nothing
