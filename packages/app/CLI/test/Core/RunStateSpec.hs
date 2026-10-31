{-# LANGUAGE OverloadedStrings #-}

-- | The pure half of 'Core.RunState': the service parser, the @\/proc@ cmdline
-- check that refuses a recycled pid, and the operator-facing text.
--
-- The file-IO half (write/read/remove) is exercised by `trha status` and
-- `trha stop` against real processes; it is deliberately not unit-tested here
-- because it would write into the user's real @~/.trha@.
module Core.RunStateSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.Aeson (Value(..), object, (.=))
import Test.Hspec

import Core.RunState

spec :: Spec
spec = describe "Core.RunState" $ do
  describe "parseService" $ do
    it "accepts kernel/scheduler in any case" $ do
      parseService "kernel"    `shouldBe` Just Kernel
      parseService "KERNEL"    `shouldBe` Just Kernel
      parseService "Scheduler" `shouldBe` Just Scheduler

    it "does not treat a typo as 'all'" $ do
      parseService "all"    `shouldBe` Nothing
      parseService "kernal" `shouldBe` Nothing

  describe "looksLikeOurProcess (pid-reuse guard)" $ do
    it "recognises the kernel" $
      looksLikeOurProcess Kernel "/x/trha\0serve\0--kernel-port\019433\0" `shouldBe` True

    it "recognises the stub kernel" $
      looksLikeOurProcess Kernel "/x/trha-kernel-stub\019433\0" `shouldBe` True

    it "recognises the scheduler" $
      looksLikeOurProcess Scheduler "node\0/x/packages/scheduler/dist/cli.js\0" `shouldBe` True

    it "refuses an unrelated process holding a recycled pid" $ do
      looksLikeOurProcess Kernel "python3\0-m\0http.server\0" `shouldBe` False
      looksLikeOurProcess Scheduler "/usr/bin/vim\0notes.md\0" `shouldBe` False

    it "does not confuse the two services" $ do
      looksLikeOurProcess Kernel "node\0/x/dist/cli.js\0" `shouldBe` False
      looksLikeOurProcess Scheduler "/x/trha\0serve\0" `shouldBe` False

  describe "parseRuntimeEntry (runtime.json)" $ do
    it "reads a complete scheduler section" $
      parseRuntimeEntry Scheduler
        (object [ "scheduler" .= object
            [ "host" .= ("127.0.0.1" :: String)
            , "port" .= (28433 :: Int)
            , "pid"  .= (4242 :: Int)
            , "token" .= ("t0ken" :: String)
            , "startedAt" .= (1.5 :: Double) ] ])
        `shouldBe` Just (RuntimeEntry "127.0.0.1" 28433 4242 "t0ken" 1.5)

    it "defaults startedAt when the writer omitted it (kernel)" $
      parseRuntimeEntry Kernel
        (object [ "kernel" .= object
            [ "host" .= ("127.0.0.1" :: String)
            , "port" .= (19433 :: Int)
            , "pid"  .= (7 :: Int)
            , "token" .= ("abc" :: String) ] ])
        `shouldBe` Just (RuntimeEntry "127.0.0.1" 19433 7 "abc" 0)

    it "returns Nothing for a missing section or a missing field" $ do
      parseRuntimeEntry Scheduler (object [ "kernel" .= object [] ]) `shouldBe` Nothing
      parseRuntimeEntry Scheduler (object [ "scheduler" .= object [ "host" .= ("x" :: String) ] ])
        `shouldBe` Nothing
      parseRuntimeEntry Scheduler (String "?") `shouldBe` Nothing

  describe "stopResultText" $ do
    it "names the service and says what happened" $ do
      stopResultText Kernel NotRunning `shouldSatisfy` ("kernel" `isInfixOf`)
      stopResultText Scheduler (Stopped 42) `shouldSatisfy` ("scheduler" `isInfixOf`)
      stopResultText Scheduler (Stopped 42) `shouldSatisfy` ("42" `isInfixOf`)
      stopResultText Kernel (Timeout 7) `shouldSatisfy` ("--force" `isInfixOf`)
      stopResultText Kernel (Refused 7 "not ours") `shouldSatisfy` ("refused" `isInfixOf`)

  describe "statusText" $ do
    it "reports pid and liveness per service" $
      statusText [ ServiceStatus Kernel (Just 10) True
                 , ServiceStatus Scheduler Nothing False ]
        `shouldBe` unlines
          [ "kernel: pid 10 (running)"
          , "scheduler: (no pid file) (not running)" ]
  describe "zombieStat" $ do
    it "treats a Z state as gone" $
      zombieStat "1234 (trha) Z 1 1234 1234 0 -1 4194560" `shouldBe` True

    it "keeps a running process alive" $
      zombieStat "1234 (trha) S 1 1234 1234 0 -1 4194560" `shouldBe` False

    -- comm may contain spaces and parentheses: "node (dist/cli.js)"
    it "finds the state after a comm containing parens and spaces" $
      zombieStat "77 (node (dist/cli.js)) Z 1 77 77 0 -1 0" `shouldBe` True

    it "does not mistake the state letter for part of comm" $
      zombieStat "9 (a) R 1 9 9" `shouldBe` False
  where
    isInfixOf needle hay = BC.pack needle `BC.isInfixOf` BC.pack hay
