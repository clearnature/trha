-- | Persistence contract for kernel sessions.
--
-- Two levels, because they fail for different reasons:
--
--   * the store level pins the on-disk format and the degrade-to-nothing
--     behaviour (missing dir, corrupt file);
--   * the assembly level starts two real kernel instances against the same
--     state directory and checks that the second one resumes the FSM state the
--     first one persisted. Without it, "we persist sessions" would only mean
--     "some function writes a file".
{-# LANGUAGE OverloadedStrings #-}

module SessionPersistSpec (sessionPersistSpec) where

import Control.Exception (bracket)
import Data.Aeson (Value, decode, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (isInfixOf)
import qualified Data.List as List
import qualified Data.Text as T
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import System.Directory
import System.FilePath (takeFileName, (</>))
import Test.Hspec

import API.Server (mkStubApp)
import Core.Agent.StateMachine (AgentCommand (..))
import Core.Agent.Types (AgentState (..), Result (..))
import Core.Session.Manager
import Core.Session.Types
import Data.Dynamic (toDyn)
import qualified Infrastructure.Storage.SessionStore as SS

-- | Throwaway state directory, removed even when a test fails.
withScratch :: (FilePath -> IO a) -> IO a
withScratch act = bracket acquire release act
  where
    root = "trha-session-persist-spec"
    acquire = do
      tmp <- getTemporaryDirectory
      let dir = tmp </> root
      removePathForcibly dir
      createDirectoryIfMissing True dir
      pure dir
    release dir = removePathForcibly dir

sessionPersistSpec :: Spec
sessionPersistSpec = do
  describe "Core.Session persistence — snapshot ↔ disk" $ do
    it "round-trips identity + FSM state and drops derived state" $ withScratch $ \dir -> do
      s0 <- createSession "sess-1"
      _ <- advanceAgent s0 (StartCommand "sess-1")
      setProjection s0 "t6state" (toDyn ("polar" :: String))
      snap <- snapshotSession s0
      SS.saveSessionSnapshot dir (snapshotId snap) snap

      loaded <- SS.loadSessionSnapshot dir "sess-1"
      case loaded of
        Nothing -> expectationFailure "snapshot was not readable back"
        Just snap' -> do
          snapshotId snap' `shouldBe` "sess-1"
          snapshotAgentState snap' `shouldBe` Processing "step-1"
          -- the restart path rebuilds a live session from the snapshot
          s1 <- restoreSession snap'
          sessionId s1 `shouldBe` "sess-1"
          getAgentState s1 >>= (`shouldBe` Processing "step-1")
          -- projections are derived state (Dynamic): recomputed, not persisted
          projectionNames s1 >>= (`shouldBe` [])

    it "keeps a terminal state's payload (Completed carries the result)" $ withScratch $ \dir -> do
      s0 <- createSession "sess-2"
      _ <- advanceAgent s0 (StartCommand "sess-2")
      _ <- advanceAgent s0 (CompleteCommand (Result "done" 7))
      snap <- snapshotSession s0
      SS.saveSessionSnapshot dir "sess-2" snap
      SS.loadSessionSnapshot dir "sess-2" `shouldReturn` Just snap
      SS.loadSessionSnapshot dir "sess-2"
        >>= \r -> (snapshotAgentState <$> r) `shouldBe` Just (Completed (Result "done" 7))

    it "encodes a versioned object, so a future format change is detectable" $ do
      snap <- snapshotSession =<< createSession "sess-3"
      let bytes = encode snap
      ("\"v\":1" `isInfixOf` BLC.unpack bytes) -- sanity: decoder below is the real check
        `shouldBe` True
      (decode bytes :: Maybe SessionSnapshot) `shouldBe` Just snap

    it "returns Nothing for an unknown id and [] for a missing directory" $ withScratch $ \dir -> do
      SS.loadSessionSnapshot dir "nobody" `shouldReturn` (Nothing :: Maybe SessionSnapshot)
      SS.listSessionSnapshots (dir </> "does-not-exist")
        >>= (`shouldBe` ([] :: [SessionSnapshot]))

    it "lists every persisted session, newest content intact" $ withScratch $ \dir -> do
      mapM_ (\sid -> do
        s <- createSession sid
        _ <- advanceAgent s (StartCommand sid)
        snap <- snapshotSession s
        SS.saveSessionSnapshot dir sid snap) ["a", "b", "c"]
      snaps <- SS.listSessionSnapshots dir
      List.sort (map snapshotId snaps) `shouldBe` ["a", "b", "c"]
      map snapshotAgentState snaps `shouldBe` replicate 3 (Processing "step-1")

    it "skips a corrupt snapshot instead of failing the whole load" $ withScratch $ \dir -> do
      s <- createSession "good"
      snap <- snapshotSession s
      SS.saveSessionSnapshot dir "good" snap
      BL.writeFile (SS.snapshotPath dir "bad") "{not json"
      SS.listSessionSnapshots dir `shouldReturn` [snap]
      SS.loadSessionSnapshot dir "bad" `shouldReturn` (Nothing :: Maybe SessionSnapshot)

    it "deletes on demand and tolerates a second delete" $ withScratch $ \dir -> do
      s <- createSession "gone"
      snap <- snapshotSession s
      SS.saveSessionSnapshot dir "gone" snap
      SS.loadSessionSnapshot dir "gone" >>= (`shouldBe` Just snap)
      SS.deleteSessionSnapshot dir "gone"
      SS.loadSessionSnapshot dir "gone" `shouldReturn` (Nothing :: Maybe SessionSnapshot)
      SS.deleteSessionSnapshot dir "gone"  -- must not throw

    it "keeps host-supplied ids file-safe (no path traversal, no subdirs)" $ withScratch $ \dir -> do
      let p = SS.snapshotPath dir "../../etc/passwd"
      takeFileName p `shouldBe` ".._.._etc_passwd.json"
      -- one level down (the store's namespace), never escaping the state dir
      p `shouldBe` (dir </> "kernel" </> takeFileName p)

    it "namespaces its files, so the scheduler's per-session JSON survives" $ withScratch $ \dir -> do
      -- Same directory, same session id, different owner: the two stores must
      -- not overwrite each other (they would both use <id>.json at the top).
      let sid = "session-1750000000000"
          scheduler = "{\"v\":1,\"sessionId\":\"" ++ sid
                   ++ "\",\"mode\":\"standard\",\"messages\":[]}"
      BL.writeFile (dir </> (sid ++ ".json")) (BLC.pack scheduler)
      s <- createSession sid
      snap <- snapshotSession s
      SS.saveSessionSnapshot dir sid snap
      -- the scheduler's record is untouched...
      BL.readFile (dir </> (sid ++ ".json")) `shouldReturn` BLC.pack scheduler
      -- ...and the kernel reads back only its own file
      SS.loadSessionSnapshot dir sid `shouldReturn` Just snap
      -- a scheduler-only directory yields no snapshots at all
      SS.listSessionSnapshots dir `shouldReturn` [snap]

  describe "API.Server — kernel restart resumes the persisted session (HTTP, 真实 warp)" $ do
    let withApp :: IO Application -> (Manager -> String -> IO a) -> IO a
        withApp app act =
          testWithApplication app $ \port -> do
            mgr <- newManager defaultManagerSettings
            act mgr ("http://127.0.0.1:" ++ show port)

        httpPost :: Manager -> String -> Value -> IO (Int, String)
        httpPost mgr url body = do
          req0 <- parseRequest ("POST " ++ url)
          let req = req0 { method         = "POST"
                         , requestBody    = RequestBodyLBS (encode body)
                         , requestHeaders = [("Content-Type", "application/json")]
                         }
          res <- httpLbs req mgr
          pure (statusCode (responseStatus res), BLC.unpack (responseBody res))

        startBody = object
          [ "mode"      .= ("standard" :: T.Text)
          , "sessionId" .= ("restart-1" :: T.Text)
          ]
        stepBody = object
          [ "sessionId" .= ("restart-1" :: T.Text)
          , "message"   .= ("hi" :: T.Text)
          ]

    it "a fresh instance continues where the previous one stopped" $ withScratch $ \dir -> do
      -- instance 1: one step drives the FSM Idle → Processing and persists it
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c0, _) <- httpPost mgr (base ++ "/session/start") startBody
        c0 `shouldBe` 200
        (c1, body1) <- httpPost mgr (base ++ "/agent/step") stepBody
        c1 `shouldBe` 200
        body1 `shouldSatisfy` ("Idle" `isInfixOf`)          -- before: Idle
        body1 `shouldSatisfy` ("Processing" `isInfixOf`)     -- after: Processing

      -- instance 2: nothing shared in memory, only the state directory.
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        -- (a) resuming needs no /session/start at all
        (c2, body2) <- httpPost mgr (base ++ "/agent/step") stepBody
        c2 `shouldBe` 200                                    -- 404 ⇒ nothing restored
        -- "before" must be the persisted state, not a fresh Idle
        body2 `shouldSatisfy` (not . ("Idle" `isInfixOf`))

        -- (b) the scheduler's real restore path re-registers the id it
        -- restored (Server/index.ts). That call has to be idempotent: it may
        -- not reset the FSM the kernel just loaded from disk.
        (c3, body3) <- httpPost mgr (base ++ "/session/start") startBody
        c3 `shouldBe` 200
        body3 `shouldSatisfy` ("\"resumed\":true" `isInfixOf`)
        body3 `shouldSatisfy` (not . ("Idle" `isInfixOf`))
        (c4, body4) <- httpPost mgr (base ++ "/agent/step") stepBody
        c4 `shouldBe` 200
        body4 `shouldSatisfy` (not . ("Idle" `isInfixOf`))

    it "a brand-new id reports resumed:false" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c, body) <- httpPost mgr (base ++ "/session/start") startBody
        c `shouldBe` 200
        body `shouldSatisfy` ("\"resumed\":false" `isInfixOf`)

    it "deleting a session drops its snapshot (no resurrection after restart)" $ withScratch $ \dir -> do
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c0, _) <- httpPost mgr (base ++ "/session/start") startBody
        c0 `shouldBe` 200
        (c1, _) <- httpPost mgr (base ++ "/agent/step") stepBody
        c1 `shouldBe` 200
        req0 <- parseRequest ("DELETE " ++ base ++ "/session/restart-1")
        res <- httpLbs (req0 { method = "DELETE" }) mgr
        statusCode (responseStatus res) `shouldBe` 200
      -- the snapshot is gone, so a restarted kernel cannot bring it back
      SS.loadSessionSnapshot dir "restart-1"
        `shouldReturn` (Nothing :: Maybe SessionSnapshot)
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c2, _) <- httpPost mgr (base ++ "/agent/step") stepBody
        c2 `shouldBe` 404

    it "an empty state directory starts clean (no phantom sessions)" $ withScratch $ \dir ->
      withApp (mkStubApp (Just dir)) $ \mgr base -> do
        (c, _) <- httpPost mgr (base ++ "/agent/step") stepBody
        c `shouldBe` 404
