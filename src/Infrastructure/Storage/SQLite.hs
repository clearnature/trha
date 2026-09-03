module Infrastructure.Storage.SQLite
  ( SQLiteStorage(..)
  , createSQLiteStorage
  ) where

-- | SQLite storage (placeholder)
data SQLiteStorage = SQLiteStorage
  { dbPath :: FilePath
  }

-- | Create a new SQLite storage
createSQLiteStorage :: FilePath -> IO SQLiteStorage
createSQLiteStorage path = do
  return $ SQLiteStorage path