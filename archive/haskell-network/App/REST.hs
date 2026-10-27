{-# LANGUAGE OverloadedStrings #-}

module App.REST
  ( -- * REST API
    RESTApp(..)
  , createRESTApp
  , runRESTApp
  
    -- * Endpoints
  , getUsers
  , getUser
  , createUser
  , updateUser
  , deleteUser
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BSL

-- | REST application
data RESTApp = RESTApp
  { restAppPort :: Int
  , restAppHost :: String
  }

-- | Create a new REST application
createRESTApp :: Int -> String -> RESTApp
createRESTApp port host = RESTApp port host

-- | Run the REST application
runRESTApp :: RESTApp -> IO ()
runRESTApp app = do
    putStrLn $ "Starting REST server on " ++ restAppHost app ++ ":" ++ show (restAppPort app)
    -- Placeholder: implement REST server
    putStrLn "REST server started"

-- | Get all users
getUsers :: IO [Text]
getUsers = do
    -- Placeholder: implement get users
    return ["user1", "user2", "user3"]

-- | Get a user by ID
getUser :: Text -> IO (Maybe Text)
getUser userId = do
    -- Placeholder: implement get user
    return $ Just $ "User " <> userId

-- | Create a new user
createUser :: Text -> IO Text
createUser userName = do
    -- Placeholder: implement create user
    return $ "Created user: " <> userName

-- | Update a user
updateUser :: Text -> Text -> IO Text
updateUser userId userName = do
    -- Placeholder: implement update user
    return $ "Updated user " <> userId <> " to " <> userName

-- | Delete a user
deleteUser :: Text -> IO Text
deleteUser userId = do
    -- Placeholder: implement delete user
    return $ "Deleted user: " <> userId