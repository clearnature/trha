{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Storage.SQLite
  ( SQLiteStorage(..)
  , createSQLiteStorage
  , execute
  , query
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | SQLite storage
data SQLiteStorage = SQLiteStorage
  { dbPath :: FilePath
  }

-- | Create a new SQLite storage
createSQLiteStorage :: FilePath -> IO SQLiteStorage
createSQLiteStorage path = do
  return $ SQLiteStorage path

-- | Execute a SQL statement
execute :: SQLiteStorage -> Text -> IO (Either Text ())
execute storage sql = do
  -- In production, would execute SQL
  putStrLn $ "Executing SQL: " ++ T.unpack sql
  return $ Right ()

-- | Query data
query :: SQLiteStorage -> Text -> IO (Either Text [[Text]])
query storage sql = do
  -- In production, would execute query
  putStrLn $ "Querying: " ++ T.unpack sql
  return $ Right [["result1", "result2"]]