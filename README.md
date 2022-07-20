# persistent-stm - STM transactions involving persistent storage

![](https://travis-ci.com/cdsmith/persistent-stm.svg?branch=main)
![](https://img.shields.io/hackage/v/persistent-stm)

Haskell's `STM` monad implements composable transactions on in-memory state,
offering atomicity, isolation, and consistency.  However, they lack persistence,
so changes are not durable at all.  This package adds a limited form of
persistence to the existing STM monad, allowing for transactions that include
writing values durably to external storage.

The persistence is limited in the following senses:

* First, it is only suitable for use by a single process at a time.  It is not
  possible to access the storage from multiple processes at the same time,
  *even* *if* some of those processes are merely readers.
* While the view of data in memory is always consistent, the consistency of data
  on disk depends on the `Persistence` implementation, which you choose.  The
  included implementation, `filePersistence`, does *not* guarantee that data
  will be in a consistent or readable state if the process is suddenly
  terminated with a power outage, system crash, etc.  This can be fixed by using
  a `Persistence` implementation built on a transactional storage layer such as
  a database.

# Quick Start

A simple example of using `persistent-stm` follows:

```haskell
import PersistentSTM.DB

main :: IO ()
main = do
    persistence <- filePersistence "./my-data"
    withDB persistence $ \db -> do
        n <- atomically $ do
            ref <- getDBRef db "my-key"
            readDBRef ref >>= \case
                Nothing -> do
                    writeDBRef ref 1
                    return 1
                Just n -> do
                    writeDBRef ref (n + 1)
                    return (n + 1)
        putStrLn $ "Number of times program was run: " ++ show n
```

