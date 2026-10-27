{-# LANGUAGE OverloadedStrings #-}

-- | Message-level presentation helpers: terminal error classification (MiMo's
-- @errorKind()@) and the per-turn footer line (model + token usage).
module UI.Render.Message
  ( ErrorKind(..)
  , classifyError
  , errorLabel
  , errorHint
  , metaLine
  ) where

import Core.Types (Usage(..))
import Data.Text (Text)
import qualified Data.Text as T

-- | Terminal error family.  A rate limit gets its own label so the header
-- reads "rate limited" instead of a generic error.
data ErrorKind = ErrRateLimit | ErrAuth | ErrTimeout | ErrOther
  deriving (Show, Eq)

-- | Classify by the text the shell already has (provider message or
-- scheduler error).  Order matters: 429 wins over a generic "error".
classifyError :: Text -> ErrorKind
classifyError content
  | hits ["429", "rate limit", "rate-limit", "too many requests", "quota"] = ErrRateLimit
  | hits ["401", "403", "unauthorized", "invalid api key", "authentication"] = ErrAuth
  | hits ["timeout", "timed out", "etimedout", "deadline"] = ErrTimeout
  | otherwise = ErrOther
  where
    lc = T.toLower content
    hits = any (`T.isInfixOf` lc)

errorLabel :: ErrorKind -> Text
errorLabel ErrRateLimit = "error · rate limited"
errorLabel ErrAuth      = "error · auth"
errorLabel ErrTimeout   = "error · timeout"
errorLabel ErrOther     = "error"

-- | What the user can do about it.  Only shown for actionable families.
errorHint :: ErrorKind -> Maybe Text
errorHint ErrRateLimit = Just "Retry shortly, or switch provider/model."
errorHint ErrAuth      = Just "Check the provider API key (settings.yaml or env)."
errorHint ErrTimeout   = Just "The stream timed out; partial output was kept."
errorHint ErrOther     = Nothing

-- | Footer for one assistant turn: model and token usage (empty parts are
-- dropped, so a missing usage leaves just the model).
metaLine :: Text -> Maybe Usage -> Text
metaLine model musage = T.intercalate " · " parts
  where
    parts = [ "model=" <> model | not (T.null model) ]
         ++ case musage of
              Just u | usageTotalTokens u > 0 ->
                [ "in " <> tshow (usagePromptTokens u)
                , "out " <> tshow (usageCompletionTokens u) ]
              _ -> []
    tshow = T.pack . show
