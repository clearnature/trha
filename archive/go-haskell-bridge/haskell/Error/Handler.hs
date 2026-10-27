{-# LANGUAGE OverloadedStrings #-}

module Error.Handler
  ( -- * Error Handler
    ErrorHandler(..)
  , createErrorHandler
  
    -- * Error Handling
  , handleError
  , wrapError
  , throwError
  , catchError
  ) where

import Control.Exception
import Data.Text (Text)

-- | Error types
data ErrorType
  = ServerError
  | ClientError
  | TimeoutError
  | NetworkError
  | UnknownError
  deriving (Show, Eq)

-- | Application error
data AppError = AppError
  { errorType    :: ErrorType
  , errorMessage :: Text
  , errorDetails :: Maybe Text
  } deriving (Show)

instance Exception AppError

-- | Error handler
data ErrorHandler = ErrorHandler
  { handlerName :: String
  }

-- | Create a new error handler
createErrorHandler :: String -> IO ErrorHandler
createErrorHandler name = do
  return $ ErrorHandler name

-- | Handle an error
handleError :: ErrorHandler -> AppError -> IO ()
handleError handler error = do
  putStrLn $ "Error handled by " ++ handlerName handler ++ ": " ++ show error

-- | Wrap an error with additional context
wrapError :: Text -> AppError -> AppError
wrapError context error = error { errorMessage = context <> ": " <> errorMessage error }

-- | Throw an error
throwError :: ErrorType -> Text -> Maybe Text -> IO a
throwError errorType message details = do
  throwIO $ AppError errorType message details

-- | Catch an error
catchError :: IO a -> (AppError -> IO a) -> IO a
catchError action handler = do
  catch action handler