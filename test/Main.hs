{-# LANGUAGE LambdaCase #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (replicateM)
import Data.IORef (newIORef, readIORef, writeIORef)
import PersistentSTM
  ( Persistence (..),
    filePersistence,
    getDBRef,
    readDBRef,
    synchronously,
    withDB,
    writeDBRef,
  )
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, hspec, it, shouldBe, shouldReturn)

endToEndSpec :: Spec
endToEndSpec =
  describe "end-to-end" $ do
    it "maintains a persistent counter" $ do
      withSystemTempDirectory "persistent-stm" $ \dir -> do
        nums <- replicateM 100 $ do
          p <- filePersistence dir
          withDB p $ \db -> do
            atomically $ do
              ref <- getDBRef db "my-key"
              readDBRef ref >>= \case
                Nothing -> do
                  writeDBRef ref (1 :: Int)
                  return 1
                Just n -> do
                  writeDBRef ref (n + 1)
                  return (n + 1)
        nums `shouldBe` [1 .. 100]

    it "waits for writes before synchronously returns" $ do
      written <- newIORef False
      let dummyPersistence =
            Persistence
              { persistentRead = const (return Nothing),
                persistentWrite = const $ do
                  threadDelay 250000
                  writeIORef written True,
                persistentFinish = return ()
              }
      withDB dummyPersistence $ \db -> do
        synchronously db $ do
          ref <- getDBRef db "my-key"
          writeDBRef ref ()
        readIORef written `shouldReturn` True

      writeIORef written False

      withDB dummyPersistence $ \db -> do
        atomically $ do
          ref <- getDBRef db "my-key"
          writeDBRef ref ()
        readIORef written `shouldReturn` False
      readIORef written `shouldReturn` True

main :: IO ()
main = hspec $ do
  endToEndSpec
