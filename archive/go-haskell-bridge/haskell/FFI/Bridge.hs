{-# LANGUAGE ForeignFunctionInterface #-}

module FFI.Bridge
  ( -- * FFI Bridge
    callGoFunction
  , callHaskellFunction
  ) where

import Foreign.C.Types
import Foreign.Ptr
import Foreign.Storable
import Data.Text (Text)
import qualified Data.Text.Foreign as TF

-- | Call a Go function from Haskell
callGoFunction :: String -> [String] -> IO String
callGoFunction funcName args = do
  -- Placeholder: implement FFI call to Go
  return $ "Result from Go: " ++ funcName

-- | Call a Haskell function from Go (exported)
foreign export ccall "callHaskellFunction" callHaskellFunction :: CString -> IO CString

-- | Implementation of callHaskellFunction
callHaskellFunction :: CString -> IO CString
callHaskellFunction cFuncName = do
  funcName <- TF.peekCStringLen (cFuncName, 100)
  result <- callGoFunction (T.unpack funcName) []
  TF.newCString (T.pack result)