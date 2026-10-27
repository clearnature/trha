{-# LANGUAGE OverloadedStrings #-}

import Test.Hspec
import Test.QuickCheck
import Core.Types
import Core.Client
import Core.HTTP
import Client.Session
import Client.Agent
import Client.Tool
import Client.Model
import Utils.Logger
import Utils.Retry

main :: IO ()
main = hspec $ do
  describe "Core.Types" $ do
    it "can create default config" $ do
      let config = defaultConfig
      configHost config `shouldBe` "localhost"
      configPort config `shouldBe` 3000

  describe "Core.Client" $ do
    it "can create SDK client" $ do
      client <- createClient "localhost" 3000
      configPort (clientConfig client) `shouldBe` 3000

  describe "Core.HTTP" $ do
    it "can build URL" $ do
      client <- createHTTPClient "localhost" 3000
      let url = buildUrl client "/api/test"
      url `shouldBe` "http://localhost:3000/api/test"

  describe "Client.Session" $ do
    it "can create session client" $ do
      sdk <- createClient "localhost" 3000
      let client = createSessionClient sdk
      clientConfig (sessionClientSDK client) `shouldBe` clientConfig sdk

  describe "Client.Agent" $ do
    it "can create agent client" $ do
      sdk <- createClient "localhost" 3000
      let client = createAgentClient sdk
      clientConfig (agentClientSDK client) `shouldBe` clientConfig sdk

  describe "Client.Tool" $ do
    it "can create tool client" $ do
      sdk <- createClient "localhost" 3000
      let client = createToolClient sdk
      clientConfig (toolClientSDK client) `shouldBe` clientConfig sdk

  describe "Client.Model" $ do
    it "can create model client" $ do
      sdk <- createClient "localhost" 3000
      let client = createModelClient sdk
      clientConfig (modelClientSDK client) `shouldBe` clientConfig sdk

  describe "Utils.Logger" $ do
    it "can create logger" $ do
      let logger = createLogger Info "test"
      loggerLevel logger `shouldBe` Info
      loggerPrefix logger `shouldBe` "test"

  describe "Utils.Retry" $ do
    it "can create retry config" $ do
      let config = defaultRetryConfig
      retryMaxAttempts config `shouldBe` 3
      retryDelay config `shouldBe` 1000