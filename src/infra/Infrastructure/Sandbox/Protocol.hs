{-# LANGUAGE OverloadedStrings #-}

-- | NDJSON v1 protocol between the scheduler and the sandbox runner
-- (docs/plans/sandbox-architecture.md §5.7.3).
--
-- Every frame is one JSON object on one line. Unknown @op@ values are
-- rejected; frames larger than 'maxFrameBytes' are rejected before parsing.
module Infrastructure.Sandbox.Protocol
  ( ProtocolError(..)
  , protocolVersion
  , maxFrameBytes
  , Frame(..)
  , encodeFrame
  , decodeFrame
  , frameOp
  ) where

import Data.Aeson
  ( FromJSON(..), ToJSON(..), Value, object, withObject, (.:), (.:?), (.=) )
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Infrastructure.Sandbox.Error (ProbeResult(..))

protocolVersion :: Int
protocolVersion = 1

-- | One mebibyte per frame.
maxFrameBytes :: Int
maxFrameBytes = 1024 * 1024

data ProtocolError
  = FrameTooLarge Int
  | MalformedFrame Text
  | UnknownOp Text
  | VersionMismatch Int
  deriving (Eq, Show)

-- | The complete v1 frame set. Record prefixes keep field names distinct.
data Frame
  = Hello
      { helloScope     :: Text
      , helloParent    :: Maybe Text
      , helloPolicy    :: Text
      , helloIsolation :: Text
      }
  | Ready
      { readyBackend      :: Text
      , readyEnforcement  :: Text
      , readyCapabilities :: Value
      , readyPid          :: Int
      }
  | Exec
      { execId        :: Text
      , execArgv      :: [Text]
      , execCwd       :: Text
      , execEnv       :: [(Text, Text)]
      , execStdin     :: Maybe Text
      , execTimeoutMs :: Maybe Int
      }
  | Stdin  { stdinId :: Text, stdinData :: Text }
  | Stdout { stdoutId :: Text, stdoutData :: Text }
  | Stderr { stderrId :: Text, stderrData :: Text }
  | Exit   { exitId :: Text, exitCode :: Int, exitSignal :: Maybe Text }
  | Deny   { denyId :: Text, denyKind :: Text, denyTarget :: Text }
  | Probe  { probeResults :: [ProbeResult] }
  | Audit  { auditEvents :: [Value] }
  | Error  { errorId :: Maybe Text, errorCode :: Text, errorMessage :: Text }
  | Shutdown
  deriving (Eq, Show)

frameOp :: Frame -> Text
frameOp frame = case frame of
  Hello{} -> "hello"
  Ready{} -> "ready"
  Exec{} -> "exec"
  Stdin{} -> "stdin"
  Stdout{} -> "stdout"
  Stderr{} -> "stderr"
  Exit{} -> "exit"
  Deny{} -> "deny"
  Probe{} -> "probe"
  Audit{} -> "audit"
  Error{} -> "error"
  Shutdown -> "shutdown"

-- Encoding ---------------------------------------------------------------

instance ToJSON ProbeResult where
  toJSON p = object
    [ "name" .= probeName p
    , "ok" .= probeOk p
    , "expected" .= probeExpected p
    , "actual" .= probeActual p
    ]

instance FromJSON ProbeResult where
  parseJSON = withObject "ProbeResult" $ \o -> ProbeResult
    <$> o .: "name"
    <*> o .: "ok"
    <*> o .: "expected"
    <*> o .: "actual"

instance ToJSON Frame where
  toJSON frame = case frame of
    Hello scope parent policy isolation -> object
      [ "v" .= protocolVersion, "op" .= ("hello" :: Text)
      , "scope" .= scope, "parent" .= parent
      , "policy" .= policy, "isolation" .= isolation ]
    Ready backend enforcement caps pid -> object
      [ "v" .= protocolVersion, "op" .= ("ready" :: Text)
      , "backend" .= backend, "enforcement" .= enforcement
      , "capabilities" .= caps, "pid" .= pid ]
    Exec cid argv cwd env stdin timeout -> object
      [ "v" .= protocolVersion, "op" .= ("exec" :: Text)
      , "id" .= cid, "argv" .= argv, "cwd" .= cwd
      , "env" .= [object ["name" .= k, "value" .= v] | (k, v) <- env]
      , "stdin" .= stdin, "timeoutMs" .= timeout ]
    Stdin cid payload -> out "stdin" cid payload
    Stdout cid payload -> out "stdout" cid payload
    Stderr cid payload -> out "stderr" cid payload
    Exit cid code signal -> object
      [ "v" .= protocolVersion, "op" .= ("exit" :: Text)
      , "id" .= cid, "code" .= code, "signal" .= signal ]
    Deny cid kind target -> object
      [ "v" .= protocolVersion, "op" .= ("deny" :: Text)
      , "id" .= cid, "kind" .= kind, "target" .= target ]
    Probe results -> object
      [ "v" .= protocolVersion, "op" .= ("probe" :: Text)
      , "results" .= results ]
    Audit events -> object
      [ "v" .= protocolVersion, "op" .= ("audit" :: Text)
      , "events" .= events ]
    Error cid code message -> object
      [ "v" .= protocolVersion, "op" .= ("error" :: Text)
      , "id" .= cid, "code" .= code, "message" .= message ]
    Shutdown -> object
      [ "v" .= protocolVersion, "op" .= ("shutdown" :: Text) ]
    where
      out :: Text -> Text -> Text -> Value
      out op cid payload = object
        [ "v" .= protocolVersion, "op" .= op
        , "id" .= cid, "data" .= payload ]

encodeFrame :: Frame -> BL.ByteString
encodeFrame = Aeson.encode

-- Decoding ---------------------------------------------------------------

decodeFrame :: BS.ByteString -> Either ProtocolError Frame
decodeFrame raw
  | BS.length raw > maxFrameBytes = Left (FrameTooLarge (BS.length raw))
  | otherwise = case Aeson.eitherDecodeStrict' raw of
      Left err -> Left (MalformedFrame (T.pack err))
      Right value -> case parseEither parseFrame value of
        Left err -> Left (MalformedFrame (T.pack err))
        Right frame -> Right frame

parseFrame :: Value -> Parser Frame
parseFrame = withObject "Frame" $ \o -> do
  version <- o .: "v"
  if version /= protocolVersion
    then fail ("version mismatch: " <> show version)
    else do
      op <- o .: "op" :: Parser Text
      case op of
        "hello" -> Hello
          <$> o .: "scope" <*> o .:? "parent"
          <*> o .: "policy" <*> o .: "isolation"
        "ready" -> Ready
          <$> o .: "backend" <*> o .: "enforcement"
          <*> o .: "capabilities" <*> o .: "pid"
        "exec" -> do
          envPairs <- o .:? "env" :: Parser (Maybe [Value])
          env <- case envPairs of
            Nothing -> pure []
            Just values -> mapM parseEnv values
          Exec <$> o .: "id" <*> o .: "argv" <*> o .: "cwd"
            <*> pure env <*> o .:? "stdin" <*> o .:? "timeoutMs"
        "stdin" -> Stdin <$> o .: "id" <*> o .: "data"
        "stdout" -> Stdout <$> o .: "id" <*> o .: "data"
        "stderr" -> Stderr <$> o .: "id" <*> o .: "data"
        "exit" -> Exit <$> o .: "id" <*> o .: "code" <*> o .:? "signal"
        "deny" -> Deny <$> o .: "id" <*> o .: "kind" <*> o .: "target"
        "probe" -> Probe <$> o .: "results"
        "audit" -> Audit <$> o .: "events"
        "error" -> Error <$> o .:? "id" <*> o .: "code" <*> o .: "message"
        "shutdown" -> pure Shutdown
        other -> fail ("unknown op: " <> T.unpack other)
  where
    parseEnv = withObject "EnvPair" $ \e -> (,)
      <$> e .: "name" <*> e .: "value"
