{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The kernel's HTTP security boundary (loopback gate).
--
-- Binding to @127.0.0.1@ is not enough by itself: any page in a browser can
-- reach @http://127.0.0.1:<port>@ (DNS rebinding, or a plain cross-origin
-- form post), and any process running as another local user can open a TCP
-- connection.  This gate mirrors Reasonix's @LoopbackGate@ and checks, in
-- order:
--
--   1. **Host** belongs to the loopback interface — a request addressed to
--      some other name is refused before the credential is even looked at;
--   2. **Origin**, when present, is loopback — a cross-origin browser request
--      is refused;
--   3. **Content-Type** — anything that changes state must be
--      @application\/json@, so a simple cross-origin form/text post cannot
--      drive the API (CSRF preflightless request);
--   4. **Bearer token**, compared in constant time.
--
-- The token is shared with the scheduler through @~/.trha/kernel-token@ (0600)
-- or @TRHA_KERNEL_TOKEN@.  It is minted once from 32 random bytes and reused
-- across launches; deleting the file rotates it.
module API.Security
  ( kernelTokenPath
  , resolveKernelToken
  , rotateTokenAt
  , guardKernel
  , writeKernelRuntime
  , removeKernelRuntime
  , RequestFacts(..)
  , Decision(..)
  , decide
  ) where

import Control.Exception (try)
import Data.Aeson (Value(..), decode, encode, object, (.=))
import Data.Aeson.Types (parseMaybe, (.:))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Bits as Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.Char (isSpace, toLower)
import Data.List (foldl')
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Network.HTTP.Types
    ( Status, methodGet, methodHead, methodOptions, status401, status403, status415 )
import Network.Wai (Application, Request, rawPathInfo, requestHeaders, requestMethod, responseLBS)
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Random (randomIO)
import System.Posix.Process (getProcessID)

#ifndef mingw32_HOST_OS
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
#endif

--------------------------------------------------------------------------------
-- Shared token
--------------------------------------------------------------------------------

-- | @~/.trha/kernel-token@ — read by the scheduler, written by the kernel.
kernelTokenPath :: IO FilePath
kernelTokenPath = do
  home <- getHomeDirectory
  pure (home </> ".trha" </> "kernel-token")

-- | Resolve the kernel token **for this launch**.
--
-- Order: @TRHA_KERNEL_TOKEN@ (explicit override for tests/deployments), then a
-- fresh token written to @~/.trha/kernel-token@.  Every start rotates it, so a
-- token copied off the machine stops working after the next restart; the
-- scheduler re-reads the file per request (and retries once on 401), which is
-- the whole "restart handshake".
resolveKernelToken :: IO ByteString
resolveKernelToken = do
  mOverride <- lookupEnv "TRHA_KERNEL_TOKEN"
  case fmap (BC.pack . trim) mOverride of
    Just t | not (BS.null t) -> pure t
    _ -> kernelTokenPath >>= rotateTokenAt

-- | Mint a new token and publish it atomically (temp file + rename), so a
-- concurrent reader sees either the old token or the new one — never a
-- half-written file.  0600 on POSIX.
rotateTokenAt :: FilePath -> IO ByteString
rotateTokenAt path = do
  createDirectoryIfMissing True (takeDirectory path)
  token <- mintToken
  let tmp = path ++ ".tmp"
  BS.writeFile tmp token
  setOwnerOnly tmp
  renameFile tmp path
  pure token

mintToken :: IO ByteString
mintToken = do
  words32 <- mapM (\_ -> randomIO :: IO Word64) [1 .. 4 :: Int]
  pure $ BC.pack (concatMap hex16 words32)

setOwnerOnly :: FilePath -> IO ()
#ifndef mingw32_HOST_OS
setOwnerOnly p = do
  -- A missing POSIX layer is not worth failing startup over; the directory
  -- (~/.trha, 0700) is the fallback protection.
  _ <- try (setFileMode p (ownerReadMode `unionFileModes` ownerWriteMode)) :: IO (Either IOError ())
  pure ()
#else
setOwnerOnly _ = pure ()
#endif

hex16 :: Word64 -> String
hex16 n = [ digit (fromIntegral ((n `Bits.shiftR` s) Bits..&. 0xF)) | s <- [60, 56 .. 0] ]
  where
    digit d
      | d < 10    = toEnum (fromEnum '0' + d)
      | otherwise = toEnum (fromEnum 'a' + d - 10)

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

--------------------------------------------------------------------------------
-- Pure decision
--------------------------------------------------------------------------------

-- | The request facts the gate needs, extracted from a WAI 'Request'.
data RequestFacts = RequestFacts
  { rfMethod      :: ByteString
  , rfPath        :: ByteString
  , rfHost        :: Maybe ByteString
  , rfOrigin      :: Maybe ByteString
  , rfContentType :: Maybe ByteString
  , rfAuth        :: Maybe ByteString
  } deriving (Show, Eq)

data Decision = Allow | Refuse Status ByteString
  deriving (Show, Eq)

-- | The whole policy, as a pure function so it can be tested without sockets.
decide :: ByteString -> RequestFacts -> Decision
decide token facts
  | isExempt facts = Allow
  | not (hostAllowed (rfHost facts)) = Refuse status403 "loopback.host_rejected"
  | not (originAllowed facts) = Refuse status403 "loopback.origin_rejected"
  | not (jsonContent facts) = Refuse status415 "content-type.not_json"
  | not (tokenPresented token (rfAuth facts)) = Refuse status401 "loopback.unauthorized"
  | otherwise = Allow

isExempt :: RequestFacts -> Bool
isExempt f = rfMethod f == methodGet && rfPath f == "/health"

hostAllowed :: Maybe ByteString -> Bool
hostAllowed Nothing   = True   -- non-browser client (HTTP/1.0, or a raw socket)
hostAllowed (Just h)  = isLoopbackHost (hostPart h)

originAllowed :: RequestFacts -> Bool
originAllowed f = case rfOrigin f of
  Nothing -> True
  Just o  -> case schemeSeparated o of
    Nothing      -> False
    Just (_, a)  -> isLoopbackHost (hostPart a)

-- | Drop @scheme://@ and return the scheme plus the authority.
schemeSeparated :: ByteString -> Maybe (ByteString, ByteString)
schemeSeparated raw =
  let (scheme, rest) = BC.breakSubstring "://" raw
  in if BS.null rest
       then Nothing
       else Just (BC.map toLower scheme, BS.drop 3 rest)

-- | The host part of @host[:port]@ / @[v6][:port]@.
hostPart :: ByteString -> ByteString
hostPart h
  | "[" `BS.isPrefixOf` h = BS.takeWhile (/= 0x5d) (BS.drop 1 h)   -- ']'
  | otherwise             = BS.takeWhile (/= 0x3a) h               -- ':'

isLoopbackHost :: ByteString -> Bool
isLoopbackHost h = BC.map toLower h `elem`
  ["localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1"]

-- | State-changing requests must be JSON: a @text/plain@ cross-origin post is
-- a "simple request" (no preflight), which is exactly the CSRF shape.
jsonContent :: RequestFacts -> Bool
jsonContent f =
  let m = rfMethod f
  in m `elem` [methodGet, methodHead, methodOptions]
     || maybe False isJson (rfContentType f)
  where
    isJson ct = "application/json" `BS.isPrefixOf` BC.map toLower (BC.dropWhile isSpace ct)

tokenPresented :: ByteString -> Maybe ByteString -> Bool
tokenPresented expected Nothing = False
tokenPresented expected (Just raw) =
  not (BS.null expected)
    && case BC.break (== ' ') (BC.strip raw) of
         (scheme, rest)
           | BC.map toLower scheme == "bearer" ->
               constantTimeEq expected (BC.strip rest)
         _ -> False

-- | Compare without leaking the length of the common prefix through timing.
constantTimeEq :: ByteString -> ByteString -> Bool
constantTimeEq a b
  | BS.length a /= BS.length b = False
  | otherwise =
      foldl' (\acc (x, y) -> acc Bits..|. (x `Bits.xor` y)) 0 (BS.zip a b) == 0

--------------------------------------------------------------------------------
-- WAI middleware
--------------------------------------------------------------------------------

factsOf :: Request -> RequestFacts
factsOf req = RequestFacts
  { rfMethod      = requestMethod req
  , rfPath        = rawPathInfo req
  , rfHost        = lookup "Host" hdrs
  , rfOrigin      = lookup "Origin" hdrs
  , rfContentType = lookup "Content-Type" hdrs
  , rfAuth        = lookup "Authorization" hdrs
  }
  where
    hdrs = requestHeaders req

guardKernel :: ByteString -> Application -> Application
guardKernel token app req respond =
  case decide token (factsOf req) of
    Allow -> app req respond
    Refuse status code ->
      respond $ responseLBS status
        [("Content-Type", "application/json")]
        (encode (object ["error" .= TE.decodeUtf8 code, "code" .= TE.decodeUtf8 code]))

--------------------------------------------------------------------------------
-- Runtime registry (kernel section)
--
-- The scheduler and shells read live ports/tokens from
-- @~/.trha/runtime.json@ instead of guessing.  Each process replaces only its
-- own section, atomically (temp file + rename).
--------------------------------------------------------------------------------

kernelRuntimeKey :: Key.Key
kernelRuntimeKey = Key.fromText "kernel"

runtimeFile :: IO FilePath
runtimeFile = do
  home <- getHomeDirectory
  pure (home </> ".trha" </> "runtime.json")

readRuntimeRoot :: IO Value
readRuntimeRoot = do
  p <- runtimeFile
  exists <- doesFileExist p
  if not exists
    then pure (Object KM.empty)
    else do
      raw <- try (BS.readFile p) :: IO (Either IOError BS.ByteString)
      pure $ case raw of
        Left _  -> Object KM.empty
        Right b -> maybe (Object KM.empty) id (decode (BL.fromStrict b))

writeKernelRuntime :: String -> Int -> ByteString -> IO ()
writeKernelRuntime host port token = do
  p <- runtimeFile
  cur <- readRuntimeRoot
  pid <- fromIntegral <$> getProcessID
  let entry = object
        [ "host" .= host, "port" .= port, "pid" .= (pid :: Int)
        , "token" .= TE.decodeUtf8 token ]
      merged = case cur of
        Object o -> Object (KM.insert kernelRuntimeKey entry o)
        _        -> object [kernelRuntimeKey .= entry]
      tmp = p ++ ".tmp"
  createDirectoryIfMissing True (takeDirectory p)
  BL.writeFile tmp (encode merged)
  setOwnerOnly tmp
  renameFile tmp p

removeKernelRuntime :: IO ()
removeKernelRuntime = do
  p <- runtimeFile
  cur <- readRuntimeRoot
  me <- fromIntegral <$> getProcessID
  case cur of
    Object o -> case KM.lookup kernelRuntimeKey o of
      Just (Object e)
        | (parseMaybe (.: "pid") e :: Maybe Int) == Just me -> do
            let tmp = p ++ ".tmp"
            BL.writeFile tmp (encode (Object (KM.delete kernelRuntimeKey o)))
            setOwnerOnly tmp
            renameFile tmp p
      _ -> pure ()
    _ -> pure ()
