{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

-- | A scheme for adding persistence to Haskell's STM transactions.  A @'DBRef'
-- a@ is like a @'TVar' ('Maybe' a)@, except that it exists (or not) in
-- persistent storage as well as in memory.
--
-- The choice of persistent storage is up to the user, and is specified with a
-- 'Persistence'.  There is a default implementation called 'filePersistence'
-- that uses files on disk.  Note that 'filePersistence' doesn't guarantee
-- transactional atomicity in the presence of sudden termination of the process,
-- such as in a power outage or system crash.  Therefore, for serious use,
-- it's recommended that you use a different 'Persistence' implementation based
-- on a storage layer with stronger transactional guarantees.
--
-- For this scheme to work at all, this process must be the only entity to
-- access the persistent storage.  You may not even use a single-writer,
-- multiple-reader architecture, because consistency guarantees for reads, as
-- well, depend on all writes happening in the current process.
module PersistentSTM.DB
  ( DB,
    openDB,
    closeDB,
    withDB,
    checkWriteQueue,
    DBRef,
    DBStorable (..),
    getDBRef,
    readDBRef,
    writeDBRef,
    delDBRef,
    Persistence (..),
    filePersistence,
  )
where

import Control.Concurrent
  ( forkIO,
    newEmptyMVar,
    putMVar,
    takeMVar,
  )
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    newTVar,
    newTVarIO,
    readTVar,
    retry,
    writeTVar,
  )
import Control.Exception (bracket)
import Control.Monad (forM_, when)
import Control.Monad.Extra (whileM)
import Data.Binary (Binary)
import qualified Data.Binary as Binary
import Data.Bool (bool)
import qualified Data.ByteString as BS
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Typeable (TypeRep, Typeable, typeRep)
import Data.Word (Word16, Word32, Word64, Word8)
import qualified Focus
import GHC.Conc (unsafeIOToSTM)
import Numeric.Natural (Natural)
import qualified StmContainers.Map as SMap
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FileLock (SharedExclusive (..), tryLockFile, unlockFile)
import System.FilePath ((</>))
import System.Mem.Weak (Weak, deRefWeak, mkWeak)
import Unsafe.Coerce (unsafeCoerce)

-- | A type class for things that can be stored in a DBRef.  This is similar to
-- a serialization class like 'Binary', but reads have access to the 'DB' and
-- the STM monad, which is important because it allows for one 'DBRef' to be
-- stored inside the value of another.  (In this case, 'decode' will call
-- 'getDBRef'.)
class Typeable a => DBStorable a where
  decode :: DB -> ByteString -> STM a
  default decode :: (Binary a) => DB -> ByteString -> STM a
  decode _ = pure . Binary.decode

  encode :: a -> ByteString
  default encode :: (Binary a) => a -> ByteString
  encode = Binary.encode

instance DBStorable ()

instance DBStorable Bool

instance DBStorable Char

instance DBStorable Double

instance DBStorable Float

instance DBStorable Int

instance DBStorable Int8

instance DBStorable Int16

instance DBStorable Int32

instance DBStorable Int64

instance DBStorable Integer

instance DBStorable Natural

instance DBStorable Ordering

instance DBStorable Word

instance DBStorable Word8

instance DBStorable Word16

instance DBStorable Word32

instance DBStorable Word64

instance DBStorable BS.ByteString

instance DBStorable ByteString

instance DBStorable ShortByteString

instance DBStorable a => DBStorable [a] where
    encode = Binary.encode . fmap encode
    decode db = traverse (decode db) . Binary.decode

-- | Internal state of a 'DBRef'.  'Loading' means that the value is already
-- being loaded from persistent storage in a different thread, so the current
-- transaction can just retry to wait for it to load.
data Possible a = Loading | Missing | Present a

-- | Existential wrapper around 'TVar' that lets 'TVar's of various types be
-- cached.
data SomeTVar = forall a. SomeTVar (TVar (Possible a))

-- | A strategy for persisting values from 'DBRef' to some persistent storage.
-- The 'filePersistence' implementation is provided as a quick way to get
-- started, but note the weaknesses in its documentation.
--
-- A 'Persistence' can read one value at a time, but should be able to atomically
-- write/delete an entire set of keys at once, preferably atomically.
data Persistence = Persistence
  { -- | Read a single value from persistent storage.  Return the serialized
    -- representation if it exists, and Nothing otherwise.
    persistentRead :: String -> IO (Maybe ByteString),
    -- | Write (for 'Just' values) or delete (for 'Nothing' values) an entire
    -- set of values to persistent storage.  The values should ideally be
    -- written atomically, and if they are not then the implementation will be
    -- vulnerable to inconsistent data and corruption if the process is suddenly
    -- terminated.
    persistentWrite :: Map String (Maybe ByteString) -> IO (),
    -- | Perform any cleanup that is needed after the 'DB' is closed.  This can
    -- include releasing locks, for example.
    persistentFinish :: IO ()
  }

-- A currently open database in which 'DBRef's can be read and written.  See
-- 'openDB', 'closeDB', and 'withDB' to manage 'DB' values.
data DB = DB
  { -- | Cached 'TVar's corresponding to 'DBRef's that are already loading or
    -- loaded.
    dbRefs :: SMap.Map String (TypeRep, Weak SomeTVar),
    -- | Collection of dirty values that need to be written.  Only the
    -- 'ByteString' from the value is needed, but keeping the 'TVar' as well
    -- ensures that the 'TVar' won't be garbage collected and removed from
    -- 'dbRefs', which guarantees the value won't be read again until after the
    -- write is complete.  This is needed for consistency.
    dbDirty :: TVar (Map String (SomeTVar, Maybe ByteString)),
    -- | The persistence that is used for this database.
    dbPersistence :: Persistence,
    -- | If True, then 'closeDB' has been called, and the no new accesses to the
    -- 'DBRef's should be allowed.  This also triggers the writer thread to exit
    -- as soon as it has finished writing all dirty values.
    dbClosing :: TVar Bool,
    -- | If True, the writer thread as finished writing all dirty values, and
    -- it's okay for the process to exit.
    dbClosed :: TVar Bool
  }

-- A reference to persistent data from some 'DB' that can be accessed in 'STM'
-- transaction.  @'DBRef' a@ is similar to @'TVar ('Maybe' a)@, except that
-- values exist in persistent storage as well as in memory.
data DBRef a = DBRef DB String (TVar (Possible a))

-- | Only 'DBRef's in the same 'DB' should be compared.
instance Eq (DBRef a) where
  DBRef _ k1 _ == DBRef _ k2 _ = k1 == k2

-- | Only 'DBRef's in the same 'DB' should be compared.
instance Ord (DBRef a) where
  compare (DBRef _ k1 _) (DBRef _ k2 _) = compare k1 k2

instance Show (DBRef a) where
  show (DBRef _ s _) = s

instance DBStorable a => DBStorable (DBRef a) where
  decode db bs = getDBRef db (Binary.decode bs)
  encode (DBRef _ dbkey _) = Binary.encode dbkey

-- | A simple 'Persistence' that stores data in a directory in the local
-- filesystem.  This is an easy way to get started.  However, note that because
-- writes are not atomic, your data can be corrupted during a crash or power
-- outage.  For this reason, it's recommended that you use a different
-- 'Persistence' for most applications.
filePersistence :: FilePath -> IO Persistence
filePersistence dir = do
  createDirectoryIfMissing True dir
  tryLockFile (dir </> ".lock") Exclusive >>= \case
    Nothing -> error "Directory is already in use"
    Just lock ->
      return $
        Persistence
          { persistentRead = \key -> do
              ex <- doesFileExist (dir </> key)
              if ex
                then Just <$> BS.fromStrict <$> BS.readFile (dir </> key)
                else return Nothing,
            persistentWrite = \dirtyMap -> forM_ (Map.toList dirtyMap) $
              \(key, mbs) -> case mbs of
                Just bs -> BS.writeFile (dir </> key) (BS.toStrict bs)
                Nothing -> removeFile (dir </> key),
            persistentFinish = unlockFile lock
          }

-- | Opens a 'DB' using the given 'Persistence'.  The caller should guarantee
-- that 'closeDB' is called when the 'DB' is no longer needed.
openDB :: Persistence -> IO DB
openDB persistence = do
  refs <- SMap.newIO
  dirty <- newTVarIO Map.empty
  closing <- newTVarIO False
  closed <- newTVarIO False
  _ <- forkIO $ do
    whileM $ do
      (d, c) <- atomically $ do
        c <- readTVar closing
        d <- readTVar dirty
        when (not c && Map.null d) retry
        when (not (Map.null d)) $ writeTVar dirty Map.empty
        return (d, c)
      when (not (Map.null d)) $ persistentWrite persistence (snd <$> d)
      return (not c)
    atomically $ writeTVar closed True
  let db =
        DB
          { dbRefs = refs,
            dbDirty = dirty,
            dbPersistence = persistence,
            dbClosing = closing,
            dbClosed = closed
          }
  return db

-- | Closes a 'DB'.  When this call returns, all data will be written to
-- persistent storage, and the program can exit without possibly losing data.
closeDB :: DB -> IO ()
closeDB db = do
  atomically $ writeTVar (dbClosing db) True
  atomically $ readTVar (dbClosed db) >>= bool retry (return ())
  persistentFinish (dbPersistence db)

-- | Runs an action with a 'DB' open.  The 'DB' will be closed when the action
-- is finished.  The 'DB' value should not be used after the action has
-- returned.
withDB :: Persistence -> (DB -> IO ()) -> IO ()
withDB persistence f = bracket (openDB persistence) closeDB f

-- | Check that there are at most the given number of queued writes to the
-- database, and retries the transaction if so.  Adding this to the beginning of
-- your transactions can help prevent writes from falling too far behind the
-- live data, and can reduce memory usage (because 'DBRef's no longer need to be
-- retained once they are written to disk).
checkWriteQueue :: DB -> Int -> STM ()
checkWriteQueue db maxLen = do
  dirty <- readTVar (dbDirty db)
  when (Map.size dirty > maxLen) retry

failIfClosing :: DB -> STM ()
failIfClosing db = do
  c <- readTVar (dbClosing db)
  when c $ error "DB is closing"

-- | Retrieves a 'DBRef' from a 'DB' for the given key.  Throws an exception if
-- the 'DBRef' requested has a different type from a previous time the key was
-- used in this process, or if a serialized value in persistent storage cannot
-- be parsed.
getDBRef :: forall a. DBStorable a => DB -> String -> STM (DBRef a)
getDBRef db key = do
  failIfClosing db
  SMap.lookup key (dbRefs db) >>= \case
    Just (tr, weakRef)
      | tr == typeRep (Proxy @a) ->
          unsafeIOToSTM (deRefWeak weakRef) >>= \case
            Just (SomeTVar ref) -> return (DBRef db key (unsafeCoerce ref))
            Nothing -> insert
      | otherwise -> error "Type mismatch in DBRef"
    Nothing -> insert
  where
    insert = do
      ref <- newTVar Loading
      ptr <- unsafeIOToSTM $ mkWeak ref (SomeTVar ref) (Just cleanupKey)
      SMap.insert (typeRep (Proxy @a), ptr) key (dbRefs db)
      v <- unsafeIOToSTM $ do
        mvar <- newEmptyMVar
        _ <- forkIO $ putMVar mvar =<< readKey
        takeMVar mvar
      writeTVar ref v
      return (DBRef db key ref)

    readKey = do
      readResult <- persistentRead (dbPersistence db) key
      case readResult of
        Just bs -> Present <$> atomically (decode db bs)
        Nothing -> return Missing

    cleanupKey =
      atomically $
        SMap.focus
          ( Focus.updateM
              ( \(tr, p) ->
                  unsafeIOToSTM (deRefWeak p) >>= \case
                    Nothing -> return Nothing
                    Just _ -> return (Just (tr, p))
              )
          )
          key
          (dbRefs db)

-- | Gets the value stored in a 'DBRef'.  The value is @'Just' x@ if @x@ was
-- last value stored in the database using this key, or 'Nothing' if there is no
-- value stored in the database.
readDBRef :: DBRef a -> STM (Maybe a)
readDBRef (DBRef db _ ref) = do
  failIfClosing db
  readTVar ref >>= \case
    Loading -> retry
    Missing -> return Nothing
    Present a -> return (Just a)

-- | Updates the value stored in a 'DBRef'.  The update will be persisted to
-- storage soon, but not synchronously.
writeDBRef :: DBStorable a => DBRef a -> a -> STM ()
writeDBRef (DBRef db dbkey ref) a = do
  failIfClosing db
  writeTVar ref (Present a)
  d <- readTVar (dbDirty db)
  writeTVar (dbDirty db) (Map.insert dbkey (SomeTVar ref, Just (encode a)) d)

-- | Deletes the value stored in a 'DBRef'.  The delete will be persisted to
-- storage soon, but not synchronously.
delDBRef :: DBStorable a => DBRef a -> STM ()
delDBRef (DBRef db dbkey ref) = do
  failIfClosing db
  writeTVar ref Missing
  d <- readTVar (dbDirty db)
  writeTVar (dbDirty db) (Map.insert dbkey (SomeTVar ref, Nothing) d)